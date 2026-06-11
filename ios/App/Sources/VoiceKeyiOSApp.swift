import SwiftUI

@main
struct VoiceKeyiOSApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onOpenURL { url in
                    model.handleURL(url)
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            RecordView()
                .tabItem { Label("Record", systemImage: "mic") }
            HistoryListView()
                .tabItem { Label("History", systemImage: "clock") }
            IOSSettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
