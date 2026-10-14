import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum DashboardViewMode: String, CaseIterable, Identifiable {
    case audit = "列表"
    case launcher = "启动台"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .audit: return "list.bullet.rectangle"
        case .launcher: return "square.grid.3x3"
        }
    }
}

enum LauncherLayoutMode: String, CaseIterable, Identifiable {
    case grid = "图标"
    case list = "列表"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @AppStorage("dashboardViewMode") private var viewMode: DashboardViewMode = .audit
    @State private var previousSearchText = ""
    @State private var launchingAppID: AppRecord.ID?
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if viewMode == .audit {
                NavigationSplitView {
                    AuditSidebar(viewModel: viewModel)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
                } content: {
                    AuditListPane(viewModel: viewModel)
                        .navigationSplitViewColumnWidth(min: 680, ideal: 820, max: 1200)
                } detail: {
                    AppInspectorPane(viewModel: viewModel)
                        .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 480)
                }
            } else {
                NavigationSplitView {
                    LauncherSidebar(
                        viewModel: viewModel,
                        state: viewModel.launcherState
                    )
                    .navigationSplitViewColumnWidth(min: 184, ideal: 202, max: 226)
                } content: {
                    LauncherMainPane(
                        viewModel: viewModel,
                        state: viewModel.launcherState,
                        launchingAppID: launchingAppID,
                        searchFocused: $searchFocused,
                        launch: launch
                    )
                    .navigationSplitViewColumnWidth(min: 720, ideal: 860, max: 1100)
                } detail: {
                    AIAssistantPane(
                        viewModel: viewModel,
                        state: viewModel.launcherState,
                        launch: launch
                    )
                    .navigationSplitViewColumnWidth(min: 250, ideal: 286, max: 340)
                }
            }
        }
        .navigationTitle("App Dock")
        .onChange(of: viewModel.searchText) { _ in
            handleSearchTextChanged()
        }
        .onAppear {
            previousSearchText = viewModel.searchText
            PerformanceProbe.mark("launcher.viewAppeared")
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("视图模式", selection: $viewMode) {
                    ForEach(DashboardViewMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }
            LauncherToolbar(viewModel: viewModel)
        }
        .overlay(alignment: .topLeading) {
            Button("聚焦搜索") {
                searchFocused = true
            }
            .keyboardShortcut("k", modifiers: .command)
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .accessibilityHidden(true)
        }
        .background(.background)
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
        .alert("卸载清理结果", isPresented: $viewModel.showUninstallResult, presenting: viewModel.uninstallResult) { _ in
            Button("好") {}
        } message: { result in
            Text(result.alertMessage)
        }
    }

    private func handleSearchTextChanged() {
        if !previousSearchText.isEmpty && viewModel.searchText.isEmpty {
            Task { @MainActor in viewModel.recordSearchNoClick() }
        }
        previousSearchText = viewModel.searchText
        viewModel.scheduleSearchAndGrouping()
    }

    private func launch(_ app: AppRecord) {
        let started = PerformanceProbe.start("launcher.clickToOpen")
        let trimmedSearch = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let resultIndex = trimmedSearch.isEmpty ? nil : viewModel.searchResults.firstIndex { $0.app.id == app.id }
        launchingAppID = app.id
        viewModel.selectApp(app)
        openApp(app)
        PerformanceProbe.end("launcher.clickToOpen", from: started)

        Task { @MainActor in
            if let resultIndex {
                viewModel.recordSearchClick(app: app, resultIndex: resultIndex)
            }
            viewModel.recordAppOpen(app)
            try? await Task.sleep(nanoseconds: 650_000_000)
            if launchingAppID == app.id {
                launchingAppID = nil
            }
        }
    }

}

// MARK: - Toolbar

private struct LauncherToolbar: ToolbarContent {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Label(viewModel.isLoading ? "扫描应用..." : "\(viewModel.apps.count) 个应用", systemImage: viewModel.isLoading ? "arrow.triangle.2.circlepath" : "square.grid.3x3")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("已发现 \(viewModel.apps.count) 个 macOS 应用")

            CapabilityPill(flavor: viewModel.flavor)

