import Foundation

/// The recordings folder, one folder per video:
///
///     Movies/Pane/
///       Share a Project 2026-10-05/
///         Share a Project 2026-10-05.mp4             the recording (never changed)
///         Share a Project 2026-10-05 (Edited).mp4    Export Video
///         Share a Project 2026-10-05 (Edited).srt    captions
///         Share a Project 2026-10-05 (Final Cut)/    Send to Final Cut
///         Clips for Final Cut (not blurred)/         screen and camera kept apart
///
/// A video's name is its title and the day it was made, and "Take 2" and on for another
/// recording with the same title that day. Untitled videos get the time too. Moving one
/// folder to the Trash removes everything that belongs to a video.
///
/// Recordings from before folders (loose files named "Pane Recording <date> at <time>",
/// with their clips in Application Support) are listed too, and `organize` moves them
/// into folders.
public enum VideoLibrary {
    /// The folder of separate screen and camera clips inside a video's folder: the
    /// recording before blurs, named so it's never taken for "(Final Cut)/Screen.mp4".
    public static let clipsFolderName = "Clips for Final Cut (not blurred)"
    public static let untitled = "Untitled"

    // MARK: - Names

    /// "Share a Project 2026-10-05", "… Take 2"; untitled, "Untitled 2026-10-05 09.19".
    public static func name(title: String, date: Date, take: Int = 1) -> String {
        let title = cleaned(title)
        var name = (title.isEmpty ? untitled : title) + " " + format(date, title.isEmpty ? "yyyy-MM-dd HH.mm" : "yyyy-MM-dd")
        if take > 1 { name += " Take \(take)" }
        return name
    }

