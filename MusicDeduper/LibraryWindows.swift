//
//  LibraryWindows.swift
//  MusicDeduper
//
//  The "Library" menu's three tool windows: Library Viewer (browse the library
//  with tags + the built-in player), Runs (every applied run, revert any), and
//  Logs (each run's change log, list on the left, content on the right).
//

import SwiftUI
import AppKit

// MARK: - Library browser (a mini-iTunes album grid over any folder)

/// One album, discovered from the folder tree — no file reads needed to list it.
struct LibAlbum: Identifiable, Hashable {
    let id: String        // album folder path
    let artist: String    // from the parent folder
    let album: String     // the album folder name
    let dir: URL
    let files: [URL]
    var sampleURL: URL? { files.first }
    static func == (a: LibAlbum, b: LibAlbum) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct LibraryBrowserView: View {
    @AppStorage("libraryBrowserRoot") private var savedRoot = ""
    @State private var root: URL?
    @State private var albums: [LibAlbum] = []
    @State private var fileCount = 0
    @State private var loading = false
    @State private var search = ""
    @State private var selectedAlbum: LibAlbum?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if root == nil {
                chooser
            } else if loading {
                VStack(spacing: 10) { ProgressView(); Text("Listing your library…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if albums.isEmpty {
                Text("No audio files found here.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                albumGrid
            }
        }
        .sheet(item: $selectedAlbum) { a in LibraryAlbumSheet(album: a) }
        .onAppear { if root == nil && !savedRoot.isEmpty { open(URL(fileURLWithPath: savedRoot)) } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note.list").foregroundStyle(.purple)
            Text(root?.lastPathComponent ?? "Library").font(.headline)
            if !albums.isEmpty {
                Text("\(albums.count) albums · \(fileCount) tracks").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if root != nil {
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            Button { pick() } label: { Label(root == nil ? "Choose library…" : "Change…", systemImage: "folder") }
        }
        .padding(10)
    }

    private var chooser: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "music.note.house").font(.system(size: 44, weight: .light)).foregroundStyle(.purple)
            Text("Browse a music library").font(.title3).fontWeight(.medium)
            Text("Pick a folder and see it as albums — click any album to see its tracks.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            Button { pick() } label: { Label("Choose library…", systemImage: "folder").frame(minWidth: 160) }
                .controlSize(.large).buttonStyle(.borderedProminent).tint(.purple)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filtered: [LibAlbum] {
        guard !search.isEmpty else { return albums }
        let q = search.lowercased()
        return albums.filter { $0.album.lowercased().contains(q) || $0.artist.lowercased().contains(q) }
    }

    private var albumGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2").foregroundStyle(.purple)
                    Text("\(filtered.count) album(s)").fontWeight(.semibold)
                    Text("click an album to see its tracks").font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 176, maximum: 210), spacing: 18)],
                          alignment: .leading, spacing: 18) {
                    ForEach(filtered) { a in albumCard(a) }
                }
            }
            .padding(16)
        }
    }

    private func albumCard(_ a: LibAlbum) -> some View {
        Button { selectedAlbum = a } label: {
            VStack(alignment: .leading, spacing: 8) {
                AlbumCover(key: a.id, sampleURL: a.sampleURL, foundMBID: nil, size: 176)
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.album).font(.subheadline).fontWeight(.medium).lineLimit(1)
                    Text("\(a.artist) · \(a.files.count) track(s)").font(.caption)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: 176)
        }
        .buttonStyle(.plain)
    }

    private func pick() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.prompt = "Browse"; p.message = "Choose a music library folder"
        if p.runModal() == .OK, let u = p.url { open(u) }
    }
    private func open(_ u: URL) { root = u; savedRoot = u.path; albums = []; fileCount = 0; search = ""; load() }

    /// List one folder: its audio files and its sub-folders (one SMB round-trip).
    nonisolated private static func listDir(_ dir: URL) -> (files: [URL], subs: [URL]) {
        var files: [URL] = [], subs: [URL] = []
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return ([], [])
        }
        for u in items {
            if u.lastPathComponent == "Music Librarian Quarantine" { continue }
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir { subs.append(u) } else if PerfectStore.isAudio(u) { files.append(u) }
        }
        return (files, subs)
    }

    /// Build sorted albums from the discovered folders → files map.
    nonisolated private static func buildAlbums(_ byDir: [String: [URL]]) -> [LibAlbum] {
        byDir.map { (dir, urls) -> LibAlbum in
            let dirURL = URL(fileURLWithPath: dir)
            let files = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            return LibAlbum(id: dir, artist: dirURL.deletingLastPathComponent().lastPathComponent,
                            album: dirURL.lastPathComponent, dir: dirURL, files: files)
        }
        .sorted { ($0.artist.lowercased(), $0.album.lowercased()) < ($1.artist.lowercased(), $1.album.lowercased()) }
    }

    /// Walk the tree with CONCURRENT folder listings (SMB round-trips overlap) and
    /// publish albums PROGRESSIVELY as they're found — no per-file reads, so the grid
    /// fills in at listing speed instead of waiting for a serial depth-first walk.
    private func load() {
        guard let root else { return }
        loading = true; albums = []; fileCount = 0
        Task.detached(priority: .userInitiated) {
            var byDir: [String: [URL]] = [:]
            var count = 0
            var queue = [root]
            var firstPublished = false
            while !queue.isEmpty {
                let batch = Array(queue.prefix(16)); queue.removeFirst(batch.count)
                await withTaskGroup(of: (files: [URL], subs: [URL]).self) { g in
                    for d in batch { g.addTask { Self.listDir(d) } }
                    for await r in g {
                        for f in r.files {
                            byDir[f.deletingLastPathComponent().path, default: []].append(f); count += 1
                        }
                        queue.append(contentsOf: r.subs)
                    }
                }
                let snapshot = Self.buildAlbums(byDir); let c = count
                let done = queue.isEmpty
                await MainActor.run {
                    albums = snapshot; fileCount = c
                    if !firstPublished || done { loading = false }
                }
                firstPublished = true
            }
            await MainActor.run { loading = false }
        }
    }
}

