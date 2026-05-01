import Foundation

struct SanitizedJsonBuilder {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    func buildPayload(from apps: [AppRecord], maxBytes: Int = 1024) -> Data {
        var dtos = apps.map { app in
            SanitizedAppDTO(
                name: app.name,
                version: app.version,
                source: app.source,
                sizeMB: Int(app.sizeBytes / 1_048_576),
                cpuPercent: app.metrics.cpuPercent,
                backgroundResident: app.permissions.backgroundResident,
                permissionTags: Array(app.permissions.requested).sorted(by: { $0.rawValue < $1.rawValue })
            )
        }

        while !dtos.isEmpty {
            if let data = try? encoder.encode(dtos), data.count <= maxBytes {
                return data
            }
            dtos.removeLast()
        }
        return Data("[]".utf8)
    }
}