            if viewModel.tokenUsageSummary.totalTokens > 0 {
                Label("\(viewModel.tokenUsageSummary.totalTokens) tokens · $\(String(format: "%.4f", viewModel.tokenUsageSummary.totalCost))", systemImage: "chart.bar.doc.horizontal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("AI Token 用量")
            }
        }

        ToolbarItemGroup {
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
                .help("重新扫描应用")

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
                .help("使用 AI 重新整理应用分类")

                Button {
                    Task { await viewModel.runAIReport() }
                } label: {
                    if viewModel.isGeneratingReport {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("安全详情", systemImage: "shield.lefthalf.filled")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("生成 AI 安全详情")
            }

            Button {
                viewModel.showSettings = true
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("打开设置")
        }
    }
}

private struct LauncherSidebar: View {
    @ObservedObject var viewModel: DashboardViewModel
    let state: LauncherViewState

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Text("App Dock")
                        .font(.title3.weight(.semibold))
                    Text("AI 原生的 macOS 应用启动器")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            Section("智能入口") {
                ForEach(state.smartRows) { row in
                    launcherRow(row)
                }
            }

            Section("AI 分类") {
                ForEach(state.categoryRows) { row in
                    launcherRow(row)
                }
            }

            Section {
                Label("自然语言搜索", systemImage: "text.magnifyingglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func launcherRow(_ row: LauncherSidebarRow) -> some View {
        Button {
            viewModel.selectLauncherFilter(row.filter)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: row.systemImage)
                    .frame(width: 17)
                    .foregroundStyle(state.filter == row.filter ? Color.accentColor : .secondary)
                Text(row.filter.title)
                    .lineLimit(1)
                Spacer()
                Text("\(row.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(state.filter == row.filter ? Color.accentColor.opacity(0.16) : Color.clear)
    }
}

// MARK: - Launcher Main

private struct LauncherMainPane: View {
    @ObservedObject var viewModel: DashboardViewModel
    let state: LauncherViewState
    let launchingAppID: AppRecord.ID?
    let searchFocused: FocusState<Bool>.Binding
    let launch: (AppRecord) -> Void
    @State private var layoutMode: LauncherLayoutMode = .grid

    var body: some View {
        VStack(spacing: 0) {
            LauncherHeader(
                viewModel: viewModel,
                title: state.title,
                subtitle: state.subtitle,
                searchFocused: searchFocused,
                openFirstResult: openFirstResult
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LauncherSummaryStrip(items: state.summaryItems)

                    HStack(spacing: 8) {
                        Text(state.hasActiveSearch ? "AI 搜索命中" : "应用")
                            .font(.headline)
                        Text("\(state.items.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer()
                        if viewModel.isSearchLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Picker("布局", selection: $layoutMode) {
                            ForEach(LauncherLayoutMode.allCases) { mode in
                                Label(mode.rawValue, systemImage: mode.systemImage)
                                    .tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }

                    if state.items.isEmpty {
                        LauncherEmptyState()
                    } else {
                        switch layoutMode {
                        case .grid:
                            LauncherAppGrid(
                                viewModel: viewModel,
                                items: state.items,
                                launchingAppID: launchingAppID,
                                launch: launch
                            )
                        case .list:
                            LauncherAppList(
                                viewModel: viewModel,
                                items: state.items,
                                launchingAppID: launchingAppID,
                                launch: launch
                            )
                        }
                    }
                }
                .padding(24)
            }
        }
        .background(.background)
    }

    private func openFirstResult() {
        guard let first = state.items.first?.app else { return }
        launch(first)
    }
}

private struct LauncherHeader: View {
    @ObservedObject var viewModel: DashboardViewModel
    let title: String
    let subtitle: String
    let searchFocused: FocusState<Bool>.Binding
    let openFirstResult: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("App Dock")
                    .font(.title.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 9) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(.teal.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                TextField("AI 搜索应用、类别或任务", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .focused(searchFocused)
                    .onSubmit(openFirstResult)
                Text("⌘K")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 12)
            .frame(width: 420, height: 44)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.quaternary, lineWidth: 0.5)
            }
            .help("输入后按 Return 打开首个结果")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct LauncherSummaryStrip: View {
    let items: [LauncherStatItem]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(items) { item in
                LauncherStatCard(item: item)
            }
        }
    }
}

private struct LauncherStatCard: View {
    let item: LauncherStatItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(item.tint.color.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(item.value)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 70)
        .modernPanel(material: .thinMaterial)
    }
}

private struct LauncherAppGrid: View {
    @ObservedObject var viewModel: DashboardViewModel
    let items: [LauncherAppItem]
    let launchingAppID: AppRecord.ID?
    let launch: (AppRecord) -> Void
    @State private var tagEditorItem: LauncherAppItem?
    @State private var categoryPickerItem: LauncherAppItem?
    @FocusState private var focusedAppID: AppRecord.ID?

