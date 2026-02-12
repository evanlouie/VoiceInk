import Foundation
import AppKit
import os

enum BrowserType: CaseIterable {
    case safari
    case arc
    case chrome
    case edge
    case firefox
    case brave
    case opera
    case vivaldi
    case orion
    case zen
    case yandex
    
    var scriptName: String {
        switch self {
        case .safari: return "safariURL"
        case .arc: return "arcURL"
        case .chrome: return "chromeURL"
        case .edge: return "edgeURL"
        case .firefox: return "firefoxURL"
        case .brave: return "braveURL"
        case .opera: return "operaURL"
        case .vivaldi: return "vivaldiURL"
        case .orion: return "orionURL"
        case .zen: return "zenURL"
        case .yandex: return "yandexURL"
        }
    }
    
    var bundleIdentifier: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .arc: return "company.thebrowser.Browser"
        case .chrome: return "com.google.Chrome"
        case .edge: return "com.microsoft.edgemac"
        case .firefox: return "org.mozilla.firefox"
        case .brave: return "com.brave.Browser"
        case .opera: return "com.operasoftware.Opera"
        case .vivaldi: return "com.vivaldi.Vivaldi"
        case .orion: return "com.kagi.kagimacOS"
        case .zen: return "app.zen-browser.zen"
        case .yandex: return "ru.yandex.desktop.yandex-browser"
        }
    }
    
    var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .arc: return "Arc"
        case .chrome: return "Google Chrome"
        case .edge: return "Microsoft Edge"
        case .firefox: return "Firefox"
        case .brave: return "Brave"
        case .opera: return "Opera"
        case .vivaldi: return "Vivaldi"
        case .orion: return "Orion"
        case .zen: return "Zen Browser"
        case .yandex: return "Yandex Browser"
        }
    }
    
    static var installedBrowsers: [BrowserType] {
        allCases.filter { browser in
            let workspace = NSWorkspace.shared
            return workspace.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) != nil
        }
    }
}

enum BrowserURLError: Error {
    case scriptNotFound
    case executionFailed
    case executionTimedOut
    case browserNotRunning
    case noActiveWindow
    case noActiveTab
}

class BrowserURLService {
    static let shared = BrowserURLService()
    
    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "browser.applescript"
    )
    
    private init() {}
    
    func getCurrentURL(from browser: BrowserType) async throws -> String {
        guard let scriptURL = Bundle.main.url(forResource: browser.scriptName, withExtension: "scpt") else {
            logger.error("❌ AppleScript file not found: \(browser.scriptName).scpt")
            throw BrowserURLError.scriptNotFound
        }
        
        logger.debug("🔍 Attempting to execute AppleScript for \(browser.displayName)")
        
        // Check if browser is running
        if !isRunning(browser) {
            logger.error("❌ Browser not running: \(browser.displayName)")
            throw BrowserURLError.browserNotRunning
        }

        do {
            let output = try await runAppleScript(scriptURL: scriptURL, browser: browser)
            logger.debug("✅ Successfully retrieved URL from \(browser.displayName): \(output)")
            return output
        } catch let error as BrowserURLError {
            throw error
        } catch {
            logger.error("❌ AppleScript execution failed for \(browser.displayName): \(error.localizedDescription)")
            throw BrowserURLError.executionFailed
        }
    }
    
    func isRunning(_ browser: BrowserType) -> Bool {
        let workspace = NSWorkspace.shared
        let runningApps = workspace.runningApplications
        let isRunning = runningApps.contains { $0.bundleIdentifier == browser.bundleIdentifier }
        logger.debug("\(browser.displayName) running status: \(isRunning)")
        return isRunning
    }

    private func runAppleScript(scriptURL: URL, browser: BrowserType) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let task = Process()
                task.launchPath = "/usr/bin/osascript"
                task.arguments = [scriptURL.path]

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                task.standardOutput = stdoutPipe
                task.standardError = stderrPipe

                var stdoutData = Data()
                var stderrData = Data()
                let stdoutLock = NSLock()
                let stderrLock = NSLock()

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    stdoutLock.lock()
                    stdoutData.append(data)
                    stdoutLock.unlock()
                }

                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    stderrLock.lock()
                    stderrData.append(data)
                    stderrLock.unlock()
                }

                let timeoutSeconds: TimeInterval = 5
                let terminationGroup = DispatchGroup()
                terminationGroup.enter()
                task.terminationHandler = { _ in
                    terminationGroup.leave()
                }

                do {
                    self.logger.debug("▶️ Executing AppleScript for \(browser.displayName)")
                    try task.run()
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                    return
                }

                let waitResult = terminationGroup.wait(timeout: .now() + timeoutSeconds)
                if waitResult == .timedOut {
                    task.terminate()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    self.logger.error("❌ AppleScript timed out for \(browser.displayName)")
                    continuation.resume(throwing: BrowserURLError.executionTimedOut)
                    return
                }

                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                stdoutLock.lock()
                stdoutData.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                stdoutLock.unlock()

                stderrLock.lock()
                stderrData.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                stderrLock.unlock()

                if task.terminationStatus != 0 {
                    if let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !stderrText.isEmpty {
                        self.logger.error("❌ AppleScript stderr for \(browser.displayName): \(stderrText)")
                    }
                    continuation.resume(throwing: BrowserURLError.executionFailed)
                    return
                }

                guard let output = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    self.logger.error("❌ Failed to decode output from AppleScript for \(browser.displayName)")
                    continuation.resume(throwing: BrowserURLError.executionFailed)
                    return
                }

                if output.isEmpty {
                    self.logger.error("❌ Empty output from AppleScript for \(browser.displayName)")
                    continuation.resume(throwing: BrowserURLError.noActiveTab)
                    return
                }

                if output.hasPrefix("ERROR: ") {
                    self.logger.error("❌ AppleScript error for \(browser.displayName): \(output)")
                    continuation.resume(throwing: BrowserURLError.executionFailed)
                    return
                }

                continuation.resume(returning: output)
            }
        }
    }
} 
