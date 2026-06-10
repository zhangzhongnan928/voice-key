import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu bar only (LSUIElement)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let controller = try AppController()
            self.controller = controller
            controller.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "VoiceKey could not start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
