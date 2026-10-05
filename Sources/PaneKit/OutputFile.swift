import Foundation

/// Files Pane writes next to a video: the edited copy, its captions. Each is written in
/// a scratch folder on the same disk and moved into place only once it's complete, so
/// quitting or crashing mid-export never leaves a cut-off copy that looks finished. An
/// earlier copy Pane wrote is replaced; anything else in the way goes to the Trash.
public enum OutputFile {
    /// Set on files Pane wrote, so writing them again may replace them.
    static let attributeName = "com.jacobhokanson.pane.output"

    /// Where to write `destination`'s new contents. `place` moves it into place;
    /// `discard` cleans up either way.
    public static func scratch(for destination: URL) throws -> URL {
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                 appropriateFor: destination, create: true)
        return folder.appendingPathComponent(destination.lastPathComponent)
    }

    /// Moves the finished `scratch` file to `destination`.
    public static func place(_ scratch: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        // attributesOfItem doesn't follow symbolic links: a link in the way is moved
        // aside like any other file, never written through.
        if (try? fileManager.attributesOfItem(atPath: destination.path)) != nil {
            // A disk with no Trash (some network shares) gets the old way: replaced.
            if !isPanes(destination), (try? fileManager.trashItem(at: destination, resultingItemURL: nil)) != nil {
                try fileManager.moveItem(at: scratch, to: destination)
            } else {
                _ = try fileManager.replaceItemAt(destination, withItemAt: scratch)
            }
        } else {
            try fileManager.moveItem(at: scratch, to: destination)
        }
        setxattr(destination.path, attributeName, nil, 0, 0, XATTR_NOFOLLOW)
    }

    /// Removes the scratch folder and whatever is still in it.
    public static func discard(_ scratch: URL) {
        try? FileManager.default.removeItem(at: scratch.deletingLastPathComponent())
    }

    /// Writes `data` to `destination` the same way.
    public static func write(_ data: Data, to destination: URL) throws {
        let scratch = try scratch(for: destination)
        defer { discard(scratch) }
        try data.write(to: scratch)
        try place(scratch, at: destination)
    }

    static func isPanes(_ url: URL) -> Bool {
        getxattr(url.path, attributeName, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }
}
