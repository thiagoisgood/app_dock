import SwiftUI

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @FocusState private var focusedField: FocusField?

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
                }
                Spacer()
                Button("设置") { viewModel.showSettings = true }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            HStack(spacing: 6) {
                Text("App Store: \(ByteCountFormatter.string(fromByteCount: viewModel.appStoreBytes, countStyle: .file))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("•")
                    .foregroundStyle(.tertiary)
                Text("第三方: \(ByteCountFormatter.string(fromByteCount: viewModel.thirdPartyBytes, countStyle: .file))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            HStack(spacing: 8) {
                TextField("搜索应用名 / Bundle ID / 路径", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .search)
                    .onSubmit { viewModel.triggerPrimaryAction() }
                    .frame(width: 280)
                    .background(Color.red.opacity(0.15))
                    .onTapGesture { print("[DEBUG] TextField tapped, isFocused: \(focusedField == .search)") }
                    .onAppear { print("[DEBUG] TextField appeared") }
                    .onDisappear { print("[DEBUG] TextField disappeared") }
                Button("整理") { viewModel.triggerPrimaryAction() }
                    .keyboardShortcut(.return, modifiers: [])
                Picker("分组", selection: $viewModel.groupingMode) {
                    ForEach(ListGroupingMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .onChange(of: viewModel.groupingMode) { _ in viewModel.applySearchAndGrouping() }
                .onChange(of: viewModel.searchText) { _ in viewModel.applySearchAndGrouping() }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            List {
                ForEach(viewModel.listSections) { section in
                    Section(section.title) {
                        ForEach(section.apps) { app in
                            HStack(spacing: 16) {
                                Text(app.name).frame(minWidth: 120, alignment: .leading)
                                Text(app.version).frame(minWidth: 60, alignment: .leading)
                                Text(app.bundleID ?? "—").frame(minWidth: 180, alignment: .leading)
                                Text("\(app.sizeMB) MB").frame(minWidth: 70, alignment: .trailing)
                            }
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .background(
            TimelineView(.animation) { timeline in
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
        .task {
            print("[DEBUG] DashboardView.task started, requesting focus")
            try? await Task.sleep(for: .milliseconds(200))
            focusedField = .search
            print("[DEBUG] focusedField set to .search")
        }
    }

}

private struct SettingsSheet: View {
    @ObservedObject var viewModel: DashboardViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OpenAI 兼容设置").font(.headline)
            TextField("API Key", text: $viewModel.apiKey)
                .textFieldStyle(.roundedBorder)
            TextField("Base URL", text: $viewModel.baseURL)
                .textFieldStyle(.roundedBorder)
            TextField("Model", text: $viewModel.model)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("保存并关闭") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