    /// A name no video in `folder` has yet: the first free take.
    public static func uniqueName(title: String, date: Date, in folder: URL) -> String {
        var take = 1
        while true {
            let name = name(title: title, date: date, take: take)
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) { return name }
            take += 1
        }
    }

    /// The title in a video's name, without its date, time and take ("" when untitled, as
    /// recordings from before names are).
    public static func title(of name: String) -> String {
        if name.firstMatch(of: legacyPattern) != nil { return "" }
        guard let match = name.firstMatch(of: namePattern) else { return name }
        let title = String(match.1)
        return title == untitled ? "" : title
    }

    /// The take in a name: 2 for "… Take 2", otherwise 1.
    public static func take(of name: String) -> Int {
        name.firstMatch(of: namePattern)?.4.flatMap { Int($0) } ?? 1
    }

    /// The day (and for untitled videos the time) in a name, either kind.
    static func date(in name: String) -> Date? {
        if let match = name.firstMatch(of: namePattern) {
            return parse(match.3.map { "\(match.2) \($0)" } ?? String(match.2),
                         match.3 == nil ? "yyyy-MM-dd" : "yyyy-MM-dd HH.mm")
        }
        if let match = name.firstMatch(of: legacyPattern) { return parse("\(match.1) \(match.2)", "yyyy-MM-dd HH.mm.ss") }
        return nil
    }

    /// Titles can't hold the characters Finder and the disk use to separate folders, and stay
    /// a sensible length.
    public static func cleaned(_ title: String) -> String {
        let replaced = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let words = replaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(words.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    nonisolated(unsafe) private static let namePattern =
        #/^(.+?) (\d{4}-\d{2}-\d{2})(?: (\d{2}\.\d{2}))?(?: Take (\d+))?$/#
    nonisolated(unsafe) private static let legacyPattern =
        #/^(?:Pane|Veil) Recording (\d{4}-\d{2}-\d{2}) at (\d{2}\.\d{2}\.\d{2})$/#

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private static func parse(_ text: String, _ pattern: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.date(from: text)
    }

    // MARK: - Listing

    /// One video, or something else in the recordings folder.
    public struct Item: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// A video in its own folder.
            case folder
            /// A recording from before folders: loose files that `organize` gathers up.
            case loose
            /// Anything else, like a Final Cut folder left where it was, or the clips of
            /// recordings that are gone.
            case other
        }

        public var id: URL { files.first! }
        public var kind: Kind
        public var name: String
        /// The recording itself, if it's still there.
        public var video: URL?
        /// Export Video's copy, if there is one.
        public var edited: URL?
        public var captions: URL?
        public var finalCut: URL?
        public var clips: URL?
        /// Everything that belongs to it: the folder, or for a loose recording each file.
        public var files: [URL]
        public var date: Date
        /// Bytes on disk, all its files together.
        public var size: Int64

        public var title: String { kind == .other ? name : VideoLibrary.title(of: name) }
    }

    /// What's in the recordings folder: videos newest first, then anything else.
    /// - Parameters:
    ///   - legacyClips: Where clips were kept before folders, one folder per recording name.
    ///   - skipping: A folder to leave out, such as the one being recorded into.
    public static func items(in root: URL, legacyClips: URL? = nil, skipping: URL? = nil) -> [Item] {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                                                        options: [.skipsHiddenFiles])) ?? []
        var items: [Item] = []
        // Paths, since the same file can come as differently spelled URLs.
        var claimed = Set<String>()
        let skipped = skipping?.standardizedFileURL.path

        // Videos in their own folders.
        for entry in entries where isDirectory(entry) && entry.standardizedFileURL.path != skipped {
            let name = entry.lastPathComponent
            let video = entry.appendingPathComponent(name + ".mp4")
            let edited = entry.appendingPathComponent(name + " (Edited).mp4")
            guard exists(video) || exists(edited) else { continue }
            claimed.insert(entry.standardizedFileURL.path)
            items.append(Item(
                kind: .folder, name: name, video: exists(video) ? video : nil, edited: exists(edited) ? edited : nil,
                captions: existing(entry.appendingPathComponent(name + " (Edited).srt")),
                finalCut: existing(entry.appendingPathComponent(name + " (Final Cut)")),
                clips: existing(entry.appendingPathComponent(clipsFolderName)),
                // When the recording was made: a named video's name only has the day.
                files: [entry], date: [video, edited].first(where: exists).map(created) ?? date(in: name) ?? created(entry),
                size: size(of: entry)))
        }

        // Loose recordings, grouped by name.
        let videos = entries.filter { $0.pathExtension.lowercased() == "mp4" && !isDirectory($0) }
        var bases = Set(videos.map { baseName(of: $0) })
        bases.formUnion(entries.filter { $0.pathExtension.lowercased() == "srt" }.map { baseName(of: $0) })
        for base in bases.sorted() {
            let video = root.appendingPathComponent(base + ".mp4")
            // The first versions called the copy "(Blurred)".
            let edited = [" (Edited)", " (Blurred)"].map { root.appendingPathComponent(base + $0 + ".mp4") }
                .first(where: exists) ?? root.appendingPathComponent(base + " (Edited).mp4")
            guard exists(video) || exists(edited) else { continue }
            let captions = existing(root.appendingPathComponent(base + " (Edited).srt"))
            let clips = legacyClips.flatMap { existing($0.appendingPathComponent(base)) }
            // A Final Cut folder stays where it is: projects already in Final Cut point to it.
            let files = [video, edited].filter(exists) + [captions, clips].compactMap { $0 }
            claimed.formUnion(files.map(\.standardizedFileURL.path))
            items.append(Item(
                kind: .loose, name: base, video: exists(video) ? video : nil, edited: exists(edited) ? edited : nil,
                captions: captions, finalCut: nil, clips: clips, files: files,
                date: date(in: base) ?? created(exists(video) ? video : edited),
                size: files.reduce(0) { $0 + size(of: $1) }))
        }

        // Everything else.
        for entry in entries where !claimed.contains(entry.standardizedFileURL.path) && entry.standardizedFileURL.path != skipped {
            items.append(Item(kind: .other, name: entry.lastPathComponent, files: [entry],
                              date: created(entry), size: size(of: entry)))
        }
        // Clips whose recording is gone.
        if let legacyClips {
            let leftover = ((try? manager.contentsOfDirectory(at: legacyClips, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles])) ?? [])
                .filter { !claimed.contains($0.standardizedFileURL.path) }
            if !leftover.isEmpty {
                items.append(Item(kind: .other, name: "Clips from recordings that are gone", files: leftover,
                                  date: leftover.map(created).min() ?? Date(),
                                  size: leftover.reduce(0) { $0 + size(of: $1) }))
            }
        }
        // Videos newest first, then everything else.
        return items.sorted { ($0.kind == .other ? 1 : 0, $1.date) < ($1.kind == .other ? 1 : 0, $0.date) }
    }

    /// "X (Edited).mp4" and "X.mp4" both belong to X (and "X (Blurred).mp4", from the first
    /// versions).
    static func baseName(of url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        for suffix in [" (Edited)", " (Blurred)"] where name.hasSuffix(suffix) { return String(name.dropLast(suffix.count)) }
        return name
    }

    // MARK: - Changing

    /// Gathers loose recordings into folders, named the new way ("Untitled 2026-10-02
    /// 12.11" for "Pane Recording 2026-10-02 at 12.11.29"). Final Cut folders stay where
    /// they are, since projects already in Final Cut point to them.
    /// - Returns: Where each file moved, old to new.
    @discardableResult
    public static func organize(_ root: URL, legacyClips: URL? = nil) throws -> [URL: URL] {
        var moved: [URL: URL] = [:]
        func move(_ from: URL, to: URL) throws {
            try FileManager.default.moveItem(at: from, to: to)
            moved[from.standardizedFileURL] = to
        }
        // Oldest first, so a second recording in the same minute becomes Take 2.
        for item in items(in: root, legacyClips: legacyClips).reversed() where item.kind == .loose {
            let made = date(in: item.name)
            let name = uniqueName(title: made == nil ? item.name : "", date: made ?? item.date, in: root)
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            if let video = item.video { try move(video, to: folder.appendingPathComponent(name + ".mp4")) }
            if let edited = item.edited { try move(edited, to: folder.appendingPathComponent(name + " (Edited).mp4")) }
            if let captions = item.captions { try move(captions, to: folder.appendingPathComponent(name + " (Edited).srt")) }
            if let clips = item.clips { try move(clips, to: folder.appendingPathComponent(clipsFolderName)) }
        }
        return moved
    }

    /// Renames a video's folder and the files named after it.
    /// - Returns: The renamed folder.
    public static func rename(_ folder: URL, title: String) throws -> URL {
        let old = folder.lastPathComponent
        let root = folder.deletingLastPathComponent()
        guard cleaned(title) != VideoLibrary.title(of: old) else { return folder }
        let name = uniqueName(title: title, date: date(in: old) ?? created(folder), in: root)
        let renamed = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: renamed)
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: renamed.path)) ?? [] where entry.hasPrefix(old) {
            let rest = entry.dropFirst(old.count)
            // Only the files named after it: "<name>.mp4", "<name> (Edited).mp4" and the like.
            guard rest.hasPrefix(".") || rest.hasPrefix(" (") else { continue }
            try FileManager.default.moveItem(at: renamed.appendingPathComponent(entry),
                                             to: renamed.appendingPathComponent(name + rest))
        }
        return renamed
    }

    /// Where a file in a video's folder is after `rename` moved the folder from `old` to
    /// `new`, or nil if it wasn't in it.
    public static func renamed(_ url: URL, from old: URL, to new: URL) -> URL? {
        guard url.deletingLastPathComponent().standardizedFileURL.path == old.standardizedFileURL.path else { return nil }
        let file = url.lastPathComponent, oldName = old.lastPathComponent
        let rest = file.hasPrefix(oldName) ? file.dropFirst(oldName.count) : ""
        let renamed = file.hasPrefix(oldName) && (rest.hasPrefix(".") || rest.hasPrefix(" (")) ? new.lastPathComponent + rest : file
        return new.appendingPathComponent(renamed)
    }

    /// The recording itself in a video folder.
    public static func video(in folder: URL) -> URL {
        folder.appendingPathComponent(folder.lastPathComponent + ".mp4")
    }

    /// Whether `url` is a recording in its own folder in `root`.
    public static func isInFolder(_ url: URL, root: URL) -> Bool {
        let folder = url.deletingLastPathComponent()
        return folder.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path
            && url.deletingPathExtension().lastPathComponent == folder.lastPathComponent
    }

    // MARK: - Files

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private static func existing(_ url: URL) -> URL? { exists(url) ? url : nil }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func created(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    /// Bytes on disk, counting everything inside a folder.
    public static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard isDirectory(url) else {
            return Int64((try? url.resourceValues(forKeys: keys).totalFileAllocatedSize) ?? 0)
        }
        var total: Int64 = 0
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let file = walker?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: keys).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