    private let columns = [
        GridItem(.adaptive(minimum: 116, maximum: 138), spacing: 22, alignment: .top)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
            ForEach(items) { item in
                LauncherAppTile(
                    item: item,
                    isLaunching: launchingAppID == item.id,
                    launch: { launch(item.app) },
                    revealInFinder: {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.app.path)])
                    },
                    select: {
                        viewModel.selectApp(item.app)
                    },
                    editTags: {
                        tagEditorItem = item
                    },
                    changeCategory: {
                        categoryPickerItem = item
                    }
                )
                .focused($focusedAppID, equals: item.id)
            }
        }
        .padding(.bottom, 24)
        .onAppear {
            focusedAppID = focusedAppID ?? items.first?.id
        }
        .onChange(of: items.map(\.id)) { ids in
            if let focusedAppID, ids.contains(focusedAppID) {
                return
            }
            focusedAppID = ids.first
        }
        .onMoveCommand(perform: moveFocus)
        .popover(item: $tagEditorItem) { item in
            TagEditorView(appName: item.app.name, tags: item.tags, viewModel: viewModel)
        }
        .popover(item: $categoryPickerItem) { item in
            CategoryPickerView(
                appName: item.app.name,
                bundleID: item.app.bundleID,
                currentCategory: item.category,
                viewModel: viewModel
            )
        }
    }

    private func moveFocus(_ direction: MoveCommandDirection) {
        guard !items.isEmpty else { return }
        let currentIndex = focusedAppID.flatMap { id in
            items.firstIndex { $0.id == id }
        } ?? 0
        let columnsPerRow = min(max(items.count, 1), 5)
        let nextIndex: Int
        switch direction {
        case .left:
            nextIndex = max(0, currentIndex - 1)
        case .right:
            nextIndex = min(items.count - 1, currentIndex + 1)
        case .up:
            nextIndex = max(0, currentIndex - columnsPerRow)
        case .down:
            nextIndex = min(items.count - 1, currentIndex + columnsPerRow)
        @unknown default:
            nextIndex = currentIndex
        }
        focusedAppID = items[nextIndex].id
    }
}

private struct LauncherAppTile: View {
    let item: LauncherAppItem
    let isLaunching: Bool
    let launch: () -> Void
    let revealInFinder: () -> Void
    let select: () -> Void
    let editTags: () -> Void
    let changeCategory: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button {
            launch()
        } label: {
            VStack(spacing: 9) {
                ZStack(alignment: .topTrailing) {
                    AppIconView(path: item.app.path, size: 78)
                        .shadow(color: .black.opacity(0.16), radius: 12, y: 8)
                        .opacity(isLaunching ? 0.58 : 1)
                    if isLaunching {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 28, height: 28)
                            .background(.regularMaterial, in: Circle())
                            .offset(x: 10, y: -8)
                    } else if !item.cornerBadgeText.isEmpty {
                        Text(item.cornerBadgeText)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(item.statusTint.color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.thinMaterial, in: Capsule())
                            .offset(x: 10, y: -6)
                    }
                }

                Text(item.app.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)

                HStack(spacing: 5) {
                    MiniCategoryBadge(text: item.displayHint)
                    Text(item.confidenceLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 14)
            .frame(width: 124, height: 142)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(tileBackground)
        .scaleEffect(isLaunching ? 0.97 : 1)
        .animation(.snappy(duration: 0.16), value: isLaunching)
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            Button("打开应用", action: launch)
            Button("在 Finder 中显示", action: revealInFinder)
            Button("设为详情焦点", action: select)
            Divider()
            Button("编辑标签...", action: editTags)
            Button("修改类别...", action: changeCategory)
        }
        .help("单击打开 \(item.app.name)")
    }

