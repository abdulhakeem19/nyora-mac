import Foundation

/// Remembers the cover each manga was shown with in a list / search result, so the SAME
/// cover is used everywhere (details, favourites, history, updates, bookmarks).
///
/// Why: for many sources the engine's details payload carries a different image than the
/// list payload — an `og:image` share card, a differently-cropped copy, or nothing — and
/// favourites are saved from the details copy. List covers are the real cover art, so the
/// list cover wins.
///
/// Helper image URLs look like `http://127.0.0.1:<port>/image?u=…&h=…` and the port changes
/// on every launch, so covers are stored WITHOUT the host/port and rebuilt against the
/// current helper address when read.
struct CoverStore {
    private struct Entry: Codable {
        var rel: String
        var at: Double
    }

    private var entries: [String: Entry] = [:]
    private let fileURL: URL?
    private let maxEntries: Int

    init(fileURL: URL?, maxEntries: Int = 5000) {
        self.fileURL = fileURL
        self.maxEntries = maxEntries
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    /// Remembers `cover` for manga `id`. Returns true when the stored cover changed
    /// (so the caller knows to persist). Empty ids/covers are ignored.
    @discardableResult
    mutating func record(id: String, cover: String, now: Date = Date()) -> Bool {
        guard !id.isEmpty, !cover.isEmpty else { return false }
        let rel = Self.relative(cover)
        if var existing = entries[id], existing.rel == rel {
            existing.at = now.timeIntervalSince1970   // seen again — keep it fresh
            entries[id] = existing
            return false
        }
        entries[id] = Entry(rel: rel, at: now.timeIntervalSince1970)
        return true
    }

    /// The remembered cover for `id`, rebuilt against the current helper `base`; nil if unknown.
    func canonical(id: String, base: URL) -> String? {
        guard let entry = entries[id] else { return nil }
        return Self.resolve(entry.rel, base: base)
    }

    /// Writes the store to disk, keeping only the `maxEntries` most recently seen covers.
    mutating func save() {
        if entries.count > maxEntries {
            let keep = entries.sorted { $0.value.at > $1.value.at }.prefix(maxEntries)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        guard let fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: URL shape

    private static let proxyPrefix = "/image?"

    /// Strips the helper's host:port from its own `/image?…` proxy URLs; everything else
    /// (real CDN URLs, other loopback paths) is returned unchanged.
    static func relative(_ url: String) -> String {
        guard let comps = URLComponents(string: url),
              let host = comps.host, host == "127.0.0.1" || host == "localhost",
              comps.path == "/image",
              let query = comps.percentEncodedQuery
        else { return url }
        return proxyPrefix + query
    }

    /// Inverse of `relative`: rebuilds a proxy URL on the current helper `base`.
    static func resolve(_ stored: String, base: URL) -> String {
        guard stored.hasPrefix(proxyPrefix),
              var comps = URLComponents(url: base.appendingPathComponent("image"), resolvingAgainstBaseURL: false)
        else { return stored }
        comps.percentEncodedQuery = String(stored.dropFirst(proxyPrefix.count))
        return comps.url?.absoluteString ?? stored
    }
}
