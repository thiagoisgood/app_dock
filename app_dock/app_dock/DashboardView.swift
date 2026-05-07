import SwiftUI
import AppKit

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @FocusState private var focusedField: FocusField?
    @State private var scrollID = UUID()

    private enum FocusField: Hashable {
        case search
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("AI-Native macOS 应用列表")
                        .font(.title2.bold())
                    Text(viewModel.isLoading ? "扫描中..." : viewModel.summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("构建渠道: \(viewModel.flavor == .mas ? "MAS" : "DIRECT")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    // Token usage display
                    if viewModel.tokenUsageSummary.totalTokens > 0 {
                        Text("Token使用: \(viewModel.tokenUsageSummary.totalTokens) | 花费: $\(String(format: "%.4f", viewModel.tokenUsageSummary.totalCost))")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                    }
                }
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
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
                                Image(systemName: "sparkles")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("重新整理应用分类")
                        Button {
                            Task { await viewModel.runAIReport() }
                        } label: {
                            if viewModel.isGeneratingReport {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("报告", systemImage: "doc.text.magnifyingglass")
                                    .labelStyle(.iconOnly)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("生成AI审计报告")
                    }
                    Button("设置") { viewModel.showSettings = true }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            HStack(spacing: 6) {
                Text("系统: \(viewModel.systemCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("•")
                    .foregroundStyle(.tertiary)
                Text("App Store: \(viewModel.appStoreCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("•")
                    .foregroundStyle(.tertiary)
                Text("第三方: \(viewModel.thirdPartyCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            HStack(spacing: 8) {
                TextField("搜索应用名 / 标签 / 自然语言", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .search)
                    .frame(width: 280)
                Picker("", selection: $viewModel.groupingMode) {
                    ForEach(ListGroupingMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                .onChange(of: viewModel.groupingMode) { _ in
                    viewModel.applySearchAndGrouping()
                }
                .onChange(of: viewModel.searchText) { _ in
                    viewModel.applySearchAndGrouping()
                }
                .task(id: viewModel.groupingMode) {
                    scrollID = UUID()
                }
                .task(id: viewModel.searchText) {
                    scrollID = UUID()
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            // AI Assistant Bar
            if viewModel.isAIProcessing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.aiProcessingProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
            } else if !viewModel.aiAssistantText.isEmpty {
                HStack {
                    Text(viewModel.aiAssistantText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Spacer()
                    Button("查看报告") { viewModel.showAIReport = true }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(viewModel.listSections) { section in
                            Section {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 160))], spacing: 12) {
                                    ForEach(section.apps) { app in
                                        AppCardView(app: app, viewModel: viewModel)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.bottom, 8)
                            } header: {
                                HStack {
                                    Text("\(section.title) (\(section.apps.count))")
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                            }
                        }
                    }
                    .id(scrollID)
                }
                .scrollContentBackground(.hidden)
                .onChange(of: scrollID) { _ in
                    if let first = viewModel.listSections.first?.apps.first {
                        proxy.scrollTo(first.id, anchor: .top)
                    }
                }
            }
        }
        .background(
            TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Canvas { context, size in
                    let colors: [Color] = [.blue.opacity(0.12), .purple.opacity(0.10), .teal.opacity(0.08)]
                    for index in 0..<3 {
                        let x = size.width * (0.2 + 0.3 * Double(index)) + CGFloat(sin(t * 0.5 + Double(index)) * 30)
                        let y = size.height * (0.35 + 0.2 * Double(index)) + CGFloat(cos(t * 0.45 + Double(index)) * 24)
                        let radius = CGFloat(200 + index * 40)
                        let rect = CGRect(x: x - radius / 2, y: y - radius / 2, width: radius, height: radius)
                        context.fill(Path(ellipseIn: rect), with: .color(colors[index]))
                    }
                }
                .ignoresSafeArea()
                .background(Color(white: 0.97))
            }
        )
        .preferredColorScheme(.light)
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
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                focusedField = .search
            }
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
                Color.clear
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .task(id: path) {
            self.icon = AppIconCache.shared.icon(for: path)
        }
    }
}

// MARK: - App Card

private struct AppCardView: View {
    let app: AppRecord
    @ObservedObject var viewModel: DashboardViewModel
    @State private var isHovered = false
    @State private var showTagEditor = false
    @State private var showCategoryPicker = false

    private var sourceColor: Color {
        switch app.source {
        case .system: return .blue
        case .appStore: return .green
        case .thirdParty: return .orange
        case .unknown: return .gray
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            AppIconView(path: app.path, size: 64)
                .shadow(color: .black.opacity(0.08), radius: isHovered ? 6 : 2, y: isHovered ? 3 : 1)

            Text(app.name)
                .font(.system(.caption, design: .rounded))
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 4) {
                Text(app.source.displayLabel)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(sourceColor.opacity(0.85))
                    .cornerRadius(4)

                Text("\(app.sizeMB) MB")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Tags
            let tags = viewModel.appTags[app.name] ?? []
            if !tags.isEmpty {
                FlowLayout(spacing: 3) {
                    ForEach(tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(3)
                    }
                }
                .frame(maxWidth: 120)
            }
        }
        .frame(width: 120)
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(.regularMaterial)
        .cornerRadius(12)
        .shadow(color: .black.opacity(isHovered ? 0.15 : 0.06), radius: isHovered ? 8 : 3, y: isHovered ? 4 : 1)
        .scaleEffect(isHovered ? 1.08 : 1.0)
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            viewModel.recordAppOpen(app)
            let appURL = URL(fileURLWithPath: app.path)
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
        .contextMenu {
            Button("编辑标签...") { showTagEditor = true }
            Divider()
            Button("修改类别...") { showCategoryPicker = true }
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

// MARK: - Tag Editor

private struct TagEditorView: View {
    let appName: String
    let tags: [String]
    @ObservedObject var viewModel: DashboardViewModel
    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    .background(Color.blue.opacity(0.15))
                    .cornerRadius(6)
                }
            }

            HStack(spacing: 4) {
                TextField("新标签", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        viewModel.addTag(to: appName, tag: newTag)
                        newTag = ""
                    }
                Button("添加") {
                    viewModel.addTag(to: appName, tag: newTag)
                    newTag = ""
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 220)
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
                .background(isSelected ? Color.blue.opacity(0.08) : Color.clear)
                .cornerRadius(6)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

// MARK: - Flow Layout

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
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            // Stats bar
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
        .frame(minWidth: 700, minHeight: 550)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5).delay(0.1)) {
                contentVisible = true
            }
        }
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
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 60)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(color.opacity(0.08))
        .cornerRadius(8)
    }
}

