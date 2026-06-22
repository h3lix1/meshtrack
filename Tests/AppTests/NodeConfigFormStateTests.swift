// NodeConfigFormStateTests — the broad per-node config form's edit state (Phase 10).
//
// `NodeConfigFormState` seeds from a node's current snapshot and emits only the
// fields the operator actually changed, so an apply diffs a minimal set through the
// admin pipeline. These tests prove that seeding, the changed-field delta, the
// toggle helper, and the field keys all line up with `AdminConfigField.rawValue`.

@testable import App
import Provisioning
import Testing

@Suite("NodeConfigFormState — broad config form edits (Phase 10)")
@MainActor
struct NodeConfigFormStateTests {
    @Test
    func `an unchanged form yields no changed fields`() {
        let state = NodeConfigFormState(baseline: ["region": "US", "role": "CLIENT"])
        #expect(state.changedFields.isEmpty)
    }

    @Test
    func `changing a field surfaces only that field`() {
        let state = NodeConfigFormState(baseline: ["region": "US", "role": "CLIENT"])
        state.set("ROUTER", for: "role")
        #expect(state.changedFields == ["role": "ROUTER"])
    }

    @Test
    func `toggling a boolean field flips and surfaces it`() {
        let state = NodeConfigFormState(baseline: ["mqtt_enabled": "false"])
        state.toggle("mqtt_enabled")
        #expect(state.value(for: .init("mqtt_enabled", "MQTT", .toggle)) == "true")
        #expect(state.changedFields == ["mqtt_enabled": "true"])
        state.toggle("mqtt_enabled")
        #expect(state.changedFields.isEmpty) // back to baseline
    }

    @Test
    func `setting a new field not in the baseline counts as a change`() {
        let state = NodeConfigFormState(baseline: [:])
        state.set("16", for: "position_precision")
        #expect(state.changedFields == ["position_precision": "16"])
    }

    @Test
    func `value falls back to the control's sensible default when unseeded`() {
        let state = NodeConfigFormState(baseline: [:])
        #expect(state.value(for: .init("region", "Region", .choice(options: ["US", "EU_868"]))) == "US")
        #expect(state.value(for: .init("mqtt_enabled", "MQTT", .toggle)) == "false")
        #expect(state.value(for: .init("wifi_ssid", "SSID", .text(numeric: false))) == "")
    }

    @Test
    func `every form field key is a real AdminConfigField`() {
        // The form is the UI mirror of the registry; a typo'd key would silently fail
        // to apply (`AdminMessageMapping` would throw `unsupportedField`).
        for spec in NodeConfigForm.allFields {
            #expect(
                AdminConfigField(rawValue: spec.key) != nil,
                "form field \(spec.key) has no matching AdminConfigField"
            )
        }
    }

    @Test
    func `the changed fields flow into a NodeConfigEdit unchanged`() {
        let state = NodeConfigFormState(baseline: ["region": "US"])
        state.set("EU_868", for: "region")
        state.set("true", for: "mqtt_enabled")
        let edit = NodeConfigEdit(nodeNum: 7, name: "BMSH", fields: state.changedFields)
        #expect(edit.nodeNum == 7)
        #expect(edit.region == "EU_868")
        #expect(edit.fields["mqtt_enabled"] == "true")
    }

    @Test
    func `the legacy NodeConfigEdit initializer still works and folds into fields`() {
        let edit = NodeConfigEdit(nodeNum: 1, name: "n", region: "US", role: "ROUTER")
        #expect(edit.region == "US")
        #expect(edit.role == "ROUTER")
        #expect(edit.fields == ["region": "US", "role": "ROUTER"])
    }
}
