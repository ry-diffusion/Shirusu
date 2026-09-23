import FluidAudio
import Foundation

/// Checks the model repository only after the cached model is usable. An update
/// is downloaded beside the current cache and installed on the next launch.
nonisolated enum ModelUpdates {
    private static let repository = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    private static let revisionFile = ".shirusu-model-revision"
    private static let pendingName = ".shirusu-pending-parakeet"
    private static let backupName = ".shirusu-previous-parakeet"

    private static var installedDirectory: URL { ShirusuModel.installDirectory }
    private static var parentDirectory: URL { installedDirectory.deletingLastPathComponent() }
    private static var pendingRoot: URL {
        parentDirectory.appendingPathComponent(pendingName, isDirectory: true)
    }
    private static var pendingDirectory: URL {
        pendingRoot.appendingPathComponent(installedDirectory.lastPathComponent, isDirectory: true)
    }
    private static var backupDirectory: URL {
        parentDirectory.appendingPathComponent(backupName, isDirectory: true)
    }

    private static func revision(at directory: URL) -> String? {
        let url = directory.appendingPathComponent(revisionFile)
        return (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func saveRevision(_ revision: String, at directory: URL) throws {
        try Data(revision.utf8).write(
            to: directory.appendingPathComponent(revisionFile), options: .atomic)
    }

    /// Restore the old cache after an interrupted swap, then install a complete
    /// staged download. The working model is never deleted before a replacement
    /// has finished downloading.
    static func installPending() async throws {
        let files = FileManager.default
        if files.fileExists(atPath: backupDirectory.path) {
            if ShirusuModel.isInstalled {
                try files.removeItem(at: backupDirectory)
            } else {
                if files.fileExists(atPath: installedDirectory.path) {
                    try files.removeItem(at: installedDirectory)
                }
                try files.moveItem(at: backupDirectory, to: installedDirectory)
            }
        }

        guard AsrModels.modelsExist(at: pendingDirectory, version: ShirusuModel.version),
              revision(at: pendingDirectory) != nil else { return }

        // Validate CoreML loading while the known-good model is still in place.
        do {
            _ = try await AsrModels.load(
                from: pendingDirectory, version: ShirusuModel.version)
        } catch {
            try? files.removeItem(at: pendingRoot)
            throw error
        }

        let hadCurrent = files.fileExists(atPath: installedDirectory.path)
        if hadCurrent {
            try files.moveItem(at: installedDirectory, to: backupDirectory)
        }
        do {
            try files.moveItem(at: pendingDirectory, to: installedDirectory)
            try? files.removeItem(at: pendingRoot)
            if hadCurrent { try? files.removeItem(at: backupDirectory) }
        } catch {
            if !files.fileExists(atPath: installedDirectory.path), hadCurrent {
                try? files.moveItem(at: backupDirectory, to: installedDirectory)
            }
            throw error
        }
    }

    /// A failed or timed out check is ignored by the caller: local recognition
    /// is ready before this optional request starts.
    static func availableRevision() async throws -> String? {
        guard ShirusuModel.isInstalled else { return nil }
        let remote = try await remoteRevision()

        guard let installed = revision(at: installedDirectory) else {
            // Older installs predate revision tracking. Record a baseline
            // without presenting their existing model as a new update.
            try saveRevision(remote, at: installedDirectory)
            return nil
        }
        if revision(at: pendingDirectory) == remote { return nil }
        return remote == installed ? nil : remote
    }

    private static func remoteRevision() async throws -> String {
        let url = URL(string: "https://huggingface.co/api/models/\(repository)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200 else { throw UpdateError.revisionUnavailable }
        let remote = try JSONDecoder().decode(ModelInfo.self, from: data).sha
        guard remote.count == 40, remote.allSatisfy(\.isHexDigit) else {
            throw UpdateError.revisionUnavailable
        }
        return remote
    }

    static func download(_ revision: String) async throws {
        let files = FileManager.default
        if Self.revision(at: pendingRoot) != revision {
            if files.fileExists(atPath: pendingRoot.path) {
                try files.removeItem(at: pendingRoot)
            }
            try files.createDirectory(at: pendingRoot, withIntermediateDirectories: true)
            try saveRevision(revision, at: pendingRoot)
        }

        _ = try await AsrModels.download(
            to: pendingDirectory,
            version: ShirusuModel.version
        )
        guard AsrModels.modelsExist(at: pendingDirectory, version: ShirusuModel.version) else {
            throw UpdateError.incompleteDownload
        }
        guard try await remoteRevision() == revision else {
            throw UpdateError.repositoryChanged
        }
        try saveRevision(revision, at: pendingDirectory)
    }

    private struct ModelInfo: Decodable { let sha: String }
    private enum UpdateError: LocalizedError {
        case incompleteDownload
        case repositoryChanged
        case revisionUnavailable
        var errorDescription: String? {
            switch self {
            case .incompleteDownload:
                String(localized: "The model download is incomplete. Try again later.")
            case .repositoryChanged:
                String(localized: "The model changed while downloading. Try again later.")
            case .revisionUnavailable:
                String(localized: "The model version could not be checked. Try again later.")
            }
        }
    }
}