    @ViewBuilder
    private var tileBackground: some View {
        let cornerRadius: CGFloat = 14
        if isLaunching || item.isSelected || isHovering || item.isRecommended {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tileFill)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(tileStroke, lineWidth: item.isSelected ? 1 : 0.5)
                }
        }
    }

    private var tileFill: Color {
        if isLaunching { return Color.accentColor.opacity(0.16) }
        if item.isSelected { return Color.accentColor.opacity(0.12) }
        if isHovering { return Color.primary.opacity(0.06) }
        return Color.teal.opacity(0.08)
    }

    private var tileStroke: Color {
        if isLaunching || item.isSelected { return Color.accentColor.opacity(0.32) }
        if isHovering { return Color.primary.opacity(0.14) }
        return Color.teal.opacity(0.18)
    }
}

private struct LauncherAppList: View {
    @ObservedObject var viewModel: DashboardViewModel
    let items: [LauncherAppItem]
    let launchingAppID: AppRecord.ID?
    let launch: (AppRecord) -> Void
    @State private var tagEditorItem: LauncherAppItem?
    @State private var categoryPickerItem: LauncherAppItem?

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                LauncherAppListRow(
                    item: item,
                    isLaunching: launchingAppID == item.id,
                    launch: { launch(item.app) },
                    revealInFinder: {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.app.path)])
                    },
                    select: {
                        viewModel.selectApp(item.app)
                    },
                    editTags: {
                        tagEditorItem = item
                    },
                    changeCategory: {
                        categoryPickerItem = item
                    }
                )
                Divider()
            }
        }
        .modernPanel(material: .thinMaterial)
        .padding(.bottom, 24)
        .popover(item: $tagEditorItem) { item in
            TagEditorView(appName: item.app.name, tags: item.tags, viewModel: viewModel)
        }
        .popover(item: $categoryPickerItem) { item in
            CategoryPickerView(
                appName: item.app.name,
                bundleID: item.app.bundleID,
                currentCategory: item.category,
                viewModel: viewModel
            )
        }
    }
}

private struct LauncherAppListRow: View {
    let item: LauncherAppItem
    let isLaunching: Bool
    let launch: () -> Void
    let revealInFinder: () -> Void
    let select: () -> Void
    let editTags: () -> Void
    let changeCategory: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: launch) {
            HStack(spacing: 12) {
                AppIconView(path: item.app.path, size: 40)
                    .opacity(isLaunching ? 0.58 : 1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.app.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        if !item.statusLabel.isEmpty {
                            Text(item.statusLabel)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(item.statusTint.color)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(item.statusTint.color.opacity(0.12), in: Capsule())
                        }
                    }
                    HStack(spacing: 6) {
                        MiniCategoryBadge(text: item.displayHint)
                        if !item.confidenceLabel.isEmpty {
                            Text(item.confidenceLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                Spacer()

                if isLaunching {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovering || item.isSelected ? Color.primary.opacity(0.05) : Color.clear)
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            Button("打开应用", action: launch)
            Button("在 Finder 中显示", action: revealInFinder)
            Button("设为详情焦点", action: select)
            Divider()
            Button("编辑标签...", action: editTags)
            Button("修改类别...", action: changeCategory)
        }
        .help("单击打开 \(item.app.name)")
    }
}

private struct MiniCategoryBadge: View {
    let text: String

    var body: some View {
        Text(shortText)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.teal)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.teal.opacity(0.12), in: Capsule())
    }

    private var shortText: String {
        if text.count <= 6 { return text }
        return String(text.prefix(6))
    }
}

private struct LauncherEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.3x3")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("没有匹配的应用")
                .font(.headline)
            Text("换一个搜索词或切回全部应用。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .modernPanel(material: .thinMaterial)
    }
}

// MARK: - AI Assistant

private struct AIAssistantPane: View {
    @ObservedObject var viewModel: DashboardViewModel
    let state: LauncherViewState
    let launch: (AppRecord) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("AI 助手")
                    .font(.title3.weight(.semibold))

