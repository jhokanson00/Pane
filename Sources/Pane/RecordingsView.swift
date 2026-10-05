import AVFoundation
import AppKit
import SwiftUI
import PaneKit

/// The recordings folder as a list: every video with its size, to review, rename or move
/// to the Trash, so the folder doesn't fill up unnoticed (see `VideoLibrary`).
@MainActor
final class RecordingsLibrary: ObservableObject {
    static let shared = RecordingsLibrary()

    @Published private(set) var items: [VideoLibrary.Item] = []
    /// Something that went wrong, shown until dismissed.
    @Published var problem: String?
    private var thumbnails: [URL: CGImage] = [:]
    private var durations: [URL: Double] = [:]

    private var root: URL { RecorderModel.recordingsFolder }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var videoCount: Int { items.filter { $0.kind != .other }.count }
    var hasLoose: Bool { items.contains { $0.kind == .loose } }

    /// Reads the folder again, off the main thread.
    func refresh() {
        let root = root, clips = RecorderModel.legacyClipsFolder
        let recording = RecorderModel.shared.recordingFolder
        Task.detached(priority: .userInitiated) {
            let items = VideoLibrary.items(in: root, legacyClips: clips, skipping: recording)
            await MainActor.run { RecordingsLibrary.shared.items = items }
        }
    }

    // MARK: - Actions

    func review(_ item: VideoLibrary.Item) {
        guard let url = item.video ?? item.edited else { return }
        RecorderModel.shared.openReview(of: url)
    }

    func rename(_ item: VideoLibrary.Item, to title: String) {
        guard item.kind == .folder, let folder = item.files.first else { return }
        rename(folder: folder, video: item.video, to: title)
    }

    /// Renames the video shown in a review window, from its name field.
    /// - Returns: What went wrong, if it couldn't be renamed.
    func rename(videoAt url: URL, to title: String) -> String? {
        guard VideoLibrary.isInFolder(url, root: root) else { return nil }
        let failure = rename(folder: url.deletingLastPathComponent(), video: url, to: title)
        problem = nil
        return failure
    }

    @discardableResult
    private func rename(folder: URL, video: URL?, to title: String) -> String? {
        defer { refresh() }
        if let video, RecorderModel.shared.isBusy(video) {
            problem = "This video is still being exported or scanned. Rename it when that's done."
            return problem
        }
        do {
            let renamed = try VideoLibrary.rename(folder, title: title)
            RecorderModel.shared.filesMoved { VideoLibrary.renamed($0, from: folder, to: renamed) }
            return nil
        } catch {
            problem = "Couldn't rename it: \(error.localizedDescription)"
            return problem
        }
    }

    /// Moves everything that belongs to the video to the Trash.
    func trash(_ item: VideoLibrary.Item) {
        moveToTrash(item.files, video: item.video)
    }

    /// Moves the recording and its separate clips to the Trash, keeping the edited copy,
    /// captions and Final Cut files.
    func keepOnlyEdited(_ item: VideoLibrary.Item) {
        guard item.edited != nil, let video = item.video else { return }
        moveToTrash([video] + [item.clips].compactMap { $0 }, video: video)
    }

    private func moveToTrash(_ files: [URL], video: URL?) {
        if let video, RecorderModel.shared.isBusy(video) {
            problem = "This video is still being exported or scanned. Try again when that's done."
            return
        }
        WindowPresenter.closeReviews(showing: files)
        for file in files {
            do {
                try FileManager.default.trashItem(at: file, resultingItemURL: nil)
            } catch {
                problem = "Couldn't move \(file.lastPathComponent) to the Trash: \(error.localizedDescription)"
            }
        }
        if let video { RecorderModel.shared.recordingRemoved(video) }
        refresh()
    }

    /// Gathers recordings from before folders into folders.
    func organize() {
        let loose = items.filter { $0.kind == .loose }.flatMap(\.files).map(\.standardizedFileURL.path)
        if WindowPresenter.openReviews.contains(where: { loose.contains($0.sourceURL.standardizedFileURL.path) }) {
            problem = "Close the Review windows of older recordings first."
            return
        }
        do {
            let moved = try VideoLibrary.organize(root, legacyClips: RecorderModel.legacyClipsFolder)
            RecorderModel.shared.filesMoved { moved[$0.standardizedFileURL] }
        } catch {
            problem = "Couldn't organize everything: \(error.localizedDescription)"
        }
        refresh()
    }

    // MARK: - Details

    /// A frame from a second in, small, for the list.
    func thumbnail(for url: URL) async -> CGImage? {
        if let cached = thumbnails[url] { return cached }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 136)
        let image = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        thumbnails[url] = image
        return image
    }

    func duration(of url: URL) async -> Double? {
        if let cached = durations[url] { return cached }
        let seconds = try? await AVURLAsset(url: url).load(.duration).seconds
        durations[url] = seconds
        return seconds
    }
}

struct RecordingsView: View {
    @EnvironmentObject private var model: RecorderModel
    @ObservedObject private var library = RecordingsLibrary.shared
    @State private var renaming: VideoLibrary.Item?
    @State private var newTitle = ""
    @State private var trashing: VideoLibrary.Item?
    @State private var trimming: VideoLibrary.Item?
    @State private var organizing = false

