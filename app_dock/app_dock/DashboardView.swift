import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var previousSearchText = ""

    var body: some View {
        VStack(spacing: 0) {
            AuditToolbar(viewModel: viewModel)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)

            Divider()

            HStack(spacing: 0) {
                AuditSidebar(viewModel: viewModel)
                    .frame(width: 230)

                Divider()

                AuditListPane(
                    viewModel: viewModel,
                    previousSearchText: $previousSearchText
                )
                .frame(minWidth: 620)

                Divider()

                AppInspectorPane(viewModel: viewModel)
                    .frame(width: 360)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showAIReport) {
            AIReportSheet(
                report: viewModel.aiReport,
                generatedAt: viewModel.reportGeneratedAt,
                stats: viewModel.reportStats
            )
        }
    }
}

// MARK: - Toolbar

private struct AuditToolbar: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("AppDock Audit")
                    .font(.title2.weight(.semibold))
                Text(viewModel.isLoading ? "正在扫描 macOS 应用..." : viewModel.healthSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            CapabilityPill(flavor: viewModel.flavor)

            if viewModel.tokenUsageSummary.totalTokens > 0 {
                Label("\(viewModel.tokenUsageSummary.totalTokens) tokens · $\(String(format: "%.4f", viewModel.tokenUsageSummary.totalCost))", systemImage: "chart.bar.doc.horizontal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.6), in: Capsule())
            }

            Button {
                Task { await viewModel.refresh() }
            } label: {
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if !viewModel.apiKey.isEmpty {
                Button {
                    Task { await viewModel.runAIOrganization() }
                } label: {
                    if viewModel.isOrganizing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("AI 分类", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    Task { await viewModel.runAIReport() }
                } label: {
                    if viewModel.isGeneratingReport {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("报告", systemImage: "doc.text.magnifyingglass")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Button {
                viewModel.showSettings = true
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

private struct CapabilityPill: View {
    let flavor: AppFlavor

    var body: some View {
        Label(flavor == .mas ? "MAS" : "DIRECT", systemImage: flavor == .mas ? "lock" : "bolt.shield")
            .font(.caption.weight(.medium))
            .foregroundStyle(flavor == .mas ? .orange : .teal)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background((flavor == .mas ? Color.orange : Color.teal).opacity(0.12), in: Capsule())
    }
}

// MARK: - Sidebar

private struct AuditSidebar: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("审计范围")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                ForEach(AppScopeFilter.allCases) { filter in
                    ScopeRow(
                        filter: filter,
                        count: count(for: filter),
                        selected: viewModel.scopeFilter == filter
                    ) {
                        viewModel.scopeFilter = filter
                        viewModel.applySearchAndGrouping()
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("分组")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Picker("", selection: $viewModel.groupingMode) {
                    ForEach(ListGroupingMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                .disabled(viewModel.hasActiveSearch)
                .onChange(of: viewModel.groupingMode) { _ in
                    viewModel.applySearchAndGrouping()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("能力状态")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                ForEach(viewModel.capabilityStatuses) { status in
                    HStack(spacing: 8) {
                        Image(systemName: status.available ? "checkmark.circle.fill" : "minus.circle.fill")
                            .foregroundStyle(status.available ? .green : .secondary)
                        Text(status.feature.displayLabel)
                            .lineLimit(1)
                        Spacer()
                    }
                    .font(.caption)
                    .help(status.reason)
                }
            }

            Spacer()

            if viewModel.searchLearningStats.totalQueries > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    Label("搜索学习", systemImage: "brain.head.profile")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.teal)
                    Text("\(viewModel.searchLearningStats.totalQueries) 次查询 · \(Int(viewModel.searchLearningStats.clickRate))% 命中")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(14)
        .background(.bar)
    }

    private func count(for filter: AppScopeFilter) -> Int {
        viewModel.count(for: filter)
    }
}

private struct ScopeRow: View {
    let filter: AppScopeFilter
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: filter.systemImage)
                    .frame(width: 17)
                    .foregroundStyle(selected ? .white : filter.tint)
                Text(filter.rawValue)
                    .font(.callout)
                    .foregroundStyle(selected ? .white : .primary)
                Spacer()
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selected ? .white.opacity(0.9) : .secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Main List

private struct AuditListPane: View {
    @ObservedObject var viewModel: DashboardViewModel
    @Binding var previousSearchText: String
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HealthSummaryStrip(viewModel: viewModel)

                HStack(spacing: 10) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("搜索应用名、标签、Bundle ID 或输入自然语言查询", text: $viewModel.searchText)
                            .textFieldStyle(.plain)
                            .focused($searchFocused)
                            .onChange(of: viewModel.searchText) { _ in
                                if !previousSearchText.isEmpty && viewModel.searchText.isEmpty {
                                    Task { @MainActor in viewModel.recordSearchNoClick() }
                                }
                                previousSearchText = viewModel.searchText
                                viewModel.scheduleSearchAndGrouping()
                            }
                            .onAppear {
                                previousSearchText = viewModel.searchText
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    searchFocused = true
                                }
                            }
                        Group {
                            if viewModel.isSearchLoading {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: 14, height: 14)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

                }

                if viewModel.isAIProcessing {
                    StatusBanner(systemImage: "sparkles", text: viewModel.aiProcessingProgress, active: true)
                } else if !viewModel.aiAssistantText.isEmpty {
                    Button {
                        viewModel.showAIReport = true
                    } label: {
                        StatusBanner(systemImage: "text.bubble", text: viewModel.aiAssistantText, active: false)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)

            AuditTableHeader()

            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(viewModel.listSections) { section in
                        Section {
                            ForEach(section.apps) { app in
                                AuditAppRow(
                                    viewModel: viewModel,
                                    app: app,
                                    selected: viewModel.selectedAppID == app.id,
                                    riskScore: viewModel.riskScore(for: app),
                                    riskLevel: viewModel.riskLevel(for: app),
                                    category: viewModel.resolvedCategory(for: app),
                                    tags: viewModel.appTags[app.name] ?? [],
                                    hints: viewModel.searchHints(for: app),
                                    hasUpdate: viewModel.hasUpdateSuggestion(for: app)
                                ) {
                                    if !viewModel.searchText.isEmpty,
                                       let idx = viewModel.searchResults.firstIndex(where: { $0.app.id == app.id }) {
                                        viewModel.recordSearchClick(app: app, resultIndex: idx)
                                    }
                                    viewModel.selectApp(app)
                                }
                            }
                        } header: {
                            HStack {
                                Text("\(section.title) · \(section.apps.count)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(.bar)
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollContentBackground(.hidden)
        }
    }
}

private struct HealthSummaryStrip: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        HStack(spacing: 10) {
            MetricTile(
                title: "健康分",
                value: "\(viewModel.healthScore)",
                subtitle: viewModel.healthSummary,
                color: viewModel.healthScore >= 85 ? .green : (viewModel.healthScore >= 65 ? .orange : .red),
                systemImage: "shield.lefthalf.filled"
            )
            MetricTile(title: "高风险", value: "\(viewModel.highRiskCount)", subtitle: "优先处理", color: .red, systemImage: "exclamationmark.triangle.fill")
            MetricTile(title: "签名异常", value: "\(viewModel.unsignedCount)", subtitle: "未知或未签名", color: .orange, systemImage: "signature")
            MetricTile(title: "敏感权限", value: "\(viewModel.sensitivePermissionAppCount)", subtitle: "高敏访问", color: .teal, systemImage: "hand.raised.fill")
            MetricTile(title: "后台常驻", value: "\(viewModel.backgroundCount)", subtitle: "资源与隐私", color: .purple, systemImage: "clock.arrow.circlepath")
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let subtitle: String
    let color: Color
    let systemImage: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(minWidth: 112, maxWidth: .infinity, minHeight: 74)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct StatusBanner: View {
    let systemImage: String
    let text: String
    let active: Bool

    var body: some View {
        HStack(spacing: 9) {
            if active {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .foregroundStyle(.teal)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if !active {
                Text("查看报告")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.teal)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AuditTableHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("应用")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("风险")
                .frame(width: 72, alignment: .leading)
            Text("来源")
                .frame(width: 78, alignment: .leading)
            Text("签名")
                .frame(width: 92, alignment: .leading)
            Text("权限")
                .frame(width: 86, alignment: .leading)
            Text("资源")
                .frame(width: 90, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

private struct AuditAppRow: View {
    @ObservedObject var viewModel: DashboardViewModel
    let app: AppRecord
    let selected: Bool
    let riskScore: Int
    let riskLevel: AuditRiskLevel?
    let category: String
    let tags: [String]
    let hints: [SearchMatchHint]
    let hasUpdate: Bool
    let action: () -> Void
    @State private var showTagEditor = false
    @State private var showCategoryPicker = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    AppIconView(path: app.path, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(app.name)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            if hasUpdate {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                                    .help("发现更新建议")
                            }
                        }
                        HStack(spacing: 5) {
                            Text(category)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            ForEach(tags.prefix(2), id: \.self) { tag in
                                Text(tag)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.teal)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.teal.opacity(0.10), in: Capsule())
                            }
                            ForEach(hints.prefix(1)) { hint in
                                Text(hint.displayText)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(hint.color)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                RiskBadge(score: riskScore, level: riskLevel)
                    .frame(width: 72, alignment: .leading)

                Text(app.source.displayLabel)
                    .font(.caption)
                    .foregroundStyle(app.source.tint)
                    .frame(width: 78, alignment: .leading)

                Text(app.signature.trustLevel.displayLabel)
                    .font(.caption)
                    .foregroundStyle(app.signature.trustLevel.tint)
                    .frame(width: 92, alignment: .leading)

                PermissionMiniStack(app: app)
                    .frame(width: 86, alignment: .leading)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(String(format: "%.1f", app.metrics.cpuPercent))%")
                    Text("\(Int(app.metrics.memoryMB)) MB")
                        .foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
                .frame(width: 90, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(selected ? Color.accentColor.opacity(0.16) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("打开应用") {
                viewModel.recordAppOpen(app)
                openApp(app)
            }
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
            }
            Divider()
            Button("编辑标签...") { showTagEditor = true }
            Button("修改类别...") { showCategoryPicker = true }
        }
        .popover(isPresented: $showTagEditor) {
            TagEditorView(appName: app.name, tags: tags, viewModel: viewModel)
        }
        .popover(isPresented: $showCategoryPicker) {
            CategoryPickerView(
                appName: app.name,
                bundleID: app.bundleID,
                currentCategory: category,
                viewModel: viewModel
            )
        }
    }
}

private struct RiskBadge: View {
    let score: Int
    let level: AuditRiskLevel?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill((level ?? .low).tint)
                .frame(width: 7, height: 7)
            Text(level?.displayLabel ?? "低")
                .font(.caption.weight(.semibold))
            Text("\(score)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background((level ?? .low).tint.opacity(0.10), in: Capsule())
    }
}

private struct PermissionMiniStack: View {
    let app: AppRecord

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(app.permissions.requested.prefix(3)), id: \.self) { permission in
                Image(systemName: permission.systemImage)
                    .font(.caption)
                    .foregroundStyle(permission.sensitiveTint)
                    .help(permission.displayLabel)
            }
            if app.permissions.requested.count > 3 {
                Text("+\(app.permissions.requested.count - 3)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if app.permissions.requested.isEmpty {
                Text("无")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Inspector

private struct AppInspectorPane: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var showTagEditor = false
    @State private var showCategoryPicker = false

    var body: some View {
        Group {
            if let app = viewModel.selectedApp {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        InspectorHeader(app: app, viewModel: viewModel)

                        ActionBar(app: app, viewModel: viewModel)

                        InspectorSection(title: "风险解释", systemImage: "exclamationmark.shield") {
                            RiskDetailView(app: app, viewModel: viewModel)
                        }

                        InspectorSection(title: "身份与签名", systemImage: "signature") {
                            MetadataRows(app: app, viewModel: viewModel)
                        }

                        InspectorSection(title: "权限矩阵", systemImage: "hand.raised") {
                            PermissionMatrix(app: app)
                        }

                        InspectorSection(title: "资源与后台", systemImage: "gauge.with.dots.needle.67percent") {
                            RuntimePanel(app: app)
                        }

                        UpdateSuggestionPanel(app: app, suggestions: viewModel.updateSuggestions)
                        ResidualPreviewPanel(app: app)
                    }
                    .padding(16)
                }
                .background(Color(nsColor: .controlBackgroundColor))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "app.dashed")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("暂无应用")
                        .font(.headline)
                    Text("调整筛选条件或刷新扫描结果。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct InspectorHeader: View {
    let app: AppRecord
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconView(path: app.path, size: 58)
            VStack(alignment: .leading, spacing: 5) {
                Text(app.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(viewModel.resolvedCategory(for: app))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    RiskBadge(score: viewModel.riskScore(for: app), level: viewModel.riskLevel(for: app))
                    Text(app.source.displayLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(app.source.tint)
                }
            }
            Spacer()
        }
    }
}

private struct ActionBar: View {
    let app: AppRecord
    @ObservedObject var viewModel: DashboardViewModel
    @State private var showTagEditor = false
    @State private var showCategoryPicker = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.recordAppOpen(app)
                openApp(app)
            } label: {
                Label("打开", systemImage: "arrow.up.right.square")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
            } label: {
                Label("定位", systemImage: "folder")
            }
            Menu {
                Button("编辑标签...") { showTagEditor = true }
                Button("修改类别...") { showCategoryPicker = true }
            } label: {
                Label("整理", systemImage: "tag")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .popover(isPresented: $showTagEditor) {
            TagEditorView(appName: app.name, tags: viewModel.appTags[app.name] ?? [], viewModel: viewModel)
        }
        .popover(isPresented: $showCategoryPicker) {
            CategoryPickerView(
                appName: app.name,
                bundleID: app.bundleID,
                currentCategory: viewModel.resolvedCategory(for: app),
                viewModel: viewModel
            )
        }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct RiskDetailView: View {
    let app: AppRecord
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        let signals = viewModel.riskSignals(for: app)
        if signals.isEmpty {
            Label("未发现明显风险信号", systemImage: "checkmark.shield")
                .font(.callout)
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(signals) { signal in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(signal.level.displayLabel)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(signal.level.tint, in: Capsule())
                            Text(signal.reason)
                                .font(.callout.weight(.medium))
                                .lineLimit(2)
                        }
                        Text(signal.evidenceText(for: app))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(signal.recommendation)
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                    .padding(9)
                    .background(signal.level.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }
}

private struct MetadataRows: View {
    let app: AppRecord
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(spacing: 7) {
            InfoRow(label: "版本", value: app.version)
            InfoRow(label: "Bundle ID", value: app.bundleID ?? "未知")
            InfoRow(label: "类别", value: viewModel.resolvedCategory(for: app))
            InfoRow(label: "签名", value: app.signature.trustLevel.displayLabel, color: app.signature.trustLevel.tint)
            InfoRow(label: "Team ID", value: app.signature.teamID ?? "未提供")
            InfoRow(label: "主体", value: app.signature.commonName ?? "未知")
            InfoRow(label: "体积", value: "\(app.sizeMB) MB")
            InfoRow(label: "路径", value: app.path)
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PermissionMatrix: View {
    let app: AppRecord

    var body: some View {
        VStack(spacing: 7) {
            ForEach(PermissionKind.allCases, id: \.self) { kind in
                let evidence = app.permissions.evidence.first { $0.kind == kind }
                HStack(spacing: 8) {
                    Image(systemName: kind.systemImage)
                        .foregroundStyle(kind.sensitiveTint)
                        .frame(width: 18)
                    Text(kind.displayLabel)
                        .font(.caption)
                    Spacer()
                    Text(evidence?.declaredInInfoPlist == true ? "已声明" : "未声明")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(evidence?.declaredInInfoPlist == true ? .blue : .secondary)
                    Text(evidence?.tccState.displayLabel ?? "未知")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle((evidence?.tccState ?? .unavailable).tint)
                }
            }
        }
    }
}

private struct RuntimePanel: View {
    let app: AppRecord

    var body: some View {
        VStack(spacing: 8) {
            InfoRow(label: "后台", value: app.permissions.backgroundResident ? "是" : "否", color: app.permissions.backgroundResident ? .orange : .secondary)
            InfoRow(label: "CPU", value: "\(String(format: "%.1f", app.metrics.cpuPercent))%")
            InfoRow(label: "内存", value: "\(Int(app.metrics.memoryMB)) MB")
        }
    }
}

private struct UpdateSuggestionPanel: View {
    let app: AppRecord
    let suggestions: [UpdateSuggestion]

    var body: some View {
        let matches = suggestions.filter { $0.appName == app.name }
        if !matches.isEmpty {
            InspectorSection(title: "更新建议", systemImage: "arrow.triangle.2.circlepath") {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(matches) { suggestion in
                        HStack {
                            Text(suggestion.status)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(suggestion.status == "可更新" ? .blue : .secondary)
                            Spacer()
                            Text(suggestion.sourceHint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct ResidualPreviewPanel: View {
    let app: AppRecord
    @State private var candidates: [String] = []

    var body: some View {
        InspectorSection(title: "卸载残留预览", systemImage: "trash") {
            VStack(alignment: .leading, spacing: 8) {
                if candidates.isEmpty {
                    Text("未发现常见残留路径。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(candidates, id: \.self) { path in
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(path.hasPrefix("unavailable") ? .secondary : .primary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }
            }
        }
        .task(id: app.id) {
            candidates = UninstallService().preview(app: app).candidates
        }
    }
}

// MARK: - App Icon

private struct AppIconView: View {
    let path: String
    var size: CGFloat = 20
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
            } else {
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .task(id: path) {
            self.icon = AppIconCache.shared.icon(for: path)
        }
    }
}

// MARK: - Tag Editor

private struct TagEditorView: View {
    let appName: String
    let tags: [String]
    @ObservedObject var viewModel: DashboardViewModel
    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appName)
                .font(.headline)
                .lineLimit(1)

            FlowLayout(spacing: 4) {
                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 2) {
                        Text(tag)
                            .font(.caption)
                        Button {
                            viewModel.removeTag(from: appName, tag: tag)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.teal.opacity(0.15), in: Capsule())
                }
            }

            HStack(spacing: 6) {
                TextField("新标签", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTag)
                Button("添加", action: addTag)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 240)
    }

    private func addTag() {
        viewModel.addTag(to: appName, tag: newTag)
        newTag = ""
    }
}

// MARK: - Category Picker

private struct CategoryPickerView: View {
    let appName: String
    let bundleID: String?
    let currentCategory: String
    @ObservedObject var viewModel: DashboardViewModel
    private let categories = CategorySchema.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appName)
                .font(.headline)
                .lineLimit(1)

            Divider()

            ForEach(categories, id: \.displayName) { category in
                let isSelected = category.displayName == currentCategory
                Button {
                    viewModel.changeCategory(for: appName, bundleID: bundleID, to: category.displayName)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? .blue : .secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.displayName)
                                .font(.body)
                                .foregroundStyle(isSelected ? .blue : .primary)
                            Text(category.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .background(isSelected ? Color.blue.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, offset) in result.offsets.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (offsets: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var offsets: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            offsets.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }
        return (offsets, CGSize(width: maxX, height: y + rowHeight))
    }
}

// MARK: - AI Report Sheet

private struct AIReportSheet: View {
    let report: String
    let generatedAt: Date
    let stats: ReportStats
    @Environment(\.dismiss) private var dismiss
    @State private var contentVisible = false

    private var attributedReport: Text {
        let attr = MarkdownTextBuilder.build(from: report)
        return Text(attr)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 审计报告")
                        .font(.title2.bold())
                    Text("生成时间: \(generatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    copyReport()
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                Button {
                    exportReport()
                } label: {
                    Label("导出", systemImage: "square.and.arrow.down")
                }
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            HStack(spacing: 12) {
                StatBadge(label: "总应用", value: "\(stats.totalApps)", color: .blue)
                StatBadge(label: "高风险", value: "\(stats.highRisk)", color: .red)
                StatBadge(label: "未签名", value: "\(stats.unsigned)", color: .orange)
                StatBadge(label: "后台常驻", value: "\(stats.bgResident)", color: .purple)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                attributedReport
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(contentVisible ? 1 : 0)
                    .offset(y: contentVisible ? 0 : 20)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .onAppear {
            withAnimation(.easeOut(duration: 0.35).delay(0.05)) {
                contentVisible = true
            }
        }
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    private func exportReport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "AppDock-Audit-Report.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? report.write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct StatBadge: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 60)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Settings

private struct SettingsSheet: View {
    @ObservedObject var viewModel: DashboardViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("保存并关闭") {
                    viewModel.saveAPISettings()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            TabView {
                AIProviderSettings(viewModel: viewModel)
                    .tabItem { Label("AI Provider", systemImage: "sparkles") }
                TokenSettings(viewModel: viewModel)
                    .tabItem { Label("Token 成本", systemImage: "chart.bar") }
                SearchMappingSettings(viewModel: viewModel)
                    .tabItem { Label("搜索学习", systemImage: "brain.head.profile") }
                CapabilitySettings(viewModel: viewModel)
                    .tabItem { Label("扫描能力", systemImage: "shield") }
            }
            .padding()
        }
        .frame(width: 560, height: 620)
    }
}

private struct AIProviderSettings: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        Form {
            TextField("API Key", text: $viewModel.apiKey)
            TextField("Base URL", text: $viewModel.baseURL)
            TextField("Model", text: $viewModel.model)
        }
        .formStyle(.grouped)
    }
}

private struct TokenSettings: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsMetric(label: "总 Token", value: "\(viewModel.tokenUsageSummary.totalTokens)")
            SettingsMetric(label: "Prompt Token", value: "\(viewModel.tokenUsageSummary.totalPromptTokens)")
            SettingsMetric(label: "Completion Token", value: "\(viewModel.tokenUsageSummary.totalCompletionTokens)")
            SettingsMetric(label: "总花费", value: "$\(String(format: "%.4f", viewModel.tokenUsageSummary.totalCost))")
            Divider()
            if !viewModel.tokenUsageSummary.operationCounts.isEmpty {
                Text("操作统计")
                    .font(.headline)
                ForEach(viewModel.tokenUsageSummary.operationCounts.keys.sorted(), id: \.self) { op in
                    SettingsMetric(label: op, value: "\(viewModel.tokenUsageSummary.operationCounts[op] ?? 0) 次")
                }
            }
            Spacer()
            HStack {
                Text("最后更新: \(viewModel.tokenUsageSummary.lastUpdated.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清除统计") {
                    viewModel.tokenUsageStore.clearHistory()
                    viewModel.tokenUsageSummary = viewModel.tokenUsageStore.getSummary()
                }
            }
        }
        .padding()
    }
}

private struct SearchMappingSettings: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SettingsMetric(label: "映射数量", value: "\(viewModel.searchMappings.count)")
                Spacer()
                Button {
                    Task { await viewModel.updateSearchMappings() }
                } label: {
                    if viewModel.isUpdatingMappings {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("更新映射", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.isUpdatingMappings || viewModel.apiKey.isEmpty)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.searchMappings.sorted(by: { $0.category < $1.category }), id: \.id) { mapping in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(mapping.category)
                                .font(.callout.weight(.semibold))
                            Text(mapping.keywords.prefix(8).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding()
    }
}

private struct CapabilitySettings: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(viewModel.capabilityStatuses) { status in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: status.available ? "checkmark.circle.fill" : "minus.circle.fill")
                        .foregroundStyle(status.available ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.feature.displayLabel)
                            .font(.callout.weight(.medium))
                        Text(status.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer()
        }
        .padding()
    }
}

private struct SettingsMetric: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
        }
    }
}

// MARK: - Helpers

private func openApp(_ app: AppRecord) {
    let appURL = URL(fileURLWithPath: app.path)
    NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
}

private extension AppScopeFilter {
    var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .highRisk: return "exclamationmark.triangle"
        case .thirdParty: return "shippingbox"
        case .sensitivePermissions: return "hand.raised"
        case .background: return "clock.arrow.circlepath"
        case .unsigned: return "signature"
        case .updates: return "arrow.triangle.2.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .all: return .blue
        case .highRisk: return .red
        case .thirdParty: return .orange
        case .sensitivePermissions: return .teal
        case .background: return .purple
        case .unsigned: return .orange
        case .updates: return .blue
        }
    }
}

private extension AppSource {
    var tint: Color {
        switch self {
        case .system: return .blue
        case .appStore: return .green
        case .thirdParty: return .orange
        case .unknown: return .secondary
        }
    }
}

private extension SignatureTrustLevel {
    var tint: Color {
        switch self {
        case .trusted: return .green
        case .signedUnknown: return .orange
        case .unsignedHighRisk: return .red
        }
    }
}

private extension AuditRiskLevel {
    var tint: Color {
        switch self {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }
}

private extension PermissionKind {
    var sensitiveTint: Color {
        switch self {
        case .camera, .microphone, .screenRecording, .fullDiskAccess, .accessibility:
            return .orange
        case .location:
            return .blue
        }
    }
}

private extension PermissionGrantState {
    var tint: Color {
        switch self {
        case .authorized: return .green
        case .denied: return .orange
        case .restricted: return .red
        case .notDetermined: return .secondary
        case .unavailable: return .secondary
        }
    }
}

private extension CapabilityFeature {
    var displayLabel: String {
        switch self {
        case .tccRead: return "TCC 权限读取"
        case .signatureDeepAudit: return "签名深度审计"
        case .uninstallDelete: return "卸载残留扫描"
        case .updateProbe: return "更新探测"
        }
    }
}

private extension RiskSignal {
    var recommendation: String {
        switch code {
        case "SIGNATURE_UNSIGNED":
            return "建议先确认来源和开发者；若不是主动安装，优先隔离或卸载。"
        case "SIGNATURE_UNKNOWN":
            return "建议核对 Team ID、下载来源和最近更新时间。"
        case "BG_WITH_SENSITIVE":
            return "建议检查登录项和系统权限，只保留必要授权。"
        case "HIGH_CPU_BG":
            return "建议观察活动监视器，必要时关闭后台启动或更新版本。"
        case "SCREEN_CAPTURE_TP", "ACCESSIBILITY_TP":
            return "建议进入系统设置复核该权限是否仍然必要。"
        default:
            return "建议结合签名、权限、来源和使用场景复核。"
        }
    }

    func evidenceText(for app: AppRecord) -> String {
        switch code {
        case "SIGNATURE_UNSIGNED":
            return "签名状态: \(app.signature.trustLevel.displayLabel)，路径: \(app.path)"
        case "SIGNATURE_UNKNOWN":
            return "Team ID: \(app.signature.teamID ?? "未提供")，Authority: \(app.signature.commonName ?? "未知")"
        case "BG_WITH_SENSITIVE":
            let names = app.permissions.requested.map(\.displayLabel).sorted().joined(separator: "、")
            return "后台常驻: \(app.permissions.backgroundResident ? "是" : "否")；权限: \(names)"
        case "HIGH_CPU_BG":
            return "CPU: \(String(format: "%.1f", app.metrics.cpuPercent))%，后台常驻: \(app.permissions.backgroundResident ? "是" : "否")"
        case "HIGH_MEM_THIRDPARTY":
            return "内存: \(Int(app.metrics.memoryMB)) MB；来源: \(app.source.displayLabel)"
        default:
            return "来源: \(app.source.displayLabel)；权限数: \(app.permissions.requested.count)"
        }
    }
}