/// Album "pop-up" for the Library browser — matches Perfect's Review dialog: a play
/// button + scrubber per track (same AudioPreview) and the file's actual tags, for
/// reviewing a library before/after.
struct LibraryAlbumSheet: View {
    let album: LibAlbum
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var audio = AudioPreview.shared
    @State private var tracks: [Track] = []
    @State private var loading = true
    @State private var extras: [Int: [(label: String, value: String)]] = [:]   // track.id → all extra tag chips

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AlbumCover(key: album.id, sampleURL: album.sampleURL, foundMBID: nil, size: 52, corner: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(album.album).font(.headline)
                    Text("\(album.artist) · \(album.files.count) track(s)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            if loading {
                VStack(spacing: 10) { ProgressView(); Text("Reading tags…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(tracks, id: \.id) { t in trackRow(t) }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 620, height: 560)
        .onAppear(perform: loadTracks)
        .onDisappear { audio.stop() }
    }

    // Mirrors proposalRow: play button + info line + scrubber (when playing) + tags.
    private func trackRow(_ t: Track) -> some View {
        HStack(alignment: .top, spacing: 8) {
            playButton(t.url)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(t.url.lastPathComponent).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(fmtDur(t.duration)) · \(t.formatLabel)")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                if audio.playingURL == t.url { scrubBar }
                tagRow("Artist", t.displayArtist)
                tagRow("Title", t.title)
                tagRow("Album", t.album)
                TagChipsView(pairs: extras[t.id] ?? [])
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func tagRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 42, alignment: .leading)
            Text(value.isEmpty ? "—" : value).font(.caption2)
                .foregroundStyle(value.isEmpty ? .tertiary : .primary).lineLimit(1)
        }
    }

    private func playButton(_ url: URL) -> some View {
        let playing = audio.playingURL == url
        return Button { audio.toggle(url) } label: {
            Image(systemName: playing ? "stop.circle.fill" : "play.circle")
                .font(.system(size: 18)).foregroundStyle(playing ? .red : .teal)
        }.buttonStyle(.plain).help(playing ? "Stop" : "Listen")
    }

    private var scrubBar: some View {
        HStack(spacing: 8) {
            Text(fmtTime(audio.currentTime)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            Slider(value: Binding(get: { audio.progress }, set: { audio.seek(to: $0) }), in: 0...1)
                .controlSize(.mini).tint(.teal)
            Text(fmtTime(audio.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func fmtTime(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    /// Read the album's tracks CONCURRENTLY (bounded) — the network round-trips
    /// overlap instead of running one-by-one, which is what made loading the whole
    /// library over SMB crawl. Only this album's handful of files are read.
    private func loadTracks() {
        guard tracks.isEmpty else { return }
        let urls = album.files
        Task.detached(priority: .userInitiated) {
            var byIndex = [Int: (Track, [(label: String, value: String)])]()
            await withTaskGroup(of: (Int, Track, [(label: String, value: String)]).self) { group in
                let limit = 10
                var next = 0
                func launch() {
                    let i = next; next += 1
                    let u = urls[i]
                    group.addTask {
                        let size = Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                        var t = await readMetadata(url: u, size: size)
                        t.id = i
                        if t.title.isEmpty { t.title = u.deletingPathExtension().lastPathComponent }
                        return (i, t, TagReader.chips(u))
                    }
                }
                for _ in 0..<min(limit, urls.count) { launch() }
                while let (i, t, ex) = await group.next() {
                    byIndex[i] = (t, ex)
                    if next < urls.count { launch() }
                }
            }
            var built: [Track] = []
            var ex: [Int: [(label: String, value: String)]] = [:]
            for i in 0..<urls.count { if let (t, e) = byIndex[i] { built.append(t); ex[i] = e } }
            let sorted = built.sorted {
                ($0.discNo, $0.trackNo, $0.title.lowercased()) < ($1.discNo, $1.trackNo, $1.title.lowercased())
            }
            await MainActor.run { tracks = sorted; extras = ex; loading = false }
        }
    }
}


// MARK: - Runs (across all libraries)

struct RunsView: View {
    @EnvironmentObject private var perfect: PerfectStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.purple)
                Text("Runs").font(.headline)
                Text("\(perfect.runs.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { perfect.loadRuns() } label: { Image(systemName: "arrow.clockwise") }
            }
            .padding(10)
            Divider()
            if perfect.runs.isEmpty {
                Text("No runs yet.\nApply changes in Perfect and they'll show up here — from any library.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(perfect.runs) { run in runRow(run) }.listStyle(.inset)
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .onAppear { perfect.loadRuns() }
    }

    private func runRow(_ run: RunRecord) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Self.df.string(from: run.date)).fontWeight(.medium).monospacedDigit()
                    Text(run.root.lastPathComponent).font(.caption)
                        .foregroundStyle(.purple).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.purple.opacity(0.12)))
                }
                Text(run.summary).font(.caption).foregroundStyle(.secondary)
                Text(breakdown(run)).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Change log") { NSWorkspace.shared.open(run.folder.appendingPathComponent("changelog.txt")) }
                .controlSize(.small)
            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([run.folder]) }
                .controlSize(.small)
            Button(role: .destructive) { perfect.undo(run) } label: { Text("Revert") }
                .controlSize(.small).disabled(perfect.busy)
        }
        .padding(.vertical, 4)
        .help("Library: \(run.root.path)")
    }

    private func breakdown(_ r: RunRecord) -> String {
        var bits: [String] = []
        if !r.ops.isEmpty { bits.append("\(r.ops.count) moves") }
        if !r.tagEdits.isEmpty { bits.append("\(r.tagEdits.count) tags") }
        if !r.perfEdits.isEmpty { bits.append("\(r.perfEdits.count) credits") }
        let art = r.artEdits.count + r.artPromotions.count + r.artReplacements.count
        if art > 0 { bits.append("\(art) artwork") }
        return bits.isEmpty ? "—" : bits.joined(separator: " · ")
    }

    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
}

// MARK: - Logs (structured, per run — a spreadsheet of every change)

private struct LogRow: Identifiable {
    let id = UUID()
    let kind: String
    let file: String
    let detail: String
}

struct LogsView: View {
    @EnvironmentObject private var perfect: PerfectStore
    @State private var selected: String?      // run folder path (RunRecord.id)
    @State private var search = ""