                AIStatusCard(isProcessing: viewModel.isAIProcessing || viewModel.isOrganizing, state: state.aiStatus)

                VStack(spacing: 0) {
                    AIInsightRow(
                        title: "推荐打开",
                        detail: "\(state.aiStatus.recommendedName) 是当前首选应用。",
                        value: state.aiStatus.recommendedConfidenceLabel,
                        tint: .teal
                    )
                    AIInsightRow(
                        title: "新安装应用已分类",
                        detail: "最近新安装的应用已自动加入对应分组。",
                        value: state.aiStatus.organizedValue,
                        tint: .blue
                    )
                    AIInsightRow(
                        title: "高频工作流",
                        detail: "你在该时段打开应用的频率最高。",
                        value: state.aiStatus.workflowValue,
                        tint: .orange
                    )
                    AIInsightRow(
                        title: "自然语言命中",
                        detail: "“写代码”“会议”等描述会映射到对应应用。",
                        value: state.aiStatus.naturalLanguageValue,
                        tint: .pink
                    )
                }

                SuggestedGroupCard(groups: state.suggestedGroups)

                if let app = viewModel.selectedApp {
                    SelectedAppSummaryCard(app: app, viewModel: viewModel, launch: launch)
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text("安全详情已收起为轻量提示")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
            .padding(16)
        }
        .background(.background)
    }
}

private struct AIStatusCard: View {
    let isProcessing: Bool
    let state: LauncherAIStatusState

    var body: some View {
        HStack(spacing: 10) {
            if isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 38, height: 38)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.teal.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(.caption.weight(.semibold))
                Text(state.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.teal.opacity(0.22), lineWidth: 0.5)
        }
    }
}

private struct AIInsightRow: View {
    let title: String
    let detail: String?
    let value: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tint.opacity(0.12), in: Capsule())
                .lineLimit(1)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct SuggestedGroupCard: View {
    let groups: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("今日建议分组")
                .font(.caption.weight(.semibold))
            if groups.isEmpty {
                Text("暂无分组建议")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 7) {
                    ForEach(groups, id: \.self) { title in
                        group(title)
                    }
                }
            }
        }
        .padding(10)
        .modernPanel(material: .thinMaterial)
    }

    private func group(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct SelectedAppSummaryCard: View {
    let app: AppRecord
    @ObservedObject var viewModel: DashboardViewModel
    let launch: (AppRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AppIconView(path: app.path, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(viewModel.resolvedCategory(for: app))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Button {
                    launch(app)
                } label: {
                    Label("打开", systemImage: "arrow.up.right.square")
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
                } label: {
                    Label("定位", systemImage: "folder")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            HStack(spacing: 6) {
                RiskBadge(score: viewModel.riskScore(for: app), level: viewModel.riskLevel(for: app))
                Text(app.source.displayLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(app.source.tint)
            }
        }
        .padding(12)
        .modernPanel(material: .thinMaterial)
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
        List {
            Section("审计范围") {
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

            Section("分组") {
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

            Section("能力状态") {
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

            if viewModel.searchLearningStats.totalQueries > 0 {
                Section {
                    Label("搜索学习", systemImage: "brain.head.profile")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.teal)
                    Text("\(viewModel.searchLearningStats.totalQueries) 次查询 · \(Int(viewModel.searchLearningStats.clickRate))% 命中")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
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
                    .foregroundStyle(selected ? Color.accentColor : filter.tint)
                Text(filter.rawValue)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.vertical, 2)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Color.accentColor.opacity(0.16) : Color.clear)
    }
}

// MARK: - Main List

private struct AuditListPane: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HealthSummaryStrip(viewModel: viewModel)

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
            .background(.bar)

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
                            .background(.regularMaterial)
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollContentBackground(.hidden)
        }
        .background(.background)
    }
}

private struct HealthSummaryStrip: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                metricTiles
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
                metricTiles
            }
        }
    }

    @ViewBuilder
    private var metricTiles: some View {
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
                    .lineLimit(1)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(minWidth: 112, maxWidth: .infinity, minHeight: 74)
        .modernPanel()
    }
}

