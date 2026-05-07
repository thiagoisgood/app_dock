import Foundation

enum AppSource: String, Codable, CaseIterable {
    case appStore
    case thirdParty
    case unknown

    var displayLabel: String {
        switch self {
        case .appStore: return "App Store"
        case .thirdParty: return "第三方"
        case .unknown: return "未知"
        }
    }
}

enum SignatureTrustLevel: String, Codable {
    case trusted
    case signedUnknown
    case unsignedHighRisk
}

enum PermissionKind: String, Codable, CaseIterable, Hashable {
    case camera
    case microphone
    case location
    case fullDiskAccess
    case accessibility
    case screenRecording
}

enum PermissionGrantState: String, Codable, Hashable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable
}

struct PermissionEvidence: Codable, Hashable {
    let kind: PermissionKind
    let declaredInInfoPlist: Bool
    let tccState: PermissionGrantState
    let checkedAt: Date
    let note: String?
}

struct RiskSignal: Codable, Hashable, Identifiable {
    let id = UUID()
    let code: String
    let level: AuditRiskLevel
    let reason: String

    enum CodingKeys: String, CodingKey {
        case code
        case level
        case reason
    }
}

struct SignatureInfo: Codable, Hashable {
    let teamID: String?
    let commonName: String?
    let signingAuthority: [String]
    let trustLevel: SignatureTrustLevel
}

struct PermissionAudit: Codable, Hashable {
    let requested: Set<PermissionKind>
    let backgroundResident: Bool
    let evidence: [PermissionEvidence]
}

struct RuntimeMetrics: Codable, Hashable {
    let cpuPercent: Double
    let memoryMB: Double
}

struct AppRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let bundleID: String?
    let name: String
    let version: String
    let path: String
    let sizeBytes: Int64
    let source: AppSource
    let signature: SignatureInfo
    let permissions: PermissionAudit
    let metrics: RuntimeMetrics

    var sizeMB: Int {
        Int(sizeBytes / 1_048_576)
    }
}

struct SanitizedAppDTO: Codable, Hashable {
    let name: String
    let version: String
    let source: AppSource
    let sizeMB: Int
    let cpuPercent: Double
    let backgroundResident: Bool
    let permissionTags: [PermissionKind]
}

struct SemanticQueryResult: Hashable {
    let title: String
    let summary: String
    let appNames: [String]
}

enum AuditRiskLevel: String, Codable {
    case low
    case medium
    case high
}

struct AppRiskFinding: Hashable, Identifiable {
    let id = UUID()
    let appName: String
    let level: AuditRiskLevel
    let reason: String
    let signals: [RiskSignal]
}

enum ListGroupingMode: String, CaseIterable, Identifiable {
    case bySource = "来源"
    case byCategory = "类别"
    case byResidency = "后台常驻"
    case byAI = "AI 整理"
    case recentlyUsed = "最近常用"

    var id: String { rawValue }
}

struct AppListSection: Identifiable, Hashable {
    var id: String { title }
    let title: String
    let apps: [AppRecord]
}

enum CapabilityFeature: String, CaseIterable, Hashable {
    case tccRead
    case signatureDeepAudit
    case uninstallDelete
    case updateProbe
}

struct CapabilityStatus: Hashable, Identifiable {
    let id = UUID()
    let feature: CapabilityFeature
    let available: Bool
    let reason: String
}

struct AIOrganizationResponse: Codable {
    let appCategories: [String: String]
    let categoryDescriptions: [String: String]
}

enum AIProviderError: Error, LocalizedError {
    case invalidBaseURL
    case network(String)
    case unauthorized
    case rateLimited
    case badRequest(String)
    case decodeFailure
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "Base URL 无效"
        case let .network(message): return "网络错误: \(message)"
        case .unauthorized: return "API Key 无效或权限不足"
        case .rateLimited: return "请求频率过高，请稍后重试"
        case let .badRequest(message): return "请求参数错误: \(message)"
        case .decodeFailure: return "模型响应解析失败"
        case let .serverError(code): return "服务端异常 (HTTP \(code))"
        }
    }
}
