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
    @State private var showMerge = false
    @State private var scrollTarget: String?   // album id to scroll back to after a reload
    @State private var lastAlbumID: String?    // the album most recently opened

    /// Album folders that are the SAME release by the SAME artist — a "(Disc 2)"
    /// split, or a differently-marked edition — so they can be merged into one.
    /// Grouped by artist + canonical album key (disc suffix + edition markers removed).
    private var mergeGroups: [[LibAlbum]] {
        var byKey: [String: [LibAlbum]] = [:]
        for a in albums {
            let key = normText(a.artist) + "\u{0}" + Organiser.canonicalAlbumKey(a.album)
            byKey[key, default: []].append(a)
        }
        return byKey.values.filter { $0.count >= 2 }
            .map { $0.sorted { $0.album.localizedStandardCompare($1.album) == .orderedAscending } }
            .sorted { ($0.first?.artist ?? "") < ($1.first?.artist ?? "") }
    }

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
                              onChanged: { scrollTarget = lastAlbumID; load() })
        }
        .sheet(isPresented: $showMerge) {
            MergeAlbumsSheet(groups: mergeGroups, root: root ?? URL(fileURLWithPath: savedRoot),
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

    private var mergeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.down.right").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(mergeGroups.count) set\(mergeGroups.count == 1 ? "" : "s") of albums look like the same release")
                    .fontWeight(.medium)
                Text("A “(Disc 2)” folder or a differently-named edition split from its album — review and merge them into one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Review & merge…") { showMerge = true }
                .buttonStyle(.borderedProminent).tint(.orange).controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
    }

    private var albumGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !mergeGroups.isEmpty { mergeBanner }
                    HStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2").foregroundStyle(.purple)
                        Text("\(filtered.count) album(s)").fontWeight(.semibold)
                        Text("click an album to see its tracks").font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 176, maximum: 210), spacing: 18)],
                              alignment: .leading, spacing: 18) {
                        ForEach(filtered) { a in albumCard(a).id(a.id) }
                    }
                }
                .padding(16)
            }
            // After a reload (e.g. closing an album post-Perfect), scroll back to the
            // album that was open once it reappears in the freshly-loaded grid.
            .onChange(of: albums.count) { _ in
                guard let id = scrollTarget, albums.contains(where: { $0.id == id }) else { return }
                scrollTarget = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func albumCard(_ a: LibAlbum) -> some View {
        Button { lastAlbumID = a.id; selectedAlbum = a } label: {
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

/// Merge folders that are the same release (a "(Disc 2)" split, or a differently
/// named edition) into one album — reversibly. The extra folders' files move into the
/// main folder, every track is retagged to the clean album name with the right disc
/// number, and it all lands in one undoable run (Runs).
struct MergeAlbumsSheet: View {
    let groups: [[LibAlbum]]
    let root: URL
    var onChanged: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: PerfectStore
    // Keyed by the primary folder's path (stable), NOT the positional index — `groups`
    // shrinks after each merge, so an Int key would mark the wrong row afterwards.
    @State private var merged = Set<String>()
    @State private var working: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.down.right").foregroundStyle(.orange)
                Text("Merge albums").font(.headline)
                Text("Fold split disc/edition folders back into one album — reversible from Runs.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(14)
            Divider()
            if groups.isEmpty {
                Text("Nothing to merge.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { VStack(spacing: 0) { ForEach(groups.indices, id: \.self) { i in groupRow(i) } } }
            }
            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(width: 620, height: 520)
    }

    private func groupRow(_ i: Int) -> some View {
        let g = groups[i]
        let clean = Organiser.canonicalAlbumDisplay(g.map { $0.album })
        let primary = primaryOf(g)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AlbumCover(key: primary.id, sampleURL: primary.sampleURL, foundMBID: nil, size: 44, corner: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(clean).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(g.first?.artist ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if merged.contains(primary.id) {
                    Label("Merged", systemImage: "checkmark.circle.fill").foregroundStyle(.teal).font(.callout)
                } else if working == primary.id {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Merge") { merge(i) }.buttonStyle(.borderedProminent).tint(.orange).controlSize(.small)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(g, id: \.id) { a in
                    HStack(spacing: 6) {
                        Image(systemName: a.id == primary.id ? "folder.fill" : "folder")
                            .font(.system(size: 10)).foregroundStyle(a.id == primary.id ? Color.orange : Color.secondary)
                        Text(a.album).font(.system(size: 12)).lineLimit(1)
                        Text("· \(a.files.count) track\(a.files.count == 1 ? "" : "s") · disc \(discOf(a))\(a.id == primary.id ? " · main folder" : "")")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }.padding(.leading, 54)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func discOf(_ a: LibAlbum) -> Int { Organiser.stripDiscSuffix(a.album).disc ?? 1 }

    /// The folder that keeps its place: lowest disc number, then most tracks.
    private func primaryOf(_ g: [LibAlbum]) -> LibAlbum {
        g.sorted { a, b in
            let da = discOf(a), db = discOf(b)
            if da != db { return da < db }
            return a.files.count > b.files.count
        }.first!
    }

    private func rel(_ u: URL) -> String {
        let rp = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return u.path.hasPrefix(rp) ? String(u.path.dropFirst(rp.count)) : u.lastPathComponent
    }

    private func merge(_ i: Int) {
        let g = groups[i]
        let clean = Organiser.canonicalAlbumDisplay(g.map { $0.album })
        let primary = primaryOf(g)
        var tagWrites: [(rel: String, field: String, value: String)] = []
        var moves: [(from: String, to: String)] = []
        for a in g {
            let disc = discOf(a)
            for f in a.files {
                tagWrites.append((rel(f), "album", clean))       // consistent album name
                tagWrites.append((rel(f), "disc", String(disc))) // so tracks sort by disc
                if a.id != primary.id {
                    // disc-prefix the moved file so it can't collide with a same-numbered
                    // track already in the main folder
                    moves.append((rel(f), rel(primary.dir) + "/\(disc)-\(f.lastPathComponent)"))
                }
            }
        }
        working = primary.id
        store.applyLibraryRun(root: root, summary: "Merged album — \(clean)",
                              tagWrites: tagWrites, moves: moves) {
            working = nil; merged.insert(primary.id); onChanged()
        }
    }
}

/// Remembers the MusicBrainz tracklist a "Perfect this album" run matched, so the
/// inspector can keep showing which tracks are missing after the dialog closes. Kept
/// in Application Support keyed by the album folder path (the files themselves have
/// nothing to write for a track that isn't there), so the music folder stays clean.
enum AlbumReconcileStore {
    private static func hash(_ s: String) -> String {
        var h: UInt64 = 5381; for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }; return String(h, radix: 16)
    }
    private static func file(_ folderPath: String) -> URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("Music Librarian/album-tracklists", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(hash(folderPath)).json")
    }
    static func save(_ folderPath: String, _ match: MBReleaseMatch) {
        guard let u = file(folderPath), let d = try? JSONEncoder().encode(match) else { return }
        try? d.write(to: u)
    }
    static func load(_ folderPath: String) -> MBReleaseMatch? {
        guard let u = file(folderPath), let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(MBReleaseMatch.self, from: d)
    }
    static func clear(_ folderPath: String) { if let u = file(folderPath) { try? FileManager.default.removeItem(at: u) } }
}

/// One row in the inspector's track list: a track we have (playable/editable) or a
/// greyed placeholder for a track the album should contain but is missing.
private enum InspectorRow: Identifiable {
    // slotTrack > 0 = the release's track number to show (the rows are ordered by the
    // release, so a flattened set's wrong on-disk numbers would read scrambled); 0 = show
    // the file's own number (an extra track, or the non-reconciled view).
    case have(Track, slotTrack: Int)
    case missing(id: String, disc: Int, track: Int, title: String, lengthMs: Int?)
    var id: String {
        switch self {
        case .have(let t, _): return "h\(t.id)"
        case .missing(let id, _, _, _, _): return "m\(id)"
        }
    }
}

/// Album Inspector — a Roon-style dialog for one album: cover + editable album
/// details, a track table with tags, play by album or track, inline rename, and
/// reversible delete. Multi-disc albums group under "Disc N" headers, and "Check for
/// missing tracks" reconciles against MusicBrainz to grey out what's absent.
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
    @State private var showPerfect = false
    @State private var expected: MBReleaseMatch?   // MusicBrainz tracklist, loaded from the Perfect run's saved result
    @State private var reconcileNote: String?

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
            if audio.playingURL != nil {
                Divider()
                PlayerBar()
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
        // Perfect this album — after a successful reversible Apply, close the inspector
        // (files/tags/names may all have changed) and let the browser reload.
        .sheet(isPresented: $showPerfect) {
            PerfectAlbumSheet(album: album, root: root, onApplied: { onChanged(); dismiss() })
                .environmentObject(store)
        }
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
                    Button { showPerfect = true } label: { Label("Perfect this album", systemImage: "wand.and.stars") }
                        .controlSize(.small).tint(.purple)
                        .help("One-shot cleanup for this album: consistent tags, unified cover art, remove duplicates, tidy file names.")
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
        // just the distinct container formats (MP3, FLAC…), not every per-track bitrate
        let fmts = Set(tracks.map { $0.ext.uppercased() }).sorted()
        if !fmts.isEmpty { bits.append(fmts.joined(separator: " / ")) }
        if protectedCount > 0 { bits.append("\(protectedCount) protected") }
        if !artless.isEmpty { bits.append("\(artless.count) need a cover") }
        return bits.joined(separator: " · ")
    }
    private var albumDetailsDirty: Bool { albumName != album.album || albumArtist != album.artist }

    // MARK: track table
    private var trackTable: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let note = reconcileNote { reconcileBanner(note) }
                ForEach(discSections, id: \.disc) { section in
                    if showDiscHeaders { discHeader(section.disc, have: section.have, total: section.total) }
                    ForEach(section.rows) { row in
                        switch row {
                        case .have(let t, let slotTrack): trackRow(t, slotTrack: slotTrack)
                        case .missing(_, let disc, let track, let title, let ms):
                            missingRow(disc: disc, track: track, title: title, lengthMs: ms)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// True when the album spans more than one disc — either from the tracks' own disc
    /// tags, or from a reconciled multi-disc release.
    private var showDiscHeaders: Bool {
        if let e = expected { return e.discCount > 1 }
        return Set(tracks.map { $0.discNo }).subtracting([0]).count > 1 || tracks.contains { $0.discNo > 1 }
    }

    /// Tracks grouped by disc. Once reconciled, the full MusicBrainz tracklist drives
    /// it — every slot is either a track we have or a greyed "missing" placeholder.
    private var discSections: [(disc: Int, rows: [InspectorRow], have: Int, total: Int)] {
        if let e = expected {
            // Match a slot to an on-disk track by TITLE, not by track number. Across
            // editions/pressings the numbering doesn't line up (and a multi-disc Discogs
            // release numbers each disc from 1), so a position match would steal the wrong
            // track and show songs you have as "missing". Title is the reliable key for
            // "do I have this track?".
            let byTitle = Dictionary(tracks.map { (TrackProposal.typoFold($0.title).lowercased(), $0) },
                                     uniquingKeysWith: { a, _ in a })
            var used = Set<Int>()
            var byDisc: [Int: [InspectorRow]] = [:]
            for slot in e.tracks.sorted(by: { ($0.disc, $0.track) < ($1.disc, $1.track) }) {
                let key = TrackProposal.typoFold(slot.title).lowercased()
                if let t = byTitle[key], !used.contains(t.id) {
                    // Show the RELEASE's track number (rows are in release order); the file's
                    // own number is meaningless for a flattened multi-disc set.
                    used.insert(t.id); byDisc[slot.disc, default: []].append(.have(t, slotTrack: slot.track))
                } else {
                    byDisc[slot.disc, default: []].append(.missing(id: "\(slot.disc)-\(slot.track)-\(key)",
                                                                   disc: slot.disc, track: slot.track,
                                                                   title: slot.title, lengthMs: slot.lengthMs))
                }
            }
            // On-disk tracks the matched release doesn't list (bonus/hidden/edition extras)
            // must still appear so they can be played, renamed, tagged or deleted here —
            // the release match only needs 60% title overlap, so up to 40% can be extras.
            for t in tracks where !used.contains(t.id) {
                byDisc[t.discNo == 0 ? 1 : t.discNo, default: []].append(.have(t, slotTrack: 0))
            }
            return byDisc.keys.sorted().map { d in
                let rows = byDisc[d]!
                let have = rows.reduce(0) { if case .have = $1 { return $0 + 1 }; return $0 }
                return (d, rows, have, rows.count)
            }
        } else {
            var byDisc: [Int: [InspectorRow]] = [:]
            for t in tracks { byDisc[t.discNo == 0 ? 1 : t.discNo, default: []].append(.have(t, slotTrack: 0)) }
            return byDisc.keys.sorted().map { d -> (disc: Int, rows: [InspectorRow], have: Int, total: Int) in
                let rows = byDisc[d]!; return (d, rows, rows.count, rows.count)
            }
        }
    }

    private func discHeader(_ disc: Int, have: Int, total: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "opticaldisc").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Disc \(disc)").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).textCase(.uppercase)
            if expected != nil {
                Text("\(have) of \(total)").font(.system(size: 11)).foregroundStyle(have < total ? Color.orange : Color.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 5)
    }

    private func missingRow(disc: Int, track: Int, title: String, lengthMs: Int?) -> some View {
        HStack(spacing: 10) {
            Text("\(track)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)
            Image(systemName: "circle.dotted").font(.system(size: 18)).foregroundStyle(.tertiary)
            Text(title.isEmpty ? "Unknown" : title).font(.system(size: 13)).italic().foregroundStyle(.tertiary).lineLimit(1)
            badge("missing", .orange)
            Spacer()
            if let ms = lengthMs {
                Text(fmtDur(Double(ms) / 1000)).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary).frame(width: 46, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7).opacity(0.8)
    }

    private func reconcileBanner(_ note: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: expected != nil ? "checkmark.seal.fill" : "questionmark.circle")
                .foregroundStyle(expected != nil ? Color.teal : Color.orange)
            Text(note).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { expected = nil; reconcileNote = nil; AlbumReconcileStore.clear(album.id) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }.buttonStyle(.plain).help("Stop tracking missing tracks for this album")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06))
    }

    /// Load the tracklist a Perfect run matched + saved for this album, so the missing
    /// tracks keep showing after the dialog is reopened. No network here.
    private func loadReconcile() {
        guard let m = AlbumReconcileStore.load(album.id) else { expected = nil; reconcileNote = nil; return }
        expected = m
        let have = Set(tracks.map { TrackProposal.typoFold($0.title).lowercased() })
        let missing = m.tracks.filter { !have.contains(TrackProposal.typoFold($0.title).lowercased()) }.count
        let yr = m.date.flatMap { $0.isEmpty ? nil : " (\($0.prefix(4)))" } ?? ""
        reconcileNote = missing > 0
            ? "Missing \(missing) of \(m.tracks.count) tracks from “\(m.title)”\(yr)"
            : "All \(m.tracks.count) tracks present — “\(m.title)”\(yr)"
    }

    private func trackRow(_ t: Track, slotTrack: Int = 0) -> some View {
        let isSel = selectedID == t.id
        let drm = t.url.pathExtension.lowercased() == "m4p"
        let playing = audio.playingURL == t.url
        let number = slotTrack > 0 ? slotTrack : t.trackNo   // release position when reconciled
        return HStack(spacing: 10) {
            Text(number > 0 ? "\(number)" : "–")
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
                .frame(width: 46, alignment: .trailing)
            Text(t.formatLabel).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                .frame(width: 68, alignment: .center)
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
                loadReconcile()   // show missing tracks a Perfect run found + saved
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
        .padding(.horizontal, 18).padding(.vertical, 10)
        .frame(height: 76).frame(maxWidth: 820)
        .background(.ultraThinMaterial)
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

    private var manual = false   // forced visible via the menu, ignores playback state

    func start() {
        cancellable = AudioPreview.shared.$playingURL
            .receive(on: RunLoop.main)
            .sink { [weak self] url in
                guard let self else { return }
                if url != nil { self.show() } else if !self.manual { self.hide() }
            }
    }

    /// Menu command: force the bar visible (or hide it) regardless of playback, so we
    /// can tell a panel-display problem apart from a playback-wiring one.
    func toggleManual() {
        manual.toggle()
        if manual { show() } else if AudioPreview.shared.playingURL == nil { hide() }
    }

    private func show() {
        if panel == nil { panel = makePanel() }
        guard let p = panel else { return }
        position(p)
        p.orderFrontRegardless()
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


// MARK: - Perfect this album (offline, album-scoped, one reversible Apply)

/// One proposed fix in the album checklist. The payloads feed straight into
/// `PerfectStore.applyLibraryRun` (tag writes + moves + artwork), so applying the
/// whole checklist is a single reversible run that shows up in the Runs window.
struct AlbumFix: Identifiable {
    enum Kind: String {
        case identify = "Identify"
        case album = "Album name"
        case albumArtist = "Album artist"
        case artistCredit = "Artist credits"
        case compilation = "Compilation"
        case discOrder = "Disc order"
        case credits = "Credits"
        case artwork = "Cover art"
        case duplicate = "Duplicates"
        case filename = "File names"
        case missing = "Missing tracks"
        case damaged = "Possibly damaged"
    }
    let id = UUID()
    let kind: Kind
    let summary: String                  // one-line headline
    var lines: [String] = []             // per-item detail
    var enabled: Bool                    // checklist toggle
    let applyable: Bool                  // false = information only (e.g. damaged)
    var tagWrites: [(rel: String, field: String, value: String)] = []
    var moves: [(from: String, to: String)] = []
    var artEmbeds: [(rel: String, image: Data, mime: String)] = []
    var performerAdds: [(rel: String, name: String, role: String)] = []

    var systemImage: String {
        switch kind {
        case .identify: return "waveform"
        case .album: return "textformat"
        case .albumArtist: return "person.2"
        case .artistCredit: return "person.text.rectangle"
        case .compilation: return "person.3.sequence"
        case .discOrder: return "opticaldisc"
        case .credits: return "music.mic"
        case .artwork: return "photo"
        case .duplicate: return "doc.on.doc"
        case .filename: return "character.cursor.ibeam"
        case .missing: return "circle.dotted"
        case .damaged: return "exclamationmark.triangle"
        }
    }
    var changeCount: Int { tagWrites.count + moves.count + artEmbeds.count + performerAdds.count }
}

/// Cover-art context for the interactive chooser in the sheet: each kept track's
/// current cover fingerprint, the album's distinct embedded covers (best first), and
/// the artist/album used to look up more covers online.
struct AlbumArtContext {
    var artist: String
    var album: String
    var rels: [String]                                // all kept-track rels, in order
    var relArt: [String: (pixels: Int, bytes: Int)]   // current cover per rel (absent = none)
    var ownCovers: [Data]                             // distinct embedded covers, highest-res first
}

/// The album-scoped analysis behind "Perfect this album". It reuses the full Perfect
/// wizard's own pieces scoped to one folder — the AcoustID→MusicBrainz identifier, the
/// duplicate clustering, the canonical-album helpers and the cover-art client — so the
/// result matches what the wizard would do to the same album.
enum AlbumPerfect {

    /// A proposed name is worth writing when it's non-empty and either the current
    /// value is a placeholder/junk (fill it) or genuinely differs (ignoring case,
    /// punctuation and "the" — the same fold the wizard uses so cosmetic noise is quiet).
    private static func nameChanged(_ old: String, _ new: String) -> Bool {
        let n = new.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return false }
        if Identifier.isJunkValue(old) { return true }
        return normText(old) != normText(n)
    }

    private static func artInfo(_ url: URL) -> (data: Data, pixels: Int, mime: String)? {
        var len: Int32 = 0, ty: Int32 = 0
        guard let buf = md_copy_artwork(url.path, &len, &ty), len > 0 else { return nil }
        let d = Data(bytes: buf, count: Int(len)); free(buf)
        let mime = d.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
        let pixels = NSBitmapImageRep(data: d).map { $0.pixelsWide * $0.pixelsHigh } ?? 0
        return (d, pixels, mime)
    }

    static func analyze(root: URL, files: [URL], alreadyReconciled: Bool = false) async -> (fixes: [AlbumFix], art: AlbumArtContext, reconcile: MBReleaseMatch?) {
        // Read every track's tags (bounded concurrency, same as the inspector).
        var tracks = [Track](repeating: Track(id: 0, url: root, name: "", relDir: "", size: 0, ext: "",
                                              title: "", artist: "", album: "", albumArtist: "",
                                              trackNo: 0, discNo: 0, duration: 0, lossless: false,
                                              bitrate: 0, codec: ""), count: files.count)
        await withTaskGroup(of: (Int, Track).self) { group in
            let limit = 8; var next = 0
            func launch() {
                let i = next; next += 1; let u = files[i]
                group.addTask {
                    let size = Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    var t = await readMetadata(url: u, size: size); t.id = i
                    if t.title.isEmpty { t.title = u.deletingPathExtension().lastPathComponent }
                    return (i, t)
                }
            }
            for _ in 0..<min(limit, files.count) { launch() }
            while let (i, t) = await group.next() { tracks[i] = t; if next < files.count { launch() } }
        }

        let rp = root.path.hasSuffix("/") ? root.path : root.path + "/"
        func rel(_ u: URL) -> String { u.path.hasPrefix(rp) ? String(u.path.dropFirst(rp.count)) : u.lastPathComponent }

        var fixes: [AlbumFix] = []

        // ---- 1. Identify by sound — the SAME AcoustID→MusicBrainz pipeline the wizard
        // uses (Identifier.fingerprint → .resolve), scoped to this album. The corrected
        // names update the in-memory tracks so the dedup/consensus/tidy below see them,
        // exactly like the wizard's Identify → Duplicates → Organise order. Skipped with
        // no AcoustID key (Settings ⌘,) — the offline fixes still run.
        var idWrites: [(rel: String, field: String, value: String)] = []
        var idLines: [String] = []
        var recIDByRel: [String: String] = [:]   // rel → MusicBrainz recording id (for credit enrichment)
        var seedRecID: String?
        let acoustIDKey = Identifier.configuredKey
        if !acoustIDKey.isEmpty {
            let ident = Identifier(apiKey: acoustIDKey)
            for i in tracks.indices {
                let t = tracks[i]
                if t.url.pathExtension.lowercased() == "m4p" { continue }   // DRM: can't decode/fingerprint
                guard let fp = ident.fingerprint(t.url) else { continue }
                let hasArt = md_has_artwork(t.url.path) == 1
                let comp = PerfectStore.readField(t.url, "composer") ?? ""
                let label = PerfectStore.readField(t.url, "label") ?? ""
                guard let p = try? await ident.resolve(url: t.url, relPath: rel(t.url), fingerprint: fp,
                                                       curArtist: t.artist, curTitle: t.title, curAlbum: t.album,
                                                       curHasArt: hasArt, curComposer: comp, curLabel: label) else { continue }
                if let rid = p.recordingID, !rid.isEmpty { recIDByRel[rel(t.url)] = rid; if seedRecID == nil { seedRecID = rid } }
                if nameChanged(t.title, p.newTitle) {
                    idWrites.append((rel(t.url), "title", p.newTitle))
                    idLines.append("“\(t.title.isEmpty ? t.url.lastPathComponent : t.title)” → “\(p.newTitle)”")
                    tracks[i].title = p.newTitle
                }
                if nameChanged(t.artist, p.newArtist) {
                    idWrites.append((rel(t.url), "artist", p.newArtist))
                    idLines.append("artist: \(t.artist.isEmpty ? "—" : t.artist) → \(p.newArtist)")
                    tracks[i].artist = p.newArtist
                }
            }
        }

        // ---- 2. Duplicates (on the identified names), so removed files are excluded below.
        var clTracks = tracks
        let clusters = buildClusters(&clTracks, mode: .balanced, tol: 2.0, crossAlbum: false)
        var removed = Set<String>()
        var dupMoves: [(from: String, to: String)] = []
        var dupLines: [String] = []
        for c in clusters where c.memberIDs.count > 1 {
            let keeper = tracks[c.keeperID]
            for id in c.memberIDs where id != c.keeperID {
                let t = tracks[id]
                dupMoves.append((rel(t.url), ""))
                removed.insert(rel(t.url))
                dupLines.append("remove “\(t.url.lastPathComponent)” — keeping “\(keeper.url.lastPathComponent)”")
            }
        }

        // Identify fix goes first in the checklist; drop any writes to files we're
        // about to remove as duplicates (no point retagging a file headed to quarantine).
        let liveIdWrites = idWrites.filter { !removed.contains($0.rel) }
        if !liveIdWrites.isEmpty {
            let n = Set(liveIdWrites.map { $0.rel }).count
            fixes.append(AlbumFix(kind: .identify, summary: "Identify \(n) track\(n == 1 ? "" : "s") by sound (AcoustID)",
                                  lines: idLines, enabled: true, applyable: true, tagWrites: liveIdWrites))
        }
        if !dupMoves.isEmpty {
            fixes.append(AlbumFix(kind: .duplicate,
                                  summary: "Remove \(dupMoves.count) duplicate track\(dupMoves.count == 1 ? "" : "s") (best copy kept)",
                                  lines: dupLines, enabled: true, applyable: true, moves: dupMoves))
        }

        let fallbackAlbum = files.first?.deletingLastPathComponent().lastPathComponent ?? ""
        let kept = tracks.filter { !removed.contains(rel($0.url)) }
        guard !kept.isEmpty else {
            return (fixes, AlbumArtContext(artist: "", album: fallbackAlbum, rels: [], relArt: [:], ownCovers: []), nil)
        }

        // ---- 2. Album name consensus.
        let albumRaw = kept.map { $0.album }
        let realAlbums = albumRaw.filter { !$0.isEmpty && !Organiser.isPlaceholderAlbum($0) }
        let dominantAlbum = Organiser.canonicalAlbumDisplay(realAlbums.isEmpty ? albumRaw : realAlbums)
        if !dominantAlbum.isEmpty {
            var writes: [(rel: String, field: String, value: String)] = []
            var lines: [String] = []
            for t in kept where t.album != dominantAlbum {
                writes.append((rel(t.url), "album", dominantAlbum))
                lines.append("“\(t.title)”: \(t.album.isEmpty ? "—" : t.album) → \(dominantAlbum)")
            }
            if !writes.isEmpty {
                fixes.append(AlbumFix(kind: .album, summary: "Set album to “\(dominantAlbum)” on \(writes.count) track\(writes.count == 1 ? "" : "s")",
                                      lines: lines, enabled: true, applyable: true, tagWrites: writes))
            }
        }

        // ---- 3. Compilation vs album-artist consensus (mutually exclusive).
        let primaryArtists = kept.map { normText($0.artist.isEmpty ? $0.albumArtist : $0.artist) }.filter { !$0.isEmpty }
        let distinctArtists = Set(primaryArtists)
        // most common album-artist and how much of the album agrees with it
        let aaCounts = Dictionary(grouping: kept.map { $0.albumArtist }.filter { !$0.isEmpty }, by: { $0 }).mapValues { $0.count }
        let dominantAA = aaCounts.max(by: { $0.value < $1.value })?.key ?? ""
        let aaAgree = kept.filter { !$0.albumArtist.isEmpty && $0.albumArtist == dominantAA }.count
        let looksCompilation = distinctArtists.count >= 2 &&
            (dominantAA.isEmpty || normText(dominantAA) == "various artists" || Double(aaAgree) < Double(kept.count) * 0.6) &&
            !dominantAlbum.isEmpty

        if looksCompilation {
            var writes: [(rel: String, field: String, value: String)] = []
            var lines: [String] = []
            for t in kept {
                let needAA = normText(t.albumArtist) != "various artists"
                let hasFlag = (PerfectStore.readField(t.url, "compilation") ?? "").hasPrefix("1")
                if needAA { writes.append((rel(t.url), "albumartist", "Various Artists")) }
                if !hasFlag { writes.append((rel(t.url), "compilation", "1")) }
                if needAA || !hasFlag { lines.append("“\(t.title)” — \(t.artist.isEmpty ? "—" : t.artist)") }
            }
            // Only offer the fix when something actually needs changing — otherwise an
            // album that's ALREADY marked "Various Artists" + flagged would keep
            // re-proposing itself every time it's opened.
            if !writes.isEmpty {
                fixes.append(AlbumFix(kind: .compilation,
                                      summary: "Various-artists compilation — set album artist “Various Artists” + compilation flag (\(lines.count) track\(lines.count == 1 ? "" : "s"))",
                                      lines: lines, enabled: true, applyable: true, tagWrites: writes))
            }
        } else {
            // single act: file everything under the album's dominant album-artist. Only
            // trust the dominant album-artist when it has real support (a majority of the
            // tracks) — a lone stray tag ("Mick Jagger" on one track of an otherwise-blank
            // Rolling Stones album) shouldn't be propagated to the whole album; fall back to
            // the track-artist consensus instead.
            let artistConsensus = Dictionary(grouping: kept.map { $0.artist }.filter { !$0.isEmpty }, by: { $0 }).mapValues { $0.count }.max(by: { $0.value < $1.value })?.key ?? ""
            let aaWellSupported = !dominantAA.isEmpty && Double(aaAgree) >= Double(kept.count) * 0.5
            let target = aaWellSupported ? dominantAA : artistConsensus
            if !target.isEmpty {
                var writes: [(rel: String, field: String, value: String)] = []
                var lines: [String] = []
                for t in kept where t.albumArtist != target {
                    writes.append((rel(t.url), "albumartist", target))
                    lines.append("“\(t.title)”: \(t.albumArtist.isEmpty ? "—" : t.albumArtist) → \(target)")
                }
                if !writes.isEmpty {
                    fixes.append(AlbumFix(kind: .albumArtist, summary: "Set album artist to “\(target)” on \(writes.count) track\(writes.count == 1 ? "" : "s")",
                                          lines: lines, enabled: true, applyable: true, tagWrites: writes))
                }
            }
        }

        // ---- 3d. Stuffed artist tags → primary artist + performer credits (Roon shape).
        // Confident splits (machine-joined "A,B" or "A feat. B") are ready to apply;
        // ambiguous spaced lists ("A, B, C & D") are offered OFF by default because a
        // band name can look the same ("Crosby, Stills, Nash & Young").
        for confident in [true, false] {
            var writes: [(rel: String, field: String, value: String)] = []
            var perf: [(rel: String, name: String, role: String)] = []
            var lines: [String] = []
            for t in kept {
                guard let split = TrackProposal.splitArtistCredit(t.artist), split.confident == confident,
                      split.primary != t.artist else { continue }
                writes.append((rel(t.url), "artist", split.primary))
                for p in split.performers where md_has_performer(t.url.path, p.name, p.role) == 0 {
                    perf.append((rel(t.url), p.name, p.role))
                }
                let credited = split.performers.map { $0.name }.joined(separator: ", ")
                lines.append("“\(t.title)” — \(t.artist) → \(split.primary) + credits: \(credited)")
            }
            if !writes.isEmpty {
                fixes.append(AlbumFix(kind: .artistCredit,
                                      summary: confident
                                        ? "Split \(writes.count) stuffed artist tag\(writes.count == 1 ? "" : "s") — primary artist + performer credits"
                                        : "Possibly split \(writes.count) artist list\(writes.count == 1 ? "" : "s") — CHECK it's not a band name first",
                                      lines: lines, enabled: confident, applyable: true,
                                      tagWrites: writes, performerAdds: perf))
            }
        }

        // ---- 3b. Disc order. Duplicate track numbers (same disc + track appearing more
        // than once) mean a multi-disc set was flattened into one folder with no disc
        // tags — so the tracks interleave (1,1,2,2,…). Assign disc numbers by occurrence,
        // ordered by file name, so they group into discs.
        // Only the flattened-with-no-disc-tags shape: if ANY track already carries a disc
        // number, it's a correctly-tagged album (maybe with an accidental duplicate) and we
        // must NOT rewrite everyone's disc down to 1.
        let numbered = kept.filter { $0.trackNo > 0 }
        let dupKeys = Dictionary(grouping: numbered, by: { $0.trackNo }).filter { $0.value.count > 1 }
        if !dupKeys.isEmpty, numbered.allSatisfy({ $0.discNo == 0 }) {
            let discCount = dupKeys.values.map { $0.count }.max() ?? 2
            var seen: [Int: Int] = [:]
            var writes: [(rel: String, field: String, value: String)] = []
            var lines: [String] = []
            for t in kept.sorted(by: { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }) where t.trackNo > 0 {
                let key = t.discNo * 1000 + t.trackNo
                let newDisc = (seen[key] ?? 0) + 1
                seen[key] = newDisc
                if t.discNo != newDisc {
                    writes.append((rel(t.url), "disc", String(newDisc)))
                    lines.append("“\(t.title)” (track \(t.trackNo)) → disc \(newDisc)")
                }
            }
            if !writes.isEmpty {
                fixes.append(AlbumFix(kind: .discOrder,
                                      summary: "Assign disc numbers — looks like a \(discCount)-disc set flattened into one folder (\(writes.count) tracks)",
                                      lines: lines, enabled: true, applyable: true, tagWrites: writes))
            }
        }

        // ---- 3c. Credits — the wizard's "Details" step scoped to this album. In ~2
        // requests, pull performers, composer, lyricist, label and date for the whole
        // album, then gap-fill BLANK fields and add performer credits not already
        // present (md_has_performer keeps it idempotent). Needs identify (recording ids).
        if !acoustIDKey.isEmpty, let seed = seedRecID {
            let credits = await MusicBrainzClient().albumCredits(
                seedRecordingID: seed, albumTitle: dominantAlbum.isEmpty ? fallbackAlbum : dominantAlbum,
                groupSize: kept.count)
            var writes: [(rel: String, field: String, value: String)] = []
            var perf: [(rel: String, name: String, role: String)] = []
            var lines: [String] = []
            for t in kept {
                let e = recIDByRel[rel(t.url)].flatMap { credits.byRecording[$0] }
                    ?? credits.byTitle[TrackProposal.typoFold(t.title).lowercased()]
                guard let e = e, !e.isEmpty else { continue }
                var got: [String] = []
                for (field, value) in [("composer", e.composer), ("lyricist", e.lyricist), ("label", e.label), ("date", e.date)] {
                    if let v = value, !v.isEmpty, (PerfectStore.readField(t.url, field) ?? "").isEmpty {
                        writes.append((rel(t.url), field, v)); got.append(field)
                    }
                }
                let newPerf = e.performers.filter { md_has_performer(t.url.path, $0.name, $0.role) == 0 }
                for pr in newPerf { perf.append((rel(t.url), pr.name, pr.role)) }
                if !newPerf.isEmpty { got.append("\(newPerf.count) credit\(newPerf.count == 1 ? "" : "s")") }
                if !got.isEmpty { lines.append("“\(t.title)” — \(got.joined(separator: ", "))") }
            }
            if !writes.isEmpty || !perf.isEmpty {
                var parts: [String] = []
                if !writes.isEmpty { parts.append("\(writes.count) tag\(writes.count == 1 ? "" : "s")") }
                if !perf.isEmpty { parts.append("\(perf.count) performer credit\(perf.count == 1 ? "" : "s")") }
                fixes.append(AlbumFix(kind: .credits,
                                      summary: "Add \(parts.joined(separator: " + ")) from MusicBrainz / Discogs",
                                      lines: lines, enabled: true, applyable: true,
                                      tagWrites: writes, performerAdds: perf))
            }
        }

        // ---- 4. Cover-art context. The interactive chooser lives in the sheet (it also
        // fetches online candidates), so here we only gather each track's current cover
        // fingerprint and the album's distinct embedded covers, best first.
        var relArt: [String: (pixels: Int, bytes: Int)] = [:]
        var coverByFP: [String: (data: Data, pixels: Int)] = [:]
        for t in kept {
            if let a = artInfo(t.url) {
                relArt[rel(t.url)] = (a.pixels, a.data.count)
                let fp = "\(a.pixels)-\(a.data.count)"
                if coverByFP[fp] == nil { coverByFP[fp] = (a.data, a.pixels) }
            }
        }
        let ownCovers = coverByFP.values.sorted { $0.pixels > $1.pixels }.map { $0.data }
        let mostCommonArtist = Dictionary(grouping: kept.map { $0.artist }.filter { !$0.isEmpty }, by: { $0 })
            .mapValues { $0.count }.max(by: { $0.value < $1.value })?.key ?? ""
        let fetchArtist = looksCompilation ? "Various Artists" : (dominantAA.isEmpty ? mostCommonArtist : dominantAA)
        let art = AlbumArtContext(artist: fetchArtist,
                                  album: dominantAlbum.isEmpty ? fallbackAlbum : dominantAlbum,
                                  rels: kept.map { rel($0.url) }, relArt: relArt, ownCovers: ownCovers)

        // ---- 5. File-name tidy → "## Title.ext" (disc-prefixed on multi-disc sets).
        let multiDisc = kept.contains { $0.discNo > 1 }
        var renames: [(from: String, to: String)] = []
        var renameLines: [String] = []
        for t in kept where t.trackNo > 0 && !t.title.isEmpty {
            let num = multiDisc && t.discNo > 0 ? "\(t.discNo)-" + String(format: "%02d", t.trackNo) : String(format: "%02d", t.trackNo)
            let ideal = "\(num) \(Organiser.safe(t.title)).\(t.url.pathExtension.lowercased())"
            if t.url.lastPathComponent != ideal {
                let dir = (rel(t.url) as NSString).deletingLastPathComponent
                let toRel = dir.isEmpty ? ideal : dir + "/" + ideal
                // skip if that name is already taken by another kept track
                if kept.contains(where: { $0.url.lastPathComponent == ideal && $0.id != t.id }) { continue }
                renames.append((rel(t.url), toRel))
                renameLines.append("“\(t.url.lastPathComponent)” → “\(ideal)”")
            }
        }
        if !renames.isEmpty {
            fixes.append(AlbumFix(kind: .filename, summary: "Tidy \(renames.count) file name\(renames.count == 1 ? "" : "s") to “## Title”",
                                  lines: renameLines, enabled: true, applyable: true, moves: renames))
        }

        // ---- 6. Possibly-damaged flag: lone very-short files with no full-length twin.
        // Information only — never auto-removed. Skipped if it's already a dedup loser.
        let durs = kept.map { $0.duration }.filter { $0 > 0 }.sorted()
        let median = durs.isEmpty ? 0 : durs[durs.count / 2]
        var damagedLines: [String] = []
        for t in kept where t.duration > 0 && t.duration <= 40 && median > 90 && t.duration < median * 0.5 {
            damagedLines.append("“\(t.title)” — \(fmtDur(t.duration)) (album typical \(fmtDur(median)))")
        }
        if !damagedLines.isEmpty {
            fixes.append(AlbumFix(kind: .damaged, summary: "\(damagedLines.count) track\(damagedLines.count == 1 ? "" : "s") look unusually short — check before keeping",
                                  lines: damagedLines, enabled: false, applyable: false))
        }

        // ---- 7. Missing tracks — reconcile across MusicBrainz, Discogs and Deezer
        // (network). Runs as part of the Perfect check so the result is remembered on
        // Apply and the inspector can keep showing the gaps. The richest tracklist that
        // fits the folder wins; declines rather than guess when nothing matches.
        // Skip when the album's already been reconciled (result saved + shown in the
        // inspector) — no point re-fetching and re-listing it every time Perfect opens.
        // Only reconcile a real album (4+ tracks) — a single or a 2–3 track EP would match
        // a full release and grey in a pile of bogus "missing" tracks. (Same gate as batch.)
        var reconcile: MBReleaseMatch? = nil
        let discCount = max(1, Set(kept.map { $0.discNo == 0 ? 1 : $0.discNo }).count)
        if !alreadyReconciled, kept.count >= 4,
           let match = await MusicBrainzClient().bestRelease(artist: art.artist, album: art.album,
                                                             haveTitles: kept.map { $0.title }, discCount: discCount) {
            reconcile = match
            let haveFolded = Set(kept.map { TrackProposal.typoFold($0.title).lowercased() })
            let missing = match.tracks
                .filter { !haveFolded.contains(TrackProposal.typoFold($0.title).lowercased()) }
                .sorted { ($0.disc, $0.track) < ($1.disc, $1.track) }
            if !missing.isEmpty {
                let lines = missing.map { "Disc \($0.disc) · \($0.track). \($0.title)" }
                fixes.append(AlbumFix(kind: .missing,
                                      summary: "\(missing.count) of \(match.tracks.count) tracks missing from “\(match.title)” — kept so the album shows the gaps",
                                      lines: lines, enabled: false, applyable: false))
            }

            // Correct disc & track numbers FROM the matched release when the on-disk tags
            // are broken — a flattened multi-disc set has duplicate (disc,track) keys (every
            // track wrongly tagged one disc). The release is authoritative for which disc a
            // title belongs to, so write its numbers rather than guess. (Tags only; a later
            // Perfect pass re-tidies the file names once the numbers are right.)
            let dupKeys = Dictionary(grouping: kept, by: { $0.discNo * 1000 + $0.trackNo }).contains { $0.value.count > 1 }
            if dupKeys {
                let slotByTitle = Dictionary(match.tracks.map { (TrackProposal.typoFold($0.title).lowercased(), $0) },
                                             uniquingKeysWith: { a, _ in a })
                var writes: [(rel: String, field: String, value: String)] = []
                var lines: [String] = []
                for t in kept {
                    guard let slot = slotByTitle[TrackProposal.typoFold(t.title).lowercased()] else { continue }
                    if t.discNo != slot.disc { writes.append((rel(t.url), "disc", String(slot.disc))) }
                    if t.trackNo != slot.track { writes.append((rel(t.url), "track", String(slot.track))) }
                    if t.discNo != slot.disc || t.trackNo != slot.track {
                        lines.append("“\(t.title)” → disc \(slot.disc), track \(slot.track)")
                    }
                }
                if !writes.isEmpty {
                    fixes.append(AlbumFix(kind: .discOrder,
                                          summary: "Fix disc & track numbers from “\(match.title)” (\(lines.count) track\(lines.count == 1 ? "" : "s"))",
                                          lines: lines, enabled: true, applyable: true, tagWrites: writes))
                }
            }
        }

        return (fixes, art, reconcile)
    }
}


/// "Perfect this album" — a checklist of the offline fixes AlbumPerfect finds for
/// one album, each toggleable, applied as ONE reversible run (shows in Runs). Nothing
/// is written until Apply; the whole run is undoable afterwards.
struct PerfectAlbumSheet: View {
    let album: LibAlbum
    let root: URL
    var onApplied: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: PerfectStore

    @State private var fixes: [AlbumFix] = []
    @State private var art: AlbumArtContext?
    @State private var serviceCovers: [Data] = []
    @State private var selectedCover: Data?        // cover to apply across the album (nil = leave as is)
    @State private var coversLoading = false
    @State private var loading = true
    @State private var applying = false
    @State private var reconcile: MBReleaseMatch?   // matched tracklist, saved on Apply

    private var applyable: [AlbumFix] { fixes.filter { $0.applyable && $0.enabled } }

    /// Covers offered in the chooser: the album's own distinct covers first, then the
    /// online candidates that aren't byte-identical to one we already have.
    private var candidateCovers: [Data] {
        guard let a = art else { return [] }
        let ownKeys = Set(a.ownCovers.map { coverKey($0) })
        return a.ownCovers + serviceCovers.filter { !ownKeys.contains(coverKey($0)) }
    }
    private func coverKey(_ d: Data) -> String { "\(d.count):" + String(d.prefix(48).reduce(UInt64(0)) { $0 &+ UInt64($1) }) }

    /// The artwork embeds for the chosen cover: stamp it on every track whose current
    /// cover is missing or different. Empty when nothing is selected or all already match.
    private var artEmbeds: [(rel: String, image: Data, mime: String)] {
        guard let a = art, let sel = selectedCover else { return [] }
        let mime = sel.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
        let px = NSBitmapImageRep(data: sel).map { $0.pixelsWide * $0.pixelsHigh } ?? 0
        let selFP = (pixels: px, bytes: sel.count)
        return a.rels.compactMap { r in
            let cur = a.relArt[r]
            return (cur == nil || cur! != selFP) ? (r, sel, mime) : nil
        }
    }
    private var totalChanges: Int { applyable.reduce(0) { $0 + $1.changeCount } + artEmbeds.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Checking the album…").foregroundStyle(.secondary)
                    Text("Identifying tracks by sound can take a moment.").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        if let a = art { coverPanel(a) }
                        if fixes.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.seal").foregroundStyle(.teal)
                                Text("Tags are consistent and there are no duplicates — only the cover art above to adjust if you want.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        } else {
                            ForEach($fixes) { $fix in FixRow(fix: $fix) }
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 680, height: 560)
        .onAppear { runAnalysis() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AlbumCover(key: album.id, sampleURL: album.sampleURL, foundMBID: nil, size: 52, corner: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text("Perfect this album").font(.headline)
                Text(album.album.isEmpty ? album.dir.lastPathComponent : album.album)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text("Review the checklist, then apply everything in one reversible step.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(14)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if applying {
                ProgressView().controlSize(.small)
                Text("Applying…").foregroundStyle(.secondary).font(.callout)
            } else if !fixes.isEmpty {
                Text(totalChanges == 0
                     ? (reconcile != nil ? "Save the tracklist so missing tracks stay shown" : "Nothing selected")
                     : "\(totalChanges) change\(totalChanges == 1 ? "" : "s") selected · reversible from Runs")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }.disabled(applying)
            Button("Apply") { apply() }
                .buttonStyle(.borderedProminent).tint(.teal)
                .keyboardShortcut(.defaultAction)
                .disabled(applying || (totalChanges == 0 && reconcile == nil))
        }
        .padding(14)
    }

    @ViewBuilder private func coverPanel(_ a: AlbumArtContext) -> some View {
        let cands = candidateCovers
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "photo").foregroundStyle(.teal)
                Text("Cover art").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                if coversLoading { ProgressView().controlSize(.small).scaleEffect(0.7) }
                Spacer()
                if selectedCover != nil, !a.ownCovers.isEmpty {
                    Button("Keep current") { selectedCover = a.ownCovers.first }.controlSize(.small).buttonStyle(.plain).foregroundStyle(.teal)
                }
            }
            if cands.isEmpty {
                Text(coversLoading ? "Looking up covers…" : "No cover found in the files or online.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(cands.enumerated()), id: \.offset) { idx, data in
                            CoverThumb(data: data,
                                       selected: selectedCover.map { coverKey($0) == coverKey(data) } ?? false,
                                       badge: idx < a.ownCovers.count ? (idx == 0 ? "in files" : nil) : "online")
                                .onTapGesture { selectedCover = data }
                        }
                    }.padding(.vertical, 2)
                }
            }
            Text(coverStatus(a)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func coverStatus(_ a: AlbumArtContext) -> String {
        guard selectedCover != nil else { return "Pick a cover to apply it across the album, or leave the files as they are." }
        let n = artEmbeds.count
        if n == 0 { return "Every track already uses this cover." }
        return "Will set this cover on \(n) of \(a.rels.count) track\(a.rels.count == 1 ? "" : "s")."
    }

    private func runAnalysis() {
        loading = true
        let root = self.root, files = album.files
        let alreadyReconciled = AlbumReconcileStore.load(album.id) != nil
        Task {
            let (result, ctx, rec) = await AlbumPerfect.analyze(root: root, files: files,
                                                                alreadyReconciled: alreadyReconciled)
            await MainActor.run {
                fixes = result; art = ctx; reconcile = rec
                selectedCover = ctx.ownCovers.first   // default: the album's best own cover
                loading = false
            }
            // Look up more covers online so one can be chosen even when art already exists.
            if !ctx.album.isEmpty {
                await MainActor.run { coversLoading = true }
                let found = await CoverArtClient().candidates(releaseMBIDs: [], artist: ctx.artist, album: ctx.album)
                await MainActor.run { serviceCovers = found; coversLoading = false }
            }
        }
    }

    private func apply() {
        let hasChanges = totalChanges > 0
        guard hasChanges || reconcile != nil else { return }
        // remember the matched tracklist so the inspector keeps showing missing tracks
        if let r = reconcile { AlbumReconcileStore.save(album.id, r) }
        guard hasChanges else { dismiss(); onApplied(); return }   // reconcile-only: nothing to write
        applying = true
        let chosen = applyable
        let tagWrites = chosen.flatMap { $0.tagWrites }
        let moves = chosen.flatMap { $0.moves }
        let embeds = chosen.flatMap { $0.artEmbeds } + artEmbeds   // checklist art (none now) + the chosen cover
        let perfAdds = chosen.flatMap { $0.performerAdds }
        let name = album.album.isEmpty ? album.dir.lastPathComponent : album.album
        store.applyLibraryRun(root: root, summary: "Perfected album — \(name)",
                              tagWrites: tagWrites, moves: moves, artEmbeds: embeds, performerAdds: perfAdds) {
            applying = false
            dismiss()
            onApplied()
        }
    }
}

/// A selectable cover thumbnail in the chooser: the image, a teal ring when picked,
/// and a small source badge ("in files" / "online").
private struct CoverThumb: View {
    let data: Data
    let selected: Bool
    var badge: String? = nil
    @State private var showFull = false

    private var pixels: (w: Int, h: Int)? {
        guard let r = NSBitmapImageRep(data: data) else { return nil }
        return (r.pixelsWide, r.pixelsHigh)
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                if let img = NSImage(data: data) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 72, height: 72).clipped().cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Color.teal : Color.secondary.opacity(0.25), lineWidth: selected ? 3 : 1))
            .overlay(alignment: .topTrailing) {
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.teal).background(Circle().fill(.white)).padding(2) }
            }
            // "+" opens the cover at full size so it can be validated before selecting.
            .overlay(alignment: .bottomTrailing) {
                Button { showFull = true } label: {
                    Image(systemName: "plus.magnifyingglass").font(.system(size: 11, weight: .bold))
                        .padding(3).background(Circle().fill(.black.opacity(0.55))).foregroundStyle(.white)
                }
                .buttonStyle(.plain).padding(3)
                .help("View this cover full size")
                .popover(isPresented: $showFull, arrowEdge: .top) { fullPreview }
            }
            if let b = badge {
                Text(b).font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
            } else {
                Text(" ").font(.system(size: 8))
            }
        }
        .contentShape(Rectangle())
    }

    private var fullPreview: some View {
        VStack(spacing: 8) {
            if let img = NSImage(data: data) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 460, maxHeight: 460).cornerRadius(8)
            } else {
                Image(systemName: "photo").font(.system(size: 40)).foregroundStyle(.tertiary).frame(width: 200, height: 200)
            }
            Text(pixels.map { "\($0.w) × \($0.h) · \(fmtBytes(Int64(data.count)))" } ?? fmtBytes(Int64(data.count)))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(14)
    }
}

/// One checklist row: a checkbox (or a warning marker for info-only items), the
/// headline, and an expandable list of the exact per-track changes.
private struct FixRow: View {
    @Binding var fix: AlbumFix
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                if fix.applyable {
                    Toggle("", isOn: $fix.enabled).labelsHidden().toggleStyle(.checkbox)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).frame(width: 16)
                }
                Image(systemName: fix.systemImage)
                    .foregroundStyle(fix.applyable ? Color.teal : Color.orange)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fix.kind.rawValue).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    Text(fix.summary).font(.system(size: 13)).foregroundStyle(fix.enabled || !fix.applyable ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !fix.lines.isEmpty {
                    Button { withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() } } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }.buttonStyle(.plain)
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(fix.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 56).padding(.top, 6)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { if !fix.lines.isEmpty { withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() } } }
    }
}
