import Foundation

/// Core ML keeps a ready-to-run copy of the speech model for this app, only so it starts faster. After the Mac restarts,
/// that copy can stop working and abort Murmur on every launch (it did on 2026-10-28). The copy is rebuilt in a few
/// seconds, so it is thrown away whenever the Mac has restarted since the last good start, or the last start never
/// finished loading the model.
public struct ModelCacheGuard {
    private struct State: Codable {
        var boot: Int
        var finished: Bool
    }

    /// The Mac's start time can shift by a few seconds when its clock is corrected. A real restart is far more than this.
    private static let drift = 120
    private static let cacheFolderName = "com.apple.e5rt.e5bundlecache"

    private let stateURL: URL
    private let cacheURL: URL
    private let boot: Int

    public init(stateURL: URL, cacheURL: URL, boot: Int) {
        self.stateURL = stateURL
        self.cacheURL = cacheURL
        self.boot = boot
    }

    /// For the running app. Nil when macOS cannot say what the app's identifier or the Mac's start time is.
    public static func forThisMac(files: AppFiles) -> ModelCacheGuard? {
        guard let id = Bundle.main.bundleIdentifier,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        var started = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &started, &size, nil, 0) == 0 else { return nil }
        return ModelCacheGuard(
            stateURL: files.directory.appendingPathComponent("model-load.json"),
            cacheURL: caches.appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent(cacheFolderName, isDirectory: true),
            boot: Int(started.tv_sec))
    }

    /// Call just before loading the model. Returns true if the saved copy was thrown away.
    @discardableResult
    public func prepare() -> Bool {
        let lastStartWasGood = read().map { abs($0.boot - boot) <= Self.drift && $0.finished } ?? false
        var cleared = false
        // Only ever remove the one folder Core ML makes for this app.
        if !lastStartWasGood, cacheURL.lastPathComponent == Self.cacheFolderName,
           FileManager.default.fileExists(atPath: cacheURL.path) {
            cleared = (try? FileManager.default.removeItem(at: cacheURL)) != nil
        }
        write(State(boot: boot, finished: false))
        return cleared
    }

    /// Call once the model has loaded and run once. The next start keeps the saved copy.
    public func finished() {
        write(State(boot: boot, finished: true))
    }

    private func read() -> State? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private func write(_ state: State) {
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }
}
