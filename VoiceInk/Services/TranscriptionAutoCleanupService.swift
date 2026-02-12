import Foundation
import SwiftData
import OSLog

class TranscriptionAutoCleanupService {
    static let shared = TranscriptionAutoCleanupService()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionAutoCleanupService")
    private var modelContext: ModelContext?

    private let keyIsEnabled = "IsTranscriptionCleanupEnabled"
    private let keyRetentionMinutes = "TranscriptionRetentionMinutes"

    private let defaultRetentionMinutes: Int = 24 * 60

    private var recordingsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
            .appendingPathComponent("Recordings")
    }

    private init() {}

    func startMonitoring(modelContext: ModelContext) {
        self.modelContext = modelContext

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTranscriptionCompleted(_:)),
            name: .transcriptionCompleted,
            object: nil
        )

        if UserDefaults.standard.bool(forKey: keyIsEnabled) {
            Task { [weak self] in
                guard let self = self, let modelContext = self.modelContext else { return }
                await self.sweepOldTranscriptions(modelContext: modelContext)
                await self.cleanupOrphanAudioFiles(modelContext: modelContext)
            }
        }
    }

    func stopMonitoring() {
        NotificationCenter.default.removeObserver(self, name: .transcriptionCompleted, object: nil)
    }

    func runManualCleanup(modelContext: ModelContext) async {
        await sweepOldTranscriptions(modelContext: modelContext)
    }

    @objc private func handleTranscriptionCompleted(_ notification: Notification) {
        let isEnabled = UserDefaults.standard.bool(forKey: keyIsEnabled)
        guard isEnabled else { return }

        let modelContext = self.modelContext
        if let modelContext = modelContext {
            Task(priority: .utility) { [weak self] in
                guard let self = self else { return }
                await self.sweepOldTranscriptions(modelContext: modelContext)
            }
        }
    }

    private func sweepOldTranscriptions(modelContext: ModelContext) async {
        guard UserDefaults.standard.bool(forKey: keyIsEnabled) else {
            return
        }

        let retentionMinutes = UserDefaults.standard.integer(forKey: keyRetentionMinutes)
        let effectiveMinutes = max(retentionMinutes, 1)

        let cutoffDate = Date().addingTimeInterval(TimeInterval(-effectiveMinutes * 60))

        let modelContainer = await MainActor.run { modelContext.container }

        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                defer { continuation.resume() }
                do {
                    let backgroundContext = ModelContext(modelContainer)

                    let descriptor = FetchDescriptor<Transcription>(
                        predicate: #Predicate<Transcription> { transcription in
                            transcription.timestamp < cutoffDate
                        }
                    )
                    let items = try backgroundContext.fetch(descriptor)
                    var deletedCount = 0
                    for transcription in items {
                        if let urlString = transcription.audioFileURL,
                           let url = URL(string: urlString),
                           FileManager.default.fileExists(atPath: url.path) {
                            try? FileManager.default.removeItem(at: url)
                        }
                        backgroundContext.delete(transcription)
                        deletedCount += 1
                    }
                    if deletedCount > 0 {
                        try backgroundContext.save()
                        self.logger.notice("Cleaned up \(deletedCount) old transcription(s)")
                        Task { @MainActor in
                            NotificationCenter.default.post(name: .transcriptionDeleted, object: nil)
                        }
                    }
                } catch {
                    self.logger.error("Failed during transcription cleanup: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Deletes audio files in Recordings directory that have no corresponding Transcription record
    private func cleanupOrphanAudioFiles(modelContext: ModelContext) async {
        guard UserDefaults.standard.bool(forKey: keyIsEnabled) else {
            return
        }

        let modelContainer = await MainActor.run { modelContext.container }

        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                defer { continuation.resume() }
                do {
                    let backgroundContext = ModelContext(modelContainer)

                    var descriptor = FetchDescriptor<Transcription>()
                    descriptor.propertiesToFetch = [\.audioFileURL]

                    let transcriptions = try backgroundContext.fetch(descriptor)
                    let referencedFiles = Set(transcriptions.compactMap { transcription -> String? in
                        guard let urlString = transcription.audioFileURL,
                              let url = URL(string: urlString) else { return nil }
                        return url.lastPathComponent
                    })

                    guard FileManager.default.fileExists(atPath: self.recordingsDirectory.path) else { return }
                    let filesInDirectory = try FileManager.default.contentsOfDirectory(
                        at: self.recordingsDirectory,
                        includingPropertiesForKeys: nil
                    )

                    var deletedCount = 0
                    for fileURL in filesInDirectory {
                        let fileName = fileURL.lastPathComponent
                        if !referencedFiles.contains(fileName) {
                            try? FileManager.default.removeItem(at: fileURL)
                            deletedCount += 1
                        }
                    }

                    if deletedCount > 0 {
                        self.logger.notice("Cleaned up \(deletedCount) orphan audio file(s)")
                    }
                } catch {
                    self.logger.error("Failed during orphan audio cleanup: \(error.localizedDescription)")
                }
            }
        }
    }
}