    var body: some View {
        VStack(spacing: 0) {
            if library.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No recordings yet.")
                    Text("Each recording gets its own folder in Movies \u{25B8} Pane.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(library.items) { item in
                    RecordingRow(item: item, rename: {
                        newTitle = item.title
                        renaming = item
                    }, trash: { trashing = item }, keepOnlyEdited: { trimming = item })
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            if let problem = library.problem {
                HStack {
                    WarningText(problem)
                    Spacer()
                    Button("OK") { library.problem = nil }
                }
                .padding(10)
            }
            Divider()
            HStack {
                Text("\(library.videoCount) video\(library.videoCount == 1 ? "" : "s"), "
                     + ByteCountFormatter.string(fromByteCount: library.totalSize, countStyle: .file))
                    .foregroundStyle(.secondary)
                Spacer()
                if library.hasLoose {
                    Button("Organize Older Recordings…") { organizing = true }
                        .help("Put recordings from before folders into folders of their own")
                }
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(at: RecorderModel.recordingsFolder,
                                                             withIntermediateDirectories: true)
                    NSWorkspace.shared.open(RecorderModel.recordingsFolder)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 360)
        .onAppear { library.refresh() }
        .onReceive(model.$lastRecordingURL) { _ in library.refresh() }
        .onReceive(model.$recordingFolder) { _ in library.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            library.refresh()
        }
        .alert("Rename Video", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newTitle)
            Button("Rename") {
                if let renaming { library.rename(renaming, to: newTitle) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(renaming?.finalCut != nil
                 ? "Its folder and files are renamed too. Final Cut projects made from it will ask you to find its files again."
                 : "Its folder and files are renamed too.")
        }
        .confirmationDialog("Move \u{201C}\(trashing.map(display) ?? "")\u{201D} to the Trash?",
                            isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let trashing { library.trash(trashing) }
            }
        } message: {
            Text("The recording, its edited copy, captions and Final Cut files all go to the Trash. "
                 + "You can put them back from there until it's emptied.")
        }
        .confirmationDialog("Keep only the edited copy?",
                            isPresented: Binding(get: { trimming != nil }, set: { if !$0 { trimming = nil } })) {
            Button("Move Original to Trash", role: .destructive) {
                if let trimming { library.keepOnlyEdited(trimming) }
            }
        } message: {
            Text("The original recording and its camera clips go to the Trash. The edited copy, captions and "
                 + "Final Cut files stay. You won't be able to change this video's blurs or effects again.")
        }
        .confirmationDialog("Organize older recordings?", isPresented: $organizing) {
            Button("Organize") { library.organize() }
        } message: {
            Text("Each older recording, with its edited copy, captions and camera clips, moves into a folder of "
                 + "its own, named like \u{201C}Untitled 2026-10-02 12.11\u{201D}. Final Cut folders stay where they "
                 + "are, so projects already in Final Cut still find their files.")
        }
    }

    private func display(_ item: VideoLibrary.Item) -> String {
        item.title.isEmpty ? VideoLibrary.untitled : item.title
    }
}

private struct RecordingRow: View {
    @EnvironmentObject private var model: RecorderModel
    @ObservedObject private var library = RecordingsLibrary.shared
    let item: VideoLibrary.Item
    let rename: () -> Void
    let trash: () -> Void
    let keepOnlyEdited: () -> Void
    @State private var thumbnail: CGImage?
    @State private var duration: Double?

    var body: some View {
        HStack(spacing: 12) {
            preview
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).lineLimit(1)
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !parts.isEmpty {
                    Text(parts).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            if item.kind != .other {
                Button("Review") { library.review(item) }
                    .disabled(model.state != .idle)
            }
            Menu {
                if let video = item.video {
                    Button("Play") { NSWorkspace.shared.open(video) }
                }
                if let edited = item.edited {
                    Button("Play Edited Copy") { NSWorkspace.shared.open(edited) }
                }
                if item.kind != .other { Divider() }
                if item.kind == .folder {
                    Button("Rename…", action: rename)
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(item.files) }
                Divider()
                if item.video != nil, item.edited != nil {
                    Button("Keep Only the Edited Copy…", action: keepOnlyEdited)
                }
                Button("Move to Trash…", action: trash)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if item.kind != .other { library.review(item) } }
        .task(id: item.id) {
            guard let url = item.edited ?? item.video else { return }
            thumbnail = await library.thumbnail(for: url)
            duration = await library.duration(of: url)
        }
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15))
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: item.kind == .other ? "folder" : "film").foregroundStyle(.secondary)
            }
        }
        .frame(width: 112, height: 63)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var title: String {
        guard item.kind != .other else { return item.name }
        let take = VideoLibrary.take(of: item.name)
        return (item.title.isEmpty ? VideoLibrary.untitled : item.title) + (take > 1 ? ", Take \(take)" : "")
    }

    private var details: String {
        var parts: [String] = []
        if item.kind != .other { parts.append(item.date.formatted(date: .abbreviated, time: .shortened)) }
        if let duration { parts.append(ReviewSession.format(duration)) }
        parts.append(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
        if item.kind == .loose { parts.append("not in a folder yet") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// What it has besides the recording.
    private var parts: String {
        var parts: [String] = []
        if item.video == nil, item.kind != .other { parts.append("Original moved to the Trash") }
        if item.edited != nil { parts.append("Edited copy") }
        if item.captions != nil { parts.append("Captions") }
        if item.finalCut != nil { parts.append("Final Cut") }
        if item.clips != nil { parts.append("Camera clips") }
        return parts.joined(separator: " \u{00B7} ")
    }
}
