// FleetConfigViewModel — the fleet configuration engine (SPEC §2.7). Turns the
// demo "Fleet Config" into a real engine: manage reusable provisioning templates
// (persisted), target nodes from the store, preview each node's config diff
// (dry-run), then roll the template out ONE NODE AT A TIME — each verified before the
// next, halting on the first failure so a bad change can't destabilise the fleet.
//
// `@MainActor @Observable`. The rollout itself reuses the proven `FleetRolloutViewModel`
// over `FleetApplier`; this model adds template CRUD + member targeting on top, and
// builds the per-node `AdminChannel` (store-backed by default, the over-the-air radio
// transport being the HIL effect — see `StoreBackedAdminChannel`). Unit-tested over an
// in-memory store, end-to-end through the store-backed channel.

import Domain
import Foundation
import Observation
import Persistence
import Provisioning

@Observable
@MainActor
public final class FleetConfigViewModel {
    // MARK: Templates

    /// An editable, persisted template (its row id + the rendered model).
    public struct TemplateItem: Identifiable, Sendable, Equatable {
        public let id: Int64
        public let template: NodeTemplate
    }

    /// The editor's working copy of a template's fields (strings for binding).
    ///
    /// `name`, naming DSLs and channels are template-only concerns (no per-node form
    /// equivalent) and stay as scalar strings. The broad protocol surface — every
    /// LoRa/Device/Position/Power/Display/Network/Bluetooth/Security/module knob,
    /// including `region`/`role`/`position_precision` — lives in `fields`, keyed by
    /// `AdminConfigField.rawValue`, so the editor can drive the SAME bespoke
    /// `NodeConfigForm` the per-node editor uses. Only the keys the operator actually
    /// set are kept, so a template carries a minimal group-default set.
    public struct TemplateDraft: Sendable, Equatable {
        public var name: String
        public var shortNameDSL: String
        public var longNameDSL: String
        public var channels: String // comma-separated channel names
        /// Broad config defaults, keyed by `AdminConfigField.rawValue`. Region/role/
        /// precision live here too (they are real admin fields).
        public var fields: [String: String]

        /// Region the rollout always sets (legal, SPEC §2.9). Reads/writes
        /// `fields["region"]`, defaulting to "US" so a fresh draft is connectable.
        public var region: String {
            get { fields["region"] ?? "US" }
            set { fields["region"] = newValue }
        }

        /// Device role default. Reads/writes `fields["role"]` (back-compat accessor —
        /// the broad form edits the same key directly). Empty string clears it.
        public var role: String {
            get { fields["role"] ?? "" }
            set { fields["role"] = newValue.isEmpty ? nil : newValue }
        }

        /// Position broadcast precision (bits) default. Reads/writes
        /// `fields["position_precision"]`; empty string clears it.
        public var positionPrecision: String {
            get { fields["position_precision"] ?? "" }
            set { fields["position_precision"] = newValue.isEmpty ? nil : newValue }
        }

        public init(
            name: String = "New template",
            region: String = "US",
            role: String = "CLIENT",
            shortNameDSL: String = "{shortName}",
            longNameDSL: String = "{longName}",
            channels: String = "",
            positionPrecision: String = "",
            fields: [String: String] = [:]
        ) {
            self.name = name
            self.shortNameDSL = shortNameDSL
            self.longNameDSL = longNameDSL
            self.channels = channels
            var seeded = fields
            seeded["region"] = seeded["region"] ?? region
            if seeded["role"] == nil, !role.isEmpty { seeded["role"] = role }
            if seeded["position_precision"] == nil, !positionPrecision.isEmpty {
                seeded["position_precision"] = positionPrecision
            }
            self.fields = seeded
        }
    }

    public private(set) var templates: [TemplateItem] = []
    /// The template currently loaded in the editor (`nil` = a new, unsaved draft).
    public private(set) var selectedTemplateID: Int64?
    public var draft = TemplateDraft()

    /// The editor's broad-config form, driving the SAME bespoke `NodeConfigForm`
    /// sections (Device/LoRa/Position/…) the per-node editor renders. Seeded with an
    /// empty baseline so its `values` hold EXACTLY the keys the template carries as
    /// group defaults; `select`/`newTemplate` rebuild it from the draft and save/preview
    /// reconcile the draft's `fields` from it. Which fields a template sets, the rollout
    /// applies; a per-node `NodeConfigEdit` then overrides on top.
    public private(set) var configForm = NodeConfigFormState(baseline: [:])

