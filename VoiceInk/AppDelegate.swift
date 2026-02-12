import Cocoa
import SwiftUI
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {
    weak var menuBarManager: MenuBarManager?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarManager?.applyActivationPolicy()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let menuBarManager = menuBarManager, !menuBarManager.isMenuBarOnly {
            if WindowManager.shared.showMainWindow() != nil {
                return false
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { SupportedMedia.isSupported(url: $0) }) else {
            return
        }
        
        NSApplication.shared.activate(ignoringOtherApps: true)

        Task { @MainActor in
            AudioTranscriptionManager.shared.queuePendingOpenFile(url)

            if WindowManager.shared.currentMainWindow() != nil {
                menuBarManager?.focusMainWindow()
            }

            NotificationCenter.default.post(name: .navigateToDestination, object: nil, userInfo: ["destination": "Transcribe Audio"])
            NotificationCenter.default.post(name: .openFileForTranscription, object: nil, userInfo: ["url": url])
        }
    }
}
