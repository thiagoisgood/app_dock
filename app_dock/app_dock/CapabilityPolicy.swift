import Foundation

enum AppFlavor: String {
    case direct
    case mas
}

struct CapabilityPolicy {
    let flavor: AppFlavor
    let featureAvailability: [CapabilityFeature: Bool]

    static var current: CapabilityPolicy {
#if APP_FLAVOR_DIRECT
        return CapabilityPolicy(
            flavor: .direct,
            featureAvailability: [
                .tccRead: true,
                .signatureDeepAudit: true,
                .uninstallDelete: true,
                .updateProbe: true
            ]
        )
#elseif APP_FLAVOR_MAS
        return CapabilityPolicy(
            flavor: .mas,
            featureAvailability: [
                .tccRead: false,
                .signatureDeepAudit: true,
                .uninstallDelete: false,
                .updateProbe: true
            ]
        )
#else
        // Default local builds are full-capability direct builds.
        return CapabilityPolicy(
            flavor: .direct,
            featureAvailability: [
                .tccRead: true,
                .signatureDeepAudit: true,
                .uninstallDelete: true,
                .updateProbe: true
            ]
        )
#endif
    }

    func isEnabled(_ feature: CapabilityFeature) -> Bool {
        featureAvailability[feature] ?? false
    }

    func status(for feature: CapabilityFeature) -> CapabilityStatus {
        let available = isEnabled(feature)
        return CapabilityStatus(
            feature: feature,
            available: available,
            reason: available
                ? "可用"
                : "当前构建版本 (\(flavor.rawValue.uppercased())) 已禁用该能力"
        )
    }
}