    private var selectedRun: RunRecord? { perfect.runs.first { $0.id == selected } }

    private var rows: [LogRow] {
        guard let r = selectedRun else { return [] }
        var out = Self.logRows(r)
        if !search.isEmpty {
            let q = search.lowercased()
            out = out.filter { $0.file.lowercased().contains(q) || $0.detail.lowercased().contains(q) || $0.kind.lowercased().contains(q) }
        }
        return out
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack { Text("Logs").font(.headline); Spacer()
                    Button { perfect.loadRuns() } label: { Image(systemName: "arrow.clockwise") } }
                    .padding(10)
                Divider()
                if perfect.runs.isEmpty {
                    Text("No runs yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(perfect.runs, selection: $selected) { run in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.df.string(from: run.date)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                            Text(run.root.lastPathComponent).font(.caption2).foregroundStyle(.purple).lineLimit(1)
                            Text(run.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }.tag(run.id)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 240, maxWidth: 320)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if let r = selectedRun {
                        Text("\(rows.count) change(s)").font(.caption).foregroundStyle(.secondary)
                        Text(r.root.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if selectedRun != nil {
                        TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
                        Button("Raw log") {
                            if let r = selectedRun { NSWorkspace.shared.open(r.folder.appendingPathComponent("changelog.txt")) }
                        }.controlSize(.small)
                    }
                }
                .padding(8)
                Divider()
                if selectedRun == nil {
                    Text("Select a run to see its changes.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Table(rows) {
                        TableColumn("Change", value: \.kind).width(120)
                        TableColumn("File", value: \.file)
                        TableColumn("Detail", value: \.detail)
                    }
                }
            }
            .frame(minWidth: 440)
        }
        .frame(minWidth: 760, minHeight: 460)
        .onAppear { perfect.loadRuns(); if selected == nil { selected = perfect.runs.first?.id } }
    }

