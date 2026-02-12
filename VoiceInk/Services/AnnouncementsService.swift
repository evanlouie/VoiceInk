import Foundation
import AppKit

/// A minimal pull-based announcements fetcher that shows one-time in-app banners.
final class AnnouncementsService {
    static let shared = AnnouncementsService()

    private init() {}

    // MARK: - Configuration

    // Hosted via GitHub Pages for this repo
    private let announcementsURL = URL(string: "https://beingpax.github.io/VoiceInk/announcements.json")!

    // Fetch every 4 hours
    private let refreshInterval: TimeInterval = 4 * 60 * 60

    // 100 KB – announcements JSON should be tiny
    private let maxResponseBytes = 100 * 1024

    private let dismissedKey = "dismissedAnnouncementIds"
    private let maxDismissedToKeep = 2
    private var timer: Timer?

    private let allowedHosts: [String] = [
        "tryvoiceink.com",
        "github.com",
        "youtube.com",
        "x.com",
        "twitter.com",
        "discord.com",
        "discord.gg",
    ]

    // MARK: - Public API

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.fetchAndMaybeShow()
        }
        // Do an initial fetch shortly after launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.fetchAndMaybeShow()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Core Logic

    private func fetchAndMaybeShow() {
        let request = URLRequest(url: announcementsURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            guard error == nil, let data = data else { return }

            // Validate HTTP status code
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) { return }

            // Reject oversized responses
            guard data.count <= self.maxResponseBytes else { return }

            guard let announcements = try? JSONDecoder().decode([RemoteAnnouncement].self, from: data) else { return }

            let now = Date()
            let notDismissed = announcements.filter { !self.isDismissed($0.id) }
            let valid = notDismissed.filter { $0.isActive(at: now) }

            guard let next = valid.first else { return }

            DispatchQueue.main.async {
                let url = next.url.flatMap { URL(string: $0) }.flatMap { self.sanitizedURL($0) }
                AnnouncementManager.shared.showAnnouncement(
                    title: next.title,
                    description: next.description,
                    learnMoreURL: url,
                    onDismiss: { self.markDismissed(next.id) }
                )
            }
        }
        task.resume()
    }

    private func isDismissed(_ id: String) -> Bool {
        let set = UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []
        return set.contains(id)
    }

    /// Returns the URL only if it uses HTTPS and its host matches the allowlist.
    private func sanitizedURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        guard let host = url.host?.lowercased() else { return nil }
        let matched = allowedHosts.contains { allowed in
            host == allowed || host.hasSuffix("." + allowed)
        }
        return matched ? url : nil
    }

    private func markDismissed(_ id: String) {
        var ids = UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []
        if !ids.contains(id) {
            ids.append(id)
        }
        // Keep only the most recent N ids
        if ids.count > maxDismissedToKeep {
            let overflow = ids.count - maxDismissedToKeep
            ids.removeFirst(overflow)
        }
        UserDefaults.standard.set(ids, forKey: dismissedKey)
    }
}

// MARK: - Models

private struct RemoteAnnouncement: Decodable {
    let id: String
    let title: String
    let description: String?
    let url: String?
    let startAt: String?
    let endAt: String?

    func isActive(at date: Date) -> Bool {
        let formatter = ISO8601DateFormatter()
        if let startAt = startAt, let start = formatter.date(from: startAt), date < start { return false }
        if let endAt = endAt, let end = formatter.date(from: endAt), date > end { return false }
        return true
    }

}
