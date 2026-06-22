// FleetTemplateMapping — maps a persisted `TemplateRecord` ⇄ `Provisioning.NodeTemplate`
// and the editor draft. Kept out of `FleetConfigViewModel`'s body so the engine model
// stays focused. The non-secret extra fields (DSLs, channels, precision) ride in the
// record's `config_json`; name/region/role/firmware map to columns directly.

import Foundation
import Persistence
import Provisioning

extension FleetConfigViewModel {
    /// The non-column template state, persisted as the record's `config_json`. The
    /// broad `fields` (every LoRa/Device/Position/… knob keyed by
    /// `AdminConfigField.rawValue`) ride here alongside the legacy DSL/channel/precision
    /// extras. `fields` defaults empty on decode so pre-Phase-10 rows (no broad config)
    /// load unchanged.
    private struct TemplatePayload: Codable {
        var shortNameDSL: String?
        var longNameDSL: String?
        var channels: [String]
        var positionPrecisionBits: Int?
        var fields: [String: String]?
    }

    static func template(from record: TemplateRecord) -> NodeTemplate {
        let payload = record.config_json
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(TemplatePayload.self, from: $0) }
        return NodeTemplate(
            name: record.name,
            region: record.region,
            role: record.role,
            shortNameDSL: payload?.shortNameDSL ?? (record.dsl.isEmpty ? nil : record.dsl),
            longNameDSL: payload?.longNameDSL,
            channels: payload?.channels ?? [],
            positionPrecisionBits: payload?.positionPrecisionBits,
            firmwareVariant: record.firmware_variant,
            fields: payload?.fields ?? [:]
        )
    }

    static func record(from template: NodeTemplate, id: Int64?) -> TemplateRecord {
        let payload = TemplatePayload(
            shortNameDSL: template.shortNameDSL,
            longNameDSL: template.longNameDSL,
            channels: template.channels,
            positionPrecisionBits: template.positionPrecisionBits,
            fields: template.fields.isEmpty ? nil : template.fields
        )
        let json = (try? JSONEncoder().encode(payload)).flatMap { String(bytes: $0, encoding: .utf8) }
        return TemplateRecord(
            id: id,
            name: template.name,
            dsl: template.shortNameDSL ?? "",
            region: template.region,
            role: template.role,
            config_json: json,
            firmware_variant: template.firmwareVariant
        )
    }

    static func draft(from template: NodeTemplate) -> TemplateDraft {
        // Fold the typed named surface (region/role/precision) back into the draft's
        // broad `fields` so the editor drives them through the same shared form; the
        // remaining broad fields carry across verbatim.
        var fields = template.fields
        fields["region"] = template.region
        if let role = template.role { fields["role"] = role }
        if let precision = template.positionPrecisionBits {
            fields["position_precision"] = String(precision)
        }
        return TemplateDraft(
            name: template.name,
            shortNameDSL: template.shortNameDSL ?? "",
            longNameDSL: template.longNameDSL ?? "",
            channels: template.channels.joined(separator: ", "),
            fields: fields
        )
    }
}
