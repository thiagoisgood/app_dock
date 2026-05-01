import Foundation
import Combine

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var apps: [AppRecord] = []
    @Published var searchText: String = ""
    @Published var groupingMode: ListGroupingMode = .bySource
    @Published var listSections: [AppListSection] = []
    @Published var findings: [AppRiskFinding] = []
    @Published var aiDigest: String = ""
    @Published var updateSuggestions: [UpdateSuggestion] = []
    @Published var isLoading = false
    @Published var showSettings = false
    @Published var apiKey: String = ""
    @Published var baseURL: String = "https://api.openai.com/v1"
    @Published var model: String = "gpt-4o-mini"
    @Published var capabilityStatuses: [CapabilityStatus] = []
    @Published var flavor: AppFlavor = CapabilityPolicy.current.flavor

    private let pipeline = AuditPipeline()
    private let aiRouter = AIProviderRouter()
    private let updateService = UpdateAdvisorService()
    private let riskEngine = PermissionHeuristicsEngine()
    private let categoryClassifier = AppCategoryClassifier()
    private var lastGoodAIExplanation: String = ""

    func bootstrap() async {
        isLoading = true
        let output = await pipeline.run()
        apps = output.0
        capabilityStatuses = output.1
        findings = buildRiskFindings(for: apps)
        rebuildListSections()
        updateSuggestions = await updateService.suggest(for: apps)
        await runAIDigest()
        isLoading = false
    }

    func applySearchAndGrouping() {
        rebuildListSections()
    }

    func runAIDigest() async {
        guard !apps.isEmpty else { return }
        let config = AIProviderConfig(
            apiKey: apiKey,
            baseURL: baseURL.isEmpty ? "https://api.openai.com/v1" : baseURL,
            model: model.isEmpty ? "gpt-4o-mini" : model,
            temperature: 0.2,
            maxTokens: 240
        )
        let prompt = "请按来源、类别、后台常驻情况给出应用整理摘要，并附1条简单审计提醒。"
        let (_, explanation) = await aiRouter.execute(query: prompt, apps: filteredApps(), config: config)
        if explanation.contains("AI 调用失败") {
            aiDigest = lastGoodAIExplanation.isEmpty ? explanation : "\(explanation)\n(已回退展示最近一次成功结果)"
        } else {
            lastGoodAIExplanation = explanation
            aiDigest = explanation
        }
    }

    var appStoreBytes: Int64 {
        apps.filter { $0.source == .appStore }.map(\.sizeBytes).reduce(0, +)
    }

    var thirdPartyBytes: Int64 {
        apps.filter { $0.source == .thirdParty }.map(\.sizeBytes).reduce(0, +)
    }

    var summaryText: String {
        let backgroundCount = apps.filter { $0.permissions.backgroundResident }.count
        return "总计 \(apps.count) 个应用，后台常驻 \(backgroundCount) 个。"
    }

    func triggerPrimaryAction() {
        applySearchAndGrouping()
        Task { await runAIDigest() }
    }

    private func buildRiskFindings(for apps: [AppRecord]) -> [AppRiskFinding] {
        apps.compactMap { app in
            let signals = riskEngine.evaluate(app: app)
            guard let topSignal = signals.max(by: { rank($0.level) < rank($1.level) }) else {
                return nil
            }
            return AppRiskFinding(
                appName: app.name,
                level: topSignal.level,
                reason: topSignal.reason,
                signals: signals
            )
        }
        .prefix(12)
        .map { $0 }
    }

    private func filteredApps() -> [AppRecord] {
        let key = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return apps }
        return apps.filter { app in
            app.name.lowercased().contains(key)
                || (app.bundleID?.lowercased().contains(key) ?? false)
                || app.path.lowercased().contains(key)
        }
    }

    private func rebuildListSections() {
        let visible = filteredApps()
        switch groupingMode {
        case .bySource:
            let grouped = Dictionary(grouping: visible) { $0.source.rawValue }
            listSections = grouped.keys.sorted().map { key in
                AppListSection(title: key, apps: grouped[key, default: []].sorted(by: { $0.name < $1.name }))
            }
        case .byCategory:
            let grouped = Dictionary(grouping: visible) { categoryClassifier.category(for: $0).rawValue }
            listSections = grouped.keys.sorted().map { key in
                AppListSection(title: key, apps: grouped[key, default: []].sorted(by: { $0.name < $1.name }))
            }
        case .byResidency:
            let grouped = Dictionary(grouping: visible) { $0.permissions.backgroundResident ? "后台常驻" : "前台/按需运行" }
            listSections = grouped.keys.sorted().map { key in
                AppListSection(title: key, apps: grouped[key, default: []].sorted(by: { $0.name < $1.name }))
            }
        }
    }

    private func rank(_ level: AuditRiskLevel) -> Int {
        switch level {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

}
