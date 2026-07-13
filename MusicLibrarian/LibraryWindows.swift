//
//  LibraryWindows.swift
//  MusicLibrarian
//
//  The "Library" menu's three tool windows: Library Viewer (browse the library
//  with tags + the built-in player), Runs (every applied run, revert any), and
//  Logs (each run's change log, list on the left, content on the right).
//

import SwiftUI
import AppKit
import Combine
import MDTagShim

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
        .sheet(item: $selectedAlbum) { a in
            LibraryAlbumSheet(album: a, root: root ?? a.dir.deletingLastPathComponent().deletingLastPathComponent(),
                              onChanged: { load() })
        }
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
                Button { ArtworkCache.shared.clear(); load() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload from disk — use after a Perfect run to see the new tags and artwork")
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

/// Album Inspector — a Roon-style dialog for one album: cover + editable album
/// details, a track table with tags, play by album or track, inline rename, and
/// reversible delete. "Perfect this album" (one-shot per-album cleanup) is wired in
/// a later pass; the button is present but parked.
struct LibraryAlbumSheet: View {
    let album: LibAlbum
    let root: URL
    var onChanged: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: PerfectStore
    @ObservedObject private var audio = AudioPreview.shared
    @ObservedObject private var prog = AudioProgress.shared   // the playhead ticks here; observe it or the bar never moves

    @State private var tracks: [Track] = []
    @State private var loading = true
    @State private var extras: [Int: [(label: String, value: String)]] = [:]
    @State private var artless: Set<Int> = []        // track ids with no embedded cover
    @State private var selectedID: Int?
    @State private var draft: [String: String] = [:] // editable tags for the selected track
    @State private var albumName = ""
    @State private var albumArtist = ""
    @State private var confirmDeleteAlbum = false

    private var selected: Track? { tracks.first { $0.id == selectedID } }
    private var protectedCount: Int { tracks.filter { $0.url.pathExtension.lowercased() == "m4p" }.count }
    private var totalSeconds: Double { tracks.reduce(0) { $0 + $1.duration } }
    private var playItems: [PlayItem] {
        tracks.map { PlayItem(url: $0.url, title: $0.title.isEmpty ? $0.url.lastPathComponent : $0.title,
                              artist: $0.displayArtist.isEmpty ? albumArtist : $0.displayArtist, album: albumName) }
    }
    private func playTrack(_ t: Track) {
        if audio.playingURL == t.url { audio.playPause(); return }
        let items = playItems
        audio.play(items, startAt: items.firstIndex { $0.url == t.url } ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loading {
                VStack(spacing: 10) { ProgressView(); Text("Reading tags…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    trackTable
                    Divider()
                    tagInspector.frame(width: 322)
                }
            }
        }
        .frame(width: 940, height: 640)
        .onAppear { loadTracks() }
        // NB: playback deliberately continues after the dialog closes — the floating
        // player owns transport now; the bar's ✕ is how you stop.
        .alert("Delete this whole album?", isPresented: $confirmDeleteAlbum) {
            Button("Cancel", role: .cancel) {}
            Button("Delete album", role: .destructive) { deleteAlbum() }
        } message: { Text("\(tracks.count) track(s) move to quarantine — reversible from Runs.") }
    }

    // MARK: header
    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            AlbumCover(key: album.id, sampleURL: album.sampleURL, foundMBID: nil, size: 116, corner: 8)
            VStack(alignment: .leading, spacing: 6) {
                TextField("Album", text: $albumName)
                    .textFieldStyle(.plain).font(.system(size: 22, weight: .bold))
                HStack(spacing: 4) {
                    Text("by").foregroundStyle(.secondary)
                    TextField("Album artist", text: $albumArtist).textFieldStyle(.plain).font(.system(size: 14))
                }
                Text(factsLine).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                HStack(spacing: 8) {
                    Button { audio.play(playItems) } label: { Label("Play album", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).tint(.teal).controlSize(.small)
                    Button { audio.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .controlSize(.small).disabled(audio.playingURL == nil)
                    Button { } label: { Label("Perfect this album", systemImage: "wand.and.stars") }
                        .controlSize(.small).disabled(true)
                        .help("Coming next: one-shot identify, artwork, dedup & tidy for this album.")
                    Spacer()
                    if albumDetailsDirty {
                        Button("Save details") { saveAlbumDetails() }.controlSize(.small).tint(.teal)
                    }
                    Button(role: .destructive) { confirmDeleteAlbum = true } label: { Image(systemName: "trash") }
                        .controlSize(.small).help("Delete album")
                    Button("Done") { dismiss() }.controlSize(.small).keyboardShortcut(.defaultAction)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var factsLine: String {
        var bits = ["\(tracks.count) track(s)"]
        if totalSeconds > 0 { bits.append(fmtLong(totalSeconds)) }
        let fmts = Set(tracks.map { $0.formatLabel }); if !fmts.isEmpty { bits.append(fmts.sorted().joined(separator: " / ")) }
        if protectedCount > 0 { bits.append("\(protectedCount) protected") }
        if !artless.isEmpty { bits.append("\(artless.count) need a cover") }
        return bits.joined(separator: " · ")
    }
    private var albumDetailsDirty: Bool { albumName != album.album || albumArtist != album.artist }

    // MARK: track table
    private var trackTable: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(tracks, id: \.id) { t in trackRow(t) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func trackRow(_ t: Track) -> some View {
        let isSel = selectedID == t.id
        let drm = t.url.pathExtension.lowercased() == "m4p"
        let playing = audio.playingURL == t.url
        return HStack(spacing: 10) {
            Text(t.trackNo > 0 ? "\(t.trackNo)" : "–")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)
            Button { if !drm { playTrack(t) } } label: {
                Image(systemName: drm ? "lock.circle" : ((playing && !audio.paused) ? "pause.circle.fill" : "play.circle"))
                    .font(.system(size: 18)).foregroundStyle(drm ? Color.secondary : (playing ? Color.teal : Color.teal))
            }.buttonStyle(.plain).disabled(drm)
            .help(drm ? "Protected (DRM) — can't play" : (playing ? "Pause" : "Play"))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(t.title.isEmpty ? t.url.lastPathComponent : t.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if drm { badge("protected", .secondary) }
                    if artless.contains(t.id) { badge("no cover", .orange) }
                }
                if t.displayArtist.lowercased() != albumArtist.lowercased() && !t.displayArtist.isEmpty {
                    Text(t.displayArtist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(fmtDur(t.duration)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            Text(t.formatLabel).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.25)))
            Button { NSWorkspace.shared.activateFileViewerSelecting([t.url]) } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.plain).foregroundStyle(.tertiary).help("Reveal in Finder")
            Button { deleteTrack(t) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.tertiary).help("Delete track")
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(isSel ? Color.teal.opacity(0.14) : Color.clear)
        .overlay(alignment: .leading) { if isSel { Rectangle().fill(Color.teal).frame(width: 2) } }
        .contentShape(Rectangle())
        .onTapGesture { select(t) }
        if audio.playingURL == t.url { scrubBar.padding(.horizontal, 14).padding(.bottom, 6) }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18))).foregroundStyle(color)
    }

    // MARK: tag inspector
    private var tagInspector: some View {
        Group {
            if let t = selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Track tags").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        VStack(spacing: 1) {
                            tagField("Title", "title")
                            tagField("Artist", "artist")
                            tagField("Album", "album")
                            tagField("Album Artist", "albumartist")
                            HStack(spacing: 1) { tagField("Track", "track"); tagField("Disc", "disc") }
                            HStack(spacing: 1) { tagField("Year", "date"); tagField("Genre", "genre") }
                            tagField("Composer", "composer")
                        }
                        HStack(spacing: 8) {
                            Button("Save tags") { saveTrackTags(t) }
                                .buttonStyle(.borderedProminent).tint(.teal).controlSize(.small)
                                .disabled(!trackDirty(t))
                            Spacer()
                            Text(t.formatLabel).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text(rel(t.url)).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary).textSelection(.enabled)
                        if let ex = extras[t.id], !ex.isEmpty {
                            Divider()
                            Text("Other tags").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).textCase(.uppercase)
                            TagChipsView(pairs: ex)
                        }
                    }
                    .padding(14)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                    Text("Select a track to see and edit its tags").font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
    }

    private func tagField(_ label: String, _ key: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary).textCase(.uppercase)
            TextField(label, text: Binding(get: { draft[key] ?? "" }, set: { draft[key] = $0 }))
                .textFieldStyle(.roundedBorder).controlSize(.small).font(.system(size: 12))
        }
        .padding(6).background(Color.primary.opacity(0.03))
    }

    // MARK: player bits
    private func playButton(_ url: URL) -> some View {
        let playing = audio.playingURL == url
        let drm = url.pathExtension.lowercased() == "m4p"
        return Button { if !drm { audio.toggle(url) } } label: {
            Image(systemName: drm ? "lock.circle" : (playing ? "stop.circle.fill" : "play.circle"))
                .font(.system(size: 18)).foregroundStyle(drm ? Color.secondary : (playing ? Color.red : Color.teal))
        }.buttonStyle(.plain).disabled(drm)
        .help(drm ? "Protected (DRM) — this file can't be played or re-encoded" : (playing ? "Stop" : "Listen"))
    }

    private var scrubBar: some View {
        HStack(spacing: 8) {
            Text(fmtTime(prog.progress * audio.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            Slider(value: Binding(get: { prog.progress }, set: { audio.seek(to: $0) }), in: 0...1)
                .controlSize(.mini).tint(.teal)
            Text(fmtTime(audio.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private func fmtTime(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
    private func fmtLong(_ s: Double) -> String {
        let t = Int(s); let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    // MARK: selection + edits
    private func select(_ t: Track) {
        selectedID = t.id
        draft = ["title": t.title, "artist": t.artist, "album": t.album, "albumartist": t.albumArtist,
                 "track": t.trackNo > 0 ? String(t.trackNo) : "", "disc": t.discNo > 0 ? String(t.discNo) : "",
                 "date": readTag(t.url, "date"), "genre": readTag(t.url, "genre"), "composer": readTag(t.url, "composer")]
    }
    private func readTag(_ u: URL, _ f: String) -> String { PerfectStore.readField(u, f) ?? "" }

    private func trackDirty(_ t: Track) -> Bool {
        let cur = ["title": t.title, "artist": t.artist, "album": t.album, "albumartist": t.albumArtist,
                   "track": t.trackNo > 0 ? String(t.trackNo) : "", "disc": t.discNo > 0 ? String(t.discNo) : "",
                   "date": readTag(t.url, "date"), "genre": readTag(t.url, "genre"), "composer": readTag(t.url, "composer")]
        return draft.contains { cur[$0.key] ?? "" != $0.value }
    }

    private func saveTrackTags(_ t: Track) {
        var writes: [(rel: String, field: String, value: String)] = []
        for (k, v) in draft where (readTag(t.url, k) != v) { writes.append((rel(t.url), k, v)) }
        guard !writes.isEmpty else { return }
        store.applyLibraryRun(root: root, summary: "Edited tags — \(t.title)", tagWrites: writes) {
            reloadPreservingSelection()
        }
    }

    private func saveAlbumDetails() {
        var writes: [(rel: String, field: String, value: String)] = []
        for t in tracks {
            if albumName != album.album { writes.append((rel(t.url), "album", albumName)) }
            if albumArtist != album.artist { writes.append((rel(t.url), "albumartist", albumArtist)) }
        }
        // rename the album folder too so the library tree matches
        var moves: [(from: String, to: String)] = []
        if albumName != album.album {
            let parent = (rel(album.dir) as NSString).deletingLastPathComponent
            let newRel = parent.isEmpty ? sanitizeName(albumName) : parent + "/" + sanitizeName(albumName)
            moves.append((rel(album.dir), newRel))
        }
        guard !writes.isEmpty || !moves.isEmpty else { return }
        store.applyLibraryRun(root: root, summary: "Renamed album — \(albumName)", tagWrites: writes, moves: moves) {
            onChanged(); dismiss()
        }
    }

    private func deleteTrack(_ t: Track) {
        if audio.playingURL == t.url { audio.stop() }
        store.applyLibraryRun(root: root, summary: "Deleted track — \(t.title)", moves: [(rel(t.url), "")]) {
            tracks.removeAll { $0.id == t.id }
            if selectedID == t.id { selectedID = nil }
            onChanged()
        }
    }

    private func deleteAlbum() {
        audio.stop()
        store.applyLibraryRun(root: root, summary: "Deleted album — \(album.album)", moves: [(rel(album.dir), "")]) {
            onChanged(); dismiss()
        }
    }

    private func rel(_ url: URL) -> String {
        let rp = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(rp) ? String(url.path.dropFirst(rp.count)) : url.lastPathComponent
    }

    private func reloadPreservingSelection() {
        let keep = selectedID
        tracks = []; loading = true; artless = []
        loadTracks { if let k = keep, let t = tracks.first(where: { $0.id == k }) { select(t) } }
    }

    /// Read the album's tracks CONCURRENTLY (bounded). Also notes which have no cover.
    private func loadTracks(_ done: (() -> Void)? = nil) {
        let urls = album.files
        Task.detached(priority: .userInitiated) {
            var byIndex = [Int: (Track, [(label: String, value: String)], Bool)]()
            await withTaskGroup(of: (Int, Track, [(label: String, value: String)], Bool).self) { group in
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
                        let hasArt = md_has_artwork(u.path) != 0
                        return (i, t, TagReader.chips(u), hasArt)
                    }
                }
                for _ in 0..<min(limit, urls.count) { launch() }
                while let (i, t, ex, hasArt) = await group.next() {
                    byIndex[i] = (t, ex, hasArt)
                    if next < urls.count { launch() }
                }
            }
            var built: [Track] = []
            var ex: [Int: [(label: String, value: String)]] = [:]
            var noArt = Set<Int>()
            for i in 0..<urls.count { if let (t, e, hasArt) = byIndex[i] { built.append(t); ex[i] = e; if !hasArt { noArt.insert(i) } } }
            // number-less tracks sort to the BOTTOM, not the top (a missing track number
            // shouldn't jump a track above track 1) — like Apple Music.
            let sorted = built.sorted {
                let a = ($0.discNo == 0 ? Int.max : $0.discNo, $0.trackNo == 0 ? Int.max : $0.trackNo, $0.title.lowercased())
                let b = ($1.discNo == 0 ? Int.max : $1.discNo, $1.trackNo == 0 ? Int.max : $1.trackNo, $1.title.lowercased())
                return a < b
            }
            await MainActor.run {
                tracks = sorted; extras = ex; artless = noArt; loading = false
                if albumName.isEmpty { albumName = album.album }; if albumArtist.isEmpty { albumArtist = album.artist }
                done?()
            }
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


// MARK: - Floating global player (Apple-Music-style transport bar)

/// A floating transport that owns playback across the whole app. It stays above the
/// windows and keeps playing even when the album dialog that started a track closes.
struct PlayerBar: View {
    @ObservedObject private var audio = AudioPreview.shared
    @ObservedObject private var prog = AudioProgress.shared
    @State private var art: NSImage?

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 14) {
                iconBtn("shuffle", size: 13, active: audio.shuffle) { audio.toggleShuffle() }
                iconBtn("backward.fill", size: 15) { audio.prev() }
                Button { audio.playPause() } label: {
                    Image(systemName: audio.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 21)).frame(width: 26)
                }.buttonStyle(.plain)
                iconBtn("forward.fill", size: 15) { audio.next() }
                iconBtn(audio.repeatMode == .one ? "repeat.1" : "repeat", size: 13,
                        active: audio.repeatMode != .off) { audio.cycleRepeat() }
            }
            .foregroundStyle(.primary)

            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.2))
                if let a = art { Image(nsImage: a).resizable().aspectRatio(contentMode: .fill) }
                else { Image(systemName: "music.note").foregroundStyle(.secondary) }
            }
            .frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 2) {
                Text(audio.current?.title ?? "—").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(infoLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                scrubber.padding(.top, 1)
            }
            .frame(minWidth: 200, alignment: .leading)

            SpectrumView().frame(width: 132, height: 44)

            HStack(spacing: 7) {
                Image(systemName: "speaker.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(audio.volume) }, set: { audio.volume = Float($0) }), in: 0...1)
                    .frame(width: 68).controlSize(.mini).tint(.secondary)
                Button { audio.stop() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Stop and hide the player")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .frame(width: 786, height: 76)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.10)))
        .task(id: audio.current?.url) { await loadArt(audio.current?.url) }
    }

    private var infoLine: String {
        guard let c = audio.current else { return "" }
        let who = c.artist.isEmpty ? c.album : (c.album.isEmpty ? c.artist : "\(c.artist) — \(c.album)")
        return who
    }

    private var scrubber: some View {
        HStack(spacing: 7) {
            Text(fmt(prog.progress * audio.duration)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
            Slider(value: Binding(get: { prog.progress }, set: { audio.seek(to: $0) }), in: 0...1).controlSize(.mini).tint(.teal)
            Text(fmt(audio.duration)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
        }
    }

    private func iconBtn(_ name: String, size: CGFloat, active: Bool = false, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: name).font(.system(size: size, weight: .medium))
                .foregroundStyle(active ? Color.teal : Color.primary)
        }.buttonStyle(.plain)
    }

    private func fmt(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    private func loadArt(_ url: URL?) async {
        guard let url else { await MainActor.run { art = nil }; return }
        let img: NSImage? = await Task.detached { () -> NSImage? in
            var len: Int32 = 0, ty: Int32 = 0
            guard let b = md_copy_artwork(url.path, &len, &ty), len > 0 else { return nil }
            let d = Data(bytes: b, count: Int(len)); free(b)
            return NSImage(data: d)
        }.value
        await MainActor.run { art = img }
    }
}

/// Frequency spectrum bars for the player, driven by SpectrumAnalyzer (FFT of the
/// playing file at the playhead). Drawn with Canvas so 30fps updates stay cheap.
struct SpectrumView: View {
    @ObservedObject private var an = SpectrumAnalyzer.shared
    var body: some View {
        Canvas { ctx, size in
            let bands = an.bands
            let n = bands.count
            guard n > 0 else { return }
            let gap: CGFloat = 2
            let bw = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
            for i in 0..<n {
                let h = max(2, CGFloat(bands[i]) * size.height)
                let x = CGFloat(i) * (bw + gap)
                let rect = CGRect(x: x, y: size.height - h, width: bw, height: h)
                // low freqs teal → highs a lighter tint, brighter as they peak
                let t = Double(i) / Double(max(1, n - 1))
                let color = Color(hue: 0.47 - 0.08 * t, saturation: 0.55, brightness: 0.7 + 0.3 * Double(bands[i]))
                ctx.fill(Path(roundedRect: rect, cornerRadius: min(bw / 2, 2)), with: .color(color))
            }
        }
        .drawingGroup()
    }
}

/// Owns the floating panel: shows it whenever something is playing, hides it on stop.
@MainActor
final class PlayerBarController {
    static let shared = PlayerBarController()
    private var panel: NSPanel?
    private var cancellable: AnyCancellable?

    func start() {
        cancellable = AudioPreview.shared.$playingURL
            .receive(on: RunLoop.main)
            .sink { [weak self] url in url != nil ? self?.show() : self?.hide() }
    }

    private func show() {
        if panel == nil { panel = makePanel() }
        guard let p = panel else { return }
        position(p)
        p.orderFrontRegardless()
        p.makeKeyAndOrderFront(nil)
    }
    private func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 786, height: 76),
                        styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.isMovableByWindowBackground = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .moveToActiveSpace]
        p.contentView = NSHostingView(rootView: PlayerBar())
        return p
    }

    private func position(_ p: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        p.setFrameOrigin(NSPoint(x: vf.midX - p.frame.width / 2, y: vf.minY + 26))
    }
}