private struct StatusBanner: View {
    let systemImage: String
    let text: String
    let active: Bool

    var body: some View {
        HStack(spacing: 10) {
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
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if !active {
                Text("查看报告")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.teal)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modernPanel(material: .thinMaterial)
    }
}

private struct AuditTableHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("应用")
                .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
            Text("风险")
                .frame(width: 64, alignment: .leading)
            Text("来源")
                .frame(width: 68, alignment: .leading)
            Text("签名")
                .frame(width: 74, alignment: .leading)
            Text("权限")
                .frame(width: 72, alignment: .leading)
            Text("资源")
                .frame(width: 70, alignment: .trailing)
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
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    AppIconView(path: app.path, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(app.name)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if hasUpdate {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                                    .help("发现更新建议")
                            }
                        }
                        HStack(spacing: 5) {
                            Text(category)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)

                            if let hint = hints.first {
                                Text(hint.displayText)
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(hint.color)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(hint.color.opacity(0.12), in: Capsule())
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }

                            let maxTags = hints.isEmpty ? 2 : 1
                            ForEach(tags.prefix(maxTags), id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(.teal)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Color.teal.opacity(0.10), in: Capsule())
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                    }
                }
                .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)

                RiskBadge(score: riskScore, level: riskLevel)
                    .frame(width: 64, alignment: .leading)

                Text(app.source.displayLabel)
                    .font(.caption)
                    .foregroundStyle(app.source.tint)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: 68, alignment: .leading)

                Text(app.signature.trustLevel.displayLabel)
                    .font(.caption)
                    .foregroundStyle(app.signature.trustLevel.tint)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: 74, alignment: .leading)

                PermissionMiniStack(app: app)
                    .frame(width: 72, alignment: .leading)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(String(format: "%.1f", app.metrics.cpuPercent))%")
                        .lineLimit(1)
                    Text("\(Int(app.metrics.memoryMB)) MB")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.caption.monospacedDigit())
                .frame(width: 70, alignment: .trailing)
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
        HStack(spacing: 4) {
            Circle()
                .fill((level ?? .low).tint)
                .frame(width: 7, height: 7)
            Text(level?.displayLabel ?? "低")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text("\(score)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background((level ?? .low).tint.opacity(0.10), in: Capsule())
        .overlay {
            Capsule()
                .stroke((level ?? .low).tint.opacity(0.20), lineWidth: 0.5)
        }
    }
}

private struct PermissionMiniStack: View {
    let app: AppRecord