    // MARK: Members

    /// A node that can be targeted by a rollout.
    public struct MemberCandidate: Identifiable, Sendable, Equatable {
        public let nodeNum: Int64
        public let name: String
        public let hexid: String
        public let shortName: String?
        public let longName: String?
        public let role: String?
        public let isMine: Bool
        public let isManaged: Bool
        public var id: Int64 {
            nodeNum
        }
    }

    public private(set) var candidates: [MemberCandidate] = []
    public var selected: Set<Int64> = []
    public var showMineOnly = false
    public var showManagedOnly = false
    /// Halt the rollout at the first failed node (the safe default).
    public var haltOnFailure = true

    /// The in-flight / last rollout (per-node diff + status + progress). Built by
    /// `preview()`/`startRollout()`.
    public private(set) var rollout: FleetRolloutViewModel?
    public private(set) var lastError: String?

    @ObservationIgnored private let store: MeshStore
    @ObservationIgnored private let channelFor: @Sendable (Int64) -> any AdminChannel

    /// - Parameters:
    ///   - store: the shared store (templates + nodes + the store-backed admin channel).
    ///   - channelFor: resolves a node's `AdminChannel`; defaults to the store-backed
    ///     channel. Tests inject a fake; a future HIL adapter sends over the air.
    public init(
        store: MeshStore,
        channelFor: (@Sendable (Int64) -> any AdminChannel)? = nil
    ) {
        self.store = store
        self.channelFor = channelFor ?? { nodeNum in StoreBackedAdminChannel(store: store, nodeNum: nodeNum) }
    }

    // MARK: Loading

    public func load() async {
        await loadTemplates()
        await loadCandidates()
    }

    public func loadTemplates() async {
        do {
            let records = try await store.allTemplates()
            templates = records.compactMap { record in
                record.id.map { TemplateItem(id: $0, template: Self.template(from: record)) }
            }
            if let id = selectedTemplateID, templates.contains(where: { $0.id == id }) {
                // keep selection
            } else if let first = templates.first {
                select(first.id)
            }
        } catch {
            lastError = "\(error)"
        }
    }

    public func loadCandidates() async {
        do {
            candidates = try await store.allNodes().map { node in
                let hexid = node.hexid ?? Self.hexID(node.node_num)
                return MemberCandidate(
                    nodeNum: node.node_num,
                    name: node.short_name ?? node.long_name ?? hexid,
                    hexid: hexid,
                    shortName: node.short_name,
                    longName: node.long_name,
                    role: node.role,
                    isMine: node.is_mine,
                    isManaged: node.is_managed
                )
            }
        } catch {
            lastError = "\(error)"
        }
    }

    /// Candidates after applying the My-Nodes / Managed filters.
    public var visibleCandidates: [MemberCandidate] {
        candidates.filter { candidate in
            (!showMineOnly || candidate.isMine) && (!showManagedOnly || candidate.isManaged)
        }
    }

    // MARK: Template editing

    public func newTemplate() {
        selectedTemplateID = nil
        draft = TemplateDraft()
        rebuildConfigForm()
    }

    public func select(_ id: Int64) {
        guard let item = templates.first(where: { $0.id == id }) else { return }
        selectedTemplateID = id
        draft = Self.draft(from: item.template)
        rebuildConfigForm()
    }

    /// Reseed the broad-config form from the current draft so the shared
    /// `NodeConfigForm` sections show this template's defaults. Called whenever the
    /// draft is replaced (new / select).
    public func rebuildConfigForm() {
        configForm = NodeConfigFormState(templateFields: draft.fields)
    }

    /// Fold the editor form's broad-config edits back into the draft. The bespoke
    /// `NodeConfigSectionView` mutates `configForm` directly; before persisting (or
    /// previewing) we copy its `changedFields` — only the keys the operator actually
    /// edited in the form — into the draft. Applying just the edits (not every value)
    /// means a draft scalar set elsewhere (e.g. `draft.role`) isn't clobbered by the
    /// form's stale seed.
    private func syncFormIntoDraft() {
        for (key, value) in configForm.changedFields {
            draft.fields[key] = value
        }
    }

