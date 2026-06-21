// FleetTemplateMapping — maps a persisted `TemplateRecord` ⇄ `Provisioning.NodeTemplate`
// and the editor draft. Kept out of `FleetConfigViewModel`'s body so the engine model
// stays focused. The non-secret extra fields (DSLs, channels, precision) ride in the
// record's `config_json`; name/region/role/firmware map to columns directly.

import Foundation
import Persistence
import Provisioning

extension FleetConfigViewModel {
    private struct TemplatePayload: Codable {
        var shortNameDSL: String?
        var longNameDSL: String?
        var channels: [String]
        var positionPrecisionBits: Int?
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
            firmwareVariant: record.firmware_variant
        )
    }

    static func record(from template: NodeTemplate, id: Int64?) -> TemplateRecord {
        let payload = TemplatePayload(
            shortNameDSL: template.shortNameDSL,
            longNameDSL: template.longNameDSL,
            channels: template.channels,
            positionPrecisionBits: template.positionPrecisionBits
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
        TemplateDraft(
            name: template.name,
            region: template.region,
            role: template.role ?? "",
            shortNameDSL: template.shortNameDSL ?? "",
            longNameDSL: template.longNameDSL ?? "",
            channels: template.channels.joined(separator: ", "),
            positionPrecision: template.positionPrecisionBits.map(String.init) ?? ""
        )
    }
}