    var body: some View {
        HStack(spacing: 3) {
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
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
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
                        ResidualPreviewPanel(app: app, viewModel: viewModel)
                    }
                    .padding(16)
                }
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
        .background(.background)
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
    @State private var showUninstallConfirmation = false

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
            Button(role: .destructive) {
                showUninstallConfirmation = true
            } label: {
                if viewModel.isUninstallingAppID == app.id {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("卸载", systemImage: "trash")
                }
            }
            .disabled(viewModel.isUninstallingAppID != nil)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .confirmationDialog(
            "确认卸载并清理 \(app.name)？",
            isPresented: $showUninstallConfirmation,
            titleVisibility: .visible
        ) {
            Button("移入废纸篓并清理残留", role: .destructive) {
                Task { await viewModel.uninstallAndClean(app) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(uninstallConfirmationMessage(for: app, viewModel: viewModel))
        }
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
        .modernPanel()
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
    @ObservedObject var viewModel: DashboardViewModel
    @State private var preview: UninstallPreview?
    @State private var showUninstallConfirmation = false

    var body: some View {
        let items = preview?.items ?? []
        InspectorSection(title: "一键卸载清理", systemImage: "trash") {
            VStack(alignment: .leading, spacing: 10) {
                if let reason = preview?.unavailableReason {
                    Label(reason, systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if items.isEmpty {
                    Text("未发现可清理项目。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(items) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Text(item.kind.rawValue)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(item.kind == .appBundle ? Color.red : Color.secondary, in: Capsule())
                                    .frame(width: 68, alignment: .leading)
                                Text(item.path)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                            }
                        }
                    }

                    Button(role: .destructive) {
                        showUninstallConfirmation = true
                    } label: {
                        if viewModel.isUninstallingAppID == app.id {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("一键卸载并清理", systemImage: "trash")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(viewModel.isUninstallingAppID != nil)
                }
            }
        }
        .task(id: app.id) {
            preview = viewModel.uninstallPreview(for: app)
        }
        .onChange(of: viewModel.uninstallResult?.id) { _ in
            preview = viewModel.uninstallPreview(for: app)
        }
        .confirmationDialog(
            "确认卸载并清理 \(app.name)？",
            isPresented: $showUninstallConfirmation,
            titleVisibility: .visible
        ) {
            Button("移入废纸篓并清理残留", role: .destructive) {
                Task { await viewModel.uninstallAndClean(app) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(uninstallConfirmationMessage(for: app, viewModel: viewModel))
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
            self.icon = await AppIconCache.shared.icon(for: path, size: size)
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
                    if viewModel.saveAPISettings() { dismiss() }
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
            SecureField("API Key", text: $viewModel.apiKey)
            TextField("Base URL", text: $viewModel.baseURL)
            TextField("Model", text: $viewModel.model)
            Toggle("允许向此 AI 服务发送应用元数据", isOn: $viewModel.metadataSharingAllowed)
                .onChange(of: viewModel.metadataSharingAllowed) { allowed in
                    if !allowed { AIPrivacyPolicy.saveConsent(false, endpoint: viewModel.baseURL) }
                }
            Text("默认关闭。启用并保存后，会向填写的 HTTPS 服务发送应用名称、Bundle ID、来源、权限和资源摘要；本地路径与凭据会被过滤。更换服务地址需重新保存授权。API Key 保存到钥匙串。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("保留本地搜索与使用记录", isOn: $viewModel.localHistoryEnabled)
            Button("清除本机缓存与记录", role: .destructive) { viewModel.clearLocalData() }
                .disabled(viewModel.isAIProcessing || viewModel.isOrganizing || viewModel.isGeneratingReport || viewModel.isUpdatingMappings || viewModel.isLoading)
            if let status = viewModel.privacyStatus { Text(status).font(.caption) }
            Text("搜索与使用记录默认不保存。应用缓存仅保存在本机 OpenDock 目录，清除不会影响旧版应用的数据。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = viewModel.credentialError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Section {
                HStack(spacing: 10) {
                    Button {
                        Task { await viewModel.testAIConnection() }
                    } label: {
                        if viewModel.isTestingConnection {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("测试连接", systemImage: "bolt.horizontal.circle")
                        }
                    }
                    .disabled(viewModel.isTestingConnection || viewModel.apiKey.isEmpty)

                    connectionResultView
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var connectionResultView: some View {
        if let result = viewModel.connectionTestResult {
            switch result {
            case let .success(latency, model):
                Label(
                    "连接成功 · \(model) · \(String(format: "%.0f ms", latency * 1000))",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)
            case let .failure(message):
                Label(message, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
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

private extension View {
    func modernPanel(cornerRadius: CGFloat = 8, material: Material = .regularMaterial) -> some View {
        background(material, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.quaternary, lineWidth: 0.5)
            }
    }
}

private func openApp(_ app: AppRecord) {
    let appURL = URL(fileURLWithPath: app.path)
    NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
}

@MainActor
private func uninstallConfirmationMessage(for app: AppRecord, viewModel: DashboardViewModel) -> String {
    let preview = viewModel.uninstallPreview(for: app)
    if let reason = preview.unavailableReason {
        return reason
    }
    let count = preview.items.count
    if count == 0 {
        return "未发现可清理项目。"
    }
    return "将把应用本体和 \(max(0, count - 1)) 个常见残留项目移入废纸篓，可从废纸篓恢复。"
}

private extension UninstallCleanupResult {
    var alertMessage: String {
        var lines = [summary]
        if !removedItems.isEmpty {
            lines.append("已处理: \(removedItems.map { $0.kind.rawValue }.joined(separator: "、"))")
        }
        if !failedItems.isEmpty {
            let failures = failedItems.prefix(3).map { "\($0.path): \($0.reason)" }.joined(separator: "\n")
            lines.append("失败项目:\n\(failures)")
        }
        return lines.joined(separator: "\n")
    }
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
