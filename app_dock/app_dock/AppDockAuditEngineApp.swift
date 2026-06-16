import SwiftUI

@main
struct AppDockAuditEngineApp: App {
    @StateObject private var viewModel = DashboardViewModel()

    var body: some Scene {
        WindowGroup("AppDock Audit") {
            DashboardView(viewModel: viewModel)
                .task {
                    await viewModel.bootstrap()
                }
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
    }
}