    /// Persist the current draft (insert or update) and reselect it.
    public func saveTemplate() async {
        syncFormIntoDraft()
        do {
            let template = currentTemplate()
            try template.validate() // reject an unsupported broad key before persisting
            let id = try await store.upsertTemplate(Self.record(from: template, id: selectedTemplateID))
            selectedTemplateID = id
            await loadTemplates()
        } catch {
            lastError = "\(error)"
        }
    }

    public func deleteSelectedTemplate() async {
        guard let id = selectedTemplateID else { return }
        do {
            try await store.deleteTemplate(id: id)
            selectedTemplateID = nil
            draft = TemplateDraft()
            rebuildConfigForm()
            await loadTemplates()
        } catch {
            lastError = "\(error)"
        }
    }

    /// The `NodeTemplate` described by the current draft (what a rollout applies).
    ///
    /// Region/role/precision are pulled out of the draft's broad `fields` into the
    /// template's typed properties (so the existing named-field `desiredConfig` path +
    /// its tests are unchanged); every OTHER set field rides in `fields` as a group
    /// default. Blank values are dropped so the template carries only what the operator
    /// actually configured.
    public func currentTemplate() -> NodeTemplate {
        var broad = draft.fields.filter { !$0.value.isEmpty }
        let region = broad.removeValue(forKey: "region") ?? "US"
        let role = broad.removeValue(forKey: "role")
        let precision = broad.removeValue(forKey: "position_precision").flatMap(Int.init)
        return NodeTemplate(
            name: draft.name,
            region: region,
            role: role,
            shortNameDSL: draft.shortNameDSL.isEmpty ? nil : draft.shortNameDSL,
            longNameDSL: draft.longNameDSL.isEmpty ? nil : draft.longNameDSL,
            channels: draft.channels
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            positionPrecisionBits: precision,
            firmwareVariant: nil,
            fields: broad
        )
    }

    // MARK: Member selection

    public func toggle(_ nodeNum: Int64) {
        if selected.contains(nodeNum) { selected.remove(nodeNum) } else { selected.insert(nodeNum) }
    }

    public func selectAllVisible() {
        selected.formUnion(visibleCandidates.map(\.nodeNum))
    }

    public func clearSelection() {
        selected.removeAll()
    }

    /// Whether a rollout can be started (a target set + a connectable region).
    public var canRollOut: Bool {
        !selected.isEmpty && !draft.region.isEmpty
    }

    // MARK: Preview + rollout

    /// Build a rollout for the current draft + selected members, dry-run it, and keep
    /// it as `rollout` so the view shows per-node diffs before any change is applied.
    public func preview() async {
        let viewModel = buildRollout()
        rollout = viewModel
        await viewModel.preview()
    }

    /// Roll the current draft out across the selected members (verify-each-then-next).
    public func startRollout() {
        if rollout == nil { rollout = buildRollout() }
        rollout?.startRollout()
    }

    public func abort() {
        rollout?.abort()
    }

    private func buildRollout() -> FleetRolloutViewModel {
        syncFormIntoDraft() // carry the broad-config edits into the template a rollout applies
        let chosen = Self.dedupByNodeNum(candidates.filter { selected.contains($0.nodeNum) })
        let members = chosen.map { candidate in
            FleetMember(
                nodeNum: candidate.nodeNum,
                context: NamingContext(
                    id: candidate.hexid,
                    shortName: candidate.shortName,
                    longName: candidate.longName,
                    region: nil,
                    role: candidate.role
                )
            )
        }
        let names = Dictionary(uniqueKeysWithValues: chosen.map { ($0.nodeNum, $0.name) })
        return FleetRolloutViewModel(
            channelFor: channelFor,
            template: currentTemplate(),
            members: members,
            names: names,
            haltOnFailure: haltOnFailure
        )
    }

    /// Keep the first candidate per `nodeNum`. A node can appear twice in
    /// `candidates` (e.g. discovered AND also a stored row); without this, keying
    /// the rollout's `names` Dictionary by `nodeNum` would trap on the duplicate,
    /// and two rollout rows would be built for one node.
    nonisolated static func dedupByNodeNum(_ candidates: [MemberCandidate]) -> [MemberCandidate] {
        var seen: Set<Int64> = []
        return candidates.filter { seen.insert($0.nodeNum).inserted }
    }

    nonisolated static func hexID(_ nodeNum: Int64) -> String {
        NodeID.hex(UInt32(truncatingIfNeeded: nodeNum))
    }
}