    /// Flatten a run's recorded changes into spreadsheet rows.
    private static func logRows(_ r: RunRecord) -> [LogRow] {
        var out: [LogRow] = []
        for e in r.ops { out.append(LogRow(kind: "move", file: e.from, detail: "→ \(e.to)")) }
        for e in r.tagEdits {
            out.append(LogRow(kind: "tag: \(e.field)", file: e.rel, detail: e.old.isEmpty ? "set (was blank)" : "was “\(e.old)”"))
        }
        for e in r.perfEdits { out.append(LogRow(kind: "credit", file: e.rel, detail: "+ \(e.name) (\(e.role))")) }
        for rel in r.artEdits { out.append(LogRow(kind: "artwork +", file: rel, detail: "cover added")) }
        for e in r.artReplacements { out.append(LogRow(kind: "artwork ↔", file: e.rel, detail: "cover replaced (backup kept)")) }
        for e in r.artPromotions { out.append(LogRow(kind: "artwork ▲", file: e.rel, detail: "promoted to front cover")) }
        return out
    }

    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
}
// MARK: - Shared tag display (used by both Library and Perfect's Review)

/// Reads every tag we care about off a file, as (label, value) pairs, skipping blanks.
enum TagReader {
    static let fields: [(field: String, label: String)] = [
        ("albumartist", "Album artist"), ("track", "Track"), ("disc", "Disc"),
        ("composer", "Composer"), ("lyricist", "Lyricist"), ("conductor", "Conductor"),
        ("genre", "Genre"), ("date", "Year"), ("label", "Label")
    ]
    /// All non-blank tags for a file. `skipArtist`/etc. let callers drop what they already show.
    static func chips(_ url: URL, exclude: Set<String> = []) -> [(label: String, value: String)] {
        fields.compactMap { f in
            if exclude.contains(f.field) { return nil }
            guard let v = PerfectStore.readField(url, f.field), !v.isEmpty else { return nil }
            return (f.label, v)
        }
    }
}

/// Neutral grey "Label value" chips, wrapping to as many rows as needed.
struct TagChipsView: View {
    let pairs: [(label: String, value: String)]
    var body: some View {
        if !pairs.isEmpty {
            FlowLayout(spacing: 5) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, c in
                    HStack(spacing: 3) {
                        Text(c.label).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                        Text(c.value).font(.system(size: 9)).foregroundStyle(.primary).lineLimit(1)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
            }
            .padding(.top, 1)
        }
    }
}

/// A simple wrapping layout (chips flow to new rows when they run out of width).
struct FlowLayout: Layout {
    var spacing: CGFloat = 5
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW.isFinite ? maxW : x, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
