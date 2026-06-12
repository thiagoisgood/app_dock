import Foundation
import SwiftUI

enum AppSource: String, Codable, CaseIterable {
    case system
    case appStore
    case thirdParty
    case unknown

    var displayLabel: String {
        switch self {
        case .system: return "系统"
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
    case recentlyUsed = "最近常用"

    var id: String { rawValue }
}

enum AppScopeFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case highRisk = "高风险"
    case thirdParty = "第三方"
    case sensitivePermissions = "敏感权限"
    case background = "后台常驻"
    case unsigned = "签名异常"
    case updates = "可更新"

    var id: String { rawValue }
}

enum AppSortOrder: String, CaseIterable, Identifiable {
    case risk = "风险优先"
    case cpu = "CPU"
    case memory = "内存"
    case size = "体积"
    case name = "名称"
    case source = "来源"

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

/// 报告统计摘要
struct ReportStats {
    var totalApps: Int = 0
    var highRisk: Int = 0
    var unsigned: Int = 0
    var bgResident: Int = 0
}

// MARK: - 搜索相关类型

enum SearchIntent: String, Codable {
    case general, specificName, category, action, unknown
}

enum IntentFilter: Hashable {
    case risky
    case background
    case heavyResource
    case unsignedHighRisk
    case hasPermission(PermissionKind)
    case isSystem
    case isAppStore
    case isThirdParty
}

struct SearchFeedbackEvent: Codable, Identifiable {
    let id: UUID
    let query: String
    let intent: SearchIntent
    let resultCount: Int
    let clickedApp: String?
    let clickedIndex: Int?
    let clickDelay: TimeInterval?
    let timestamp: Date
    let hasResults: Bool

    init(id: UUID = UUID(), query: String, intent: SearchIntent, resultCount: Int, clickedApp: String?, clickedIndex: Int?, clickDelay: TimeInterval?, timestamp: Date = Date(), hasResults: Bool) {
        self.id = id
        self.query = query
        self.intent = intent
        self.resultCount = resultCount
        self.clickedApp = clickedApp
        self.clickedIndex = clickedIndex
        self.clickDelay = clickDelay
        self.timestamp = timestamp
        self.hasResults = hasResults
    }
}

struct SearchLearningStats: Codable {
    var totalQueries: Int = 0
    var totalClicks: Int = 0
    var avgClickPosition: Double = 0.0
    var avgClickDelay: TimeInterval = 0.0
    var failedQueries: Int = 0
    var lastUpdated: Date = Date()
    var clickRate: Double {
        guard totalQueries > 0 else { return 0 }
        return Double(totalClicks) / Double(totalQueries) * 100
    }
}

struct SearchWeights: Codable {
    var tagWeight: Double = 3.0
    var mappingWeight: Double = 5.0
    var bundleIDWeight: Double = 4.0
    var nameWeight: Double = 2.0
    var permissionHintWeight: Double = 1.0
    var exactNameBonus: Double = 10.0
    var feedbackBoost: Double = 2.0

    mutating func clamp(min: Double = 0.5, max: Double = 15.0) {
        tagWeight = Swift.max(min, Swift.min(max, tagWeight))
        mappingWeight = Swift.max(min, Swift.min(max, mappingWeight))
        bundleIDWeight = Swift.max(min, Swift.min(max, bundleIDWeight))
        nameWeight = Swift.max(min, Swift.min(max, nameWeight))
        permissionHintWeight = Swift.max(min, Swift.min(max, permissionHintWeight))
        exactNameBonus = Swift.max(min, Swift.min(max, exactNameBonus))
        feedbackBoost = Swift.max(min, Swift.min(max, feedbackBoost))
    }
}

struct SearchMatchHint: Hashable, Identifiable {
    let id: String
    let displayText: String
    let color: Color
}

struct SearchResult: Identifiable, Hashable {
    let id: UUID
    let app: AppRecord
    let hints: [SearchMatchHint]
    let score: Int
}

extension PermissionKind {
    var displayLabel: String {
        switch self {
        case .camera: return "摄像头"
        case .microphone: return "麦克风"
        case .location: return "定位"
        case .fullDiskAccess: return "完全磁盘访问"
        case .accessibility: return "辅助功能"
        case .screenRecording: return "屏幕录制"
        }
    }

    var systemImage: String {
        switch self {
        case .camera: return "camera"
        case .microphone: return "mic"
        case .location: return "location"
        case .fullDiskAccess: return "externaldrive.badge.shield.check"
        case .accessibility: return "figure.wave"
        case .screenRecording: return "rectangle.on.rectangle"
        }
    }
}

extension PermissionGrantState {
    var displayLabel: String {
        switch self {
        case .notDetermined: return "未请求"
        case .authorized: return "已授权"
        case .denied: return "已拒绝"
        case .restricted: return "受限"
        case .unavailable: return "不可读取"
        }
    }
}

extension SignatureTrustLevel {
    var displayLabel: String {
        switch self {
        case .trusted: return "可信签名"
        case .signedUnknown: return "签名未知"
        case .unsignedHighRisk: return "未签名"
        }
    }
}

extension AuditRiskLevel {
    var displayLabel: String {
        switch self {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }
}