// MARK: - Settings Sheet

private struct SettingsSheet: View {
    @ObservedObject var viewModel: DashboardViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("OpenAI 兼容设置").font(.headline)

            TextField("API Key", text: $viewModel.apiKey)
                .textFieldStyle(.roundedBorder)
            TextField("Base URL", text: $viewModel.baseURL)
                .textFieldStyle(.roundedBorder)
            TextField("Model", text: $viewModel.model)
                .textFieldStyle(.roundedBorder)

            Divider()

            // Token Usage Statistics
            Text("Token 使用统计").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("总Token:")
                        .foregroundStyle(.secondary)
                    Text("\(viewModel.tokenUsageSummary.totalTokens)")
                        .fontWeight(.medium)
                }
                HStack {
                    Text("Prompt Token:")
                        .foregroundStyle(.secondary)
                    Text("\(viewModel.tokenUsageSummary.totalPromptTokens)")
                }
                HStack {
                    Text("Completion Token:")
                        .foregroundStyle(.secondary)
                    Text("\(viewModel.tokenUsageSummary.totalCompletionTokens)")
                }
                HStack {
                    Text("总花费:")
                        .foregroundStyle(.secondary)
                    Text("$\(String(format: "%.4f", viewModel.tokenUsageSummary.totalCost))")
                        .fontWeight(.medium)
                        .foregroundStyle(.purple)
                }
                if !viewModel.tokenUsageSummary.operationCounts.isEmpty {
                    Text("操作统计:")
                        .foregroundStyle(.secondary)
                    ForEach(viewModel.tokenUsageSummary.operationCounts.keys.sorted(), id: \.self) { op in
                        Text("• \(op): \(viewModel.tokenUsageSummary.operationCounts[op] ?? 0) 次")
                            .font(.caption)
                    }
                }
                Text("最后更新: \(viewModel.tokenUsageSummary.lastUpdated.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            Divider()

            // Search Mappings
            Text("搜索映射").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("当前映射数量:")
                        .foregroundStyle(.secondary)
                    Text("\(viewModel.searchMappings.count)")
                        .fontWeight(.medium)
                }
                if viewModel.isUpdatingMappings {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在更新...")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("更新搜索映射") {
                        Task { await viewModel.updateSearchMappings() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if !viewModel.searchMappings.isEmpty {
                    Text("映射类别:")
                        .foregroundStyle(.secondary)
                    ScrollView {
                        ForEach(viewModel.searchMappings.sorted(by: { $0.category < $1.category }), id: \.id) { mapping in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mapping.category)
                                    .font(.caption.bold())
                                Text("关键词: \(mapping.keywords.prefix(5).joined(separator: ", "))...")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .frame(maxHeight: 120)
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            HStack {
                Button("清除统计") {
                    viewModel.tokenUsageStore.clearHistory()
                    viewModel.tokenUsageSummary = viewModel.tokenUsageStore.getSummary()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
                Button("保存并关闭") {
                    viewModel.saveAPISettings()
                    dismiss()
                }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500, height: 600)
    }
}
