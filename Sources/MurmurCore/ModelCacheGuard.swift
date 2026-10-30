import Foundation

/// Core ML keeps a "saved copy" of the speech model for this app, only so it starts faster. The copy is a set of tiny
/// pointer files to data that macOS keeps elsewhere and can drop whenever it likes (after a restart, or after the Mac
/// sleeps and wakes). A pointer to dropped data aborts Murmur on launch, every time, until the copy is deleted
/// (seen on 2026-10-28 and again on 2026-10-29). So the copy is thrown away before every load. The model then
/// loads a few seconds slower and can never hit this.
public struct ModelCacheGuard {
    private static let cacheFolderName = "com.apple.e5rt.e5bundlecache"

    private let cacheURL: URL

    public init(cacheURL: URL) {
        self.cacheURL = cacheURL
    }

    /// For the running app. Nil when macOS cannot say what the app's identifier is.
    public static func forThisApp() -> ModelCacheGuard? {
        guard let id = Bundle.main.bundleIdentifier,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        return ModelCacheGuard(
            cacheURL: caches.appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent(cacheFolderName, isDirectory: true))
    }

    /// Deletes the saved copy. True if there was one to delete.
    @discardableResult
    public func clear() -> Bool {
        // Only ever remove the one folder Core ML makes for this app.
        guard cacheURL.lastPathComponent == Self.cacheFolderName,
              FileManager.default.fileExists(atPath: cacheURL.path)
        else { return false }
        return (try? FileManager.default.removeItem(at: cacheURL)) != nil
    }
}
