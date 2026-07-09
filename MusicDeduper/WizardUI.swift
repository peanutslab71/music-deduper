//
//  WizardUI.swift
//  MusicDeduper
//
//  The wizard chrome + step views: Source → Review → Clean up → Copy.
//  Also the album-artwork cache and the copy-conflict panel.
//

import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Wizard steps

enum WizardStep: Int, CaseIterable, Identifiable {
    case source, review, cleanup, copy
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .source:  return "Source"
        case .review:  return "Review"
        case .cleanup: return "Clean up"
        case .copy:    return "Copy"
        }
    }
    var icon: String {
        switch self {
        case .source:  return "folder"
        case .review:  return "rectangle.grid.2x2"
        case .cleanup: return "trash"
        case .copy:    return "externaldrive.badge.icloud"
        }
    }
}

/// Step indicator across the top. Completed / reachable steps stay clickable.
struct StepBar: View {
    @Binding var step: WizardStep
    let hasScan: Bool

    private func reachable(_ s: WizardStep) -> Bool {
        s == .source || hasScan
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(WizardStep.allCases) { s in
                let current = s == step
                Button {
                    if reachable(s) { step = s }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: current ? "\(s.icon).fill" : s.icon)
                            .symbolVariant(current ? .fill : .none)
                        Text(s.title)
                    }
                    .font(.system(size: 13, weight: current ? .semibold : .regular))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(current ? Color.accentColor.opacity(0.16) : .clear)
                    )
                    .foregroundStyle(current ? Color.accentColor : (reachable(s) ? .primary : .secondary))
                }
                .buttonStyle(.plain)
                .disabled(!reachable(s))
                if s != .copy {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.quaternary)
                        .padding(.horizontal, 2)
                }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Step 1 · Source

struct SourceStepView: View {
    @ObservedObject var store: DedupStore
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            if store.busy {
                scanningPanel
            } else {
                pickerPanel
            }
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pickerPanel: some View {
        VStack(spacing: 22) {
            Image(systemName: "music.note.house")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Where's your music?").font(.title).fontWeight(.semibold)
            Text("Drop your music folder here, or browse for it.\nThe app reads real tags and durations — nothing is changed.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(spacing: 14) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
                Text(dropTargeted ? "Drop to scan" : "Drop a folder here")
                    .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
                Button {
                    store.pickSource()
                } label: {
                    Label("Browse…", systemImage: "folder")
                        .frame(minWidth: 120)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
            .frame(width: 420, height: 170)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.35))
                    .background(RoundedRectangle(cornerRadius: 14)
                        .fill(dropTargeted ? Color.accentColor.opacity(0.06) : Color.secondary.opacity(0.04)))
            )
            .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                        Task { @MainActor in store.setSource(url) }
                    }
                }
                return true
            }

            if !store.recentSources.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RECENT").font(.caption2).fontWeight(.semibold).foregroundStyle(.tertiary)
                    ForEach(store.recentSources, id: \.self) { path in
                        Button {
                            store.setSource(URL(fileURLWithPath: path))
                        } label: {
                            Label(path, systemImage: "clock.arrow.circlepath")
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .buttonStyle(.link)
                    }
                }
                .frame(width: 420, alignment: .leading)
            }

            DisclosureGroup("Matching options") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Match mode", selection: $store.matchMode) {
                        ForEach(MatchMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("Duration tolerance")
                        Slider(value: $store.tolerance, in: 0...10, step: 1).frame(width: 160)
                        Text("± \(Int(store.tolerance))s").monospacedDigit()
                    }
                    Toggle("Match across albums", isOn: $store.crossAlbum)
                }
                .padding(.top, 8)
            }
            .frame(width: 420)
        }
    }

    private var scanningPanel: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.accentColor)
                .symbolEffectCompat()
            Text("Scanning your library…").font(.title2).fontWeight(.semibold)
            ProgressView(value: store.progress).frame(width: 380)
            Text(store.status)
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(width: 440)
        }
    }
}

private extension View {
    /// Pulse effect where available; no-op on macOS 13.
    @ViewBuilder func symbolEffectCompat() -> some View {
        if #available(macOS 14.0, *) {
            self.symbolEffect(.pulse)
        } else { self }
    }
}

// MARK: - Step 2 · Review

struct ReviewStepView: View {
    @ObservedObject var store: DedupStore
    @Binding var reviewTab: Int          // 0 duplicates · 1 library
    @State private var selectedAlbum: AlbumKey? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $reviewTab) {
                    Text("Duplicates (\(store.clusters.count))").tag(0)
                    Text("Library").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 340)
                Spacer()
                Text(statsText).font(.caption).foregroundStyle(.secondary)
                Button {
                    store.scan()
                } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .disabled(store.busy)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            if reviewTab == 0 { duplicatesList } else { albumGrid }
        }
        .sheet(item: $selectedAlbum) { key in
            AlbumDetailSheet(key: key, tracks: albumTracks(key))
        }
    }

    private var statsText: String {
        guard !store.tracks.isEmpty else { return "" }
        return "\(store.artistCount) artists · \(store.tracks.count) tracks · reclaim \(fmtBytes(store.reclaimBytes))"
    }

    // — Duplicates —

    private var duplicatesList: some View {
        Group {
            if store.clusters.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 40, weight: .light)).foregroundStyle(.green)
                    Text("No duplicates found").font(.title3)
                    Text("Your library is clean — browse it on the Library tab.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.clusters) { cluster in
                        Section {
                            ForEach(cluster.memberIDs, id: \.self) { tid in
                                if let t = store.trackByID(tid) {
                                    memberRow(cluster: cluster, track: t)
                                }
                            }
                        } header: {
                            clusterHeader(cluster)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func clusterHeader(_ cluster: Cluster) -> some View {
        HStack(spacing: 10) {
            if let t = store.trackByID(cluster.keeperID) {
                ArtworkView(key: t.relDir, sampleURL: t.url, size: 34, corner: 5)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(cluster.artist) — \(cluster.title)").fontWeight(.semibold)
                Text("\(cluster.memberIDs.count) copies · \(cluster.reason)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("saves \(fmtBytes(cluster.reclaim))")
                .font(.caption).fontWeight(.medium)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.green.opacity(0.15)))
                .foregroundStyle(.green)
        }
        .padding(.vertical, 3)
    }

    private func memberRow(cluster: Cluster, track t: Track) -> some View {
        let isKeeper = cluster.keeperID == t.id
        return HStack(spacing: 10) {
            Image(systemName: isKeeper ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isKeeper ? .green : .secondary)
            Text(isKeeper ? "KEEP" : "duplicate")
                .font(.caption2).fontWeight(.bold)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(isKeeper ? Color.green.opacity(0.16) : Color.orange.opacity(0.14)))
                .foregroundStyle(isKeeper ? .green : .orange)
                .frame(width: 76)
            Text(t.url.path).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            chip(t.formatLabel)
            Text(fmtDur(t.duration)).font(.caption).foregroundStyle(.secondary)
                .monospacedDigit().frame(width: 48, alignment: .trailing)
            Text(fmtBytes(t.size)).font(.caption).foregroundStyle(.secondary)
                .monospacedDigit().frame(width: 70, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.setKeeper(clusterID: cluster.id, trackID: t.id) }
        .help("Click to keep this version")
    }

    private func chip(_ s: String) -> some View {
        Text(s).font(.caption2).monospaced()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
    }

    // — Library: album artwork grid —

    struct AlbumKey: Identifiable, Hashable {
        let artist: String
        let album: String
        var id: String { artist + "\u{0}" + album }
    }

    private func albums() -> [(key: AlbumKey, tracks: [Track])] {
        var map: [AlbumKey: [Track]] = [:]
        for t in store.tracks {
            let key = AlbumKey(artist: t.displayArtist.isEmpty ? "Unknown Artist" : t.displayArtist,
                               album: t.album.isEmpty ? "Unknown Album" : t.album)
            map[key, default: []].append(t)
        }
        return map.map { ($0.key, $0.value) }
            .sorted { ($0.key.artist.lowercased(), $0.key.album.lowercased())
                    < ($1.key.artist.lowercased(), $1.key.album.lowercased()) }
    }

    private func albumTracks(_ key: AlbumKey) -> [Track] {
        albums().first { $0.key == key }?.tracks.sorted {
            ($0.discNo, $0.trackNo, $0.title.lowercased()) < ($1.discNo, $1.trackNo, $1.title.lowercased())
        } ?? []
    }

    private var albumGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 18)], spacing: 20) {
                ForEach(albums(), id: \.key) { entry in
                    Button {
                        selectedAlbum = entry.key
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ArtworkView(key: entry.tracks.first?.relDir ?? entry.key.id,
                                        sampleURL: entry.tracks.first?.url,
                                        size: 150, corner: 8)
                            Text(entry.key.album).font(.callout).fontWeight(.medium)
                                .lineLimit(1)
                            Text("\(entry.key.artist) · \(entry.tracks.count) tracks")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: 150, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
        }
    }
}

/// Track list for one album.
struct AlbumDetailSheet: View {
    let key: ReviewStepView.AlbumKey
    let tracks: [Track]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                ArtworkView(key: tracks.first?.relDir ?? key.id, sampleURL: tracks.first?.url, size: 96, corner: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(key.album).font(.title3).fontWeight(.semibold)
                    Text(key.artist).foregroundStyle(.secondary)
                    Text("\(tracks.count) tracks · \(fmtBytes(tracks.reduce(0) { $0 + $1.size }))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            List(tracks, id: \.id) { t in
                HStack {
                    Text(t.trackNo > 0 ? String(format: "%02d", t.trackNo) : "—")
                        .font(.caption).monospaced().foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .trailing)
                    Text(t.title).lineLimit(1)
                    Spacer()
                    Text("\(fmtDur(t.duration)) · \(t.formatLabel) · \(fmtBytes(t.size))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 520, height: 480)
    }
}

// MARK: - Step 3 · Clean up

struct CleanupStepView: View {
    @ObservedObject var store: DedupStore
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            if store.clusters.isEmpty {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 44, weight: .light)).foregroundStyle(.green)
                Text("Nothing to clean up").font(.title2).fontWeight(.semibold)
                Text("No duplicate groups in this library — carry on to Copy.")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "trash")
                    .font(.system(size: 44, weight: .light)).foregroundStyle(Color.accentColor)
                Text("Remove the duplicates").font(.title2).fontWeight(.semibold)
                HStack(spacing: 26) {
                    stat("\(store.clusters.count)", "groups")
                    stat("\(store.removableCount)", "files to remove")
                    stat(fmtBytes(store.reclaimBytes), "reclaimed")
                }
                Text("The marked KEEP copy of every group is never touched.\nYou'll confirm twice, and Trash is the default — recoverable.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete duplicates…", systemImage: "trash")
                        .frame(minWidth: 180)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(store.busy)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3).fontWeight(.semibold).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 90)
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
    }
}

// MARK: - Step 4 · Copy

struct CopyStepView: View {
    @ObservedObject var store: DedupStore
    @Binding var destFolder: URL?
    let onCopy: (URL) -> Void

    private var shareName: String {
        guard let u = URL(string: store.smbAddress), let h = u.host else { return "" }
        return "\(h)\(u.path)"
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 8)
            Text("Copy your keepers to a server").font(.title2).fontWeight(.semibold)
            Text("The best copy of every track, rebuilt as a clean Artist/Album tree.")
                .foregroundStyle(.secondary)

            numbered(1, title: "Where is your Roon server (or NAS)?",
                     detail: store.smbAddress.isEmpty
                        ? "Locate the music share so the app can reconnect to it if the network drops mid-copy."
                        : "Connected share: \(shareName)  — remembered for automatic reconnects.") {
                Button {
                    locateServer()
                } label: {
                    Label(store.smbAddress.isEmpty ? "Locate server share…" : "Change…",
                          systemImage: "server.rack")
                }
            }

            numbered(2, title: "Which folder inside it?",
                     detail: destFolder.map { "Copying into: \($0.path)" }
                        ?? "Pick the folder the Artist/Album tree should be created in.") {
                Button {
                    pickDestFolder()
                } label: {
                    Label(destFolder == nil ? "Choose folder…" : "Change…", systemImage: "folder")
                }
            }

            numbered(3, title: "Copy",
                     detail: "\(store.keeperTracks.count) keeper tracks · any file that already exists asks Overwrite/Skip (or All) · a Roon ROCK destination is checked and Roon Server stopped first.") {
                Button {
                    if let d = destFolder { onCopy(d) }
                } label: {
                    Label("Copy \(store.keeperTracks.count) keepers", systemImage: "arrow.right.doc.on.clipboard")
                        .frame(minWidth: 180)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(destFolder == nil || store.busy || store.tracks.isEmpty)
            }
            Spacer(minLength: 8)
        }
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func numbered(_ n: Int, title: String, detail: String,
                          @ViewBuilder action: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)")
                .font(.headline).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                action().padding(.top, 4)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
    }

    /// Browse to the server share (Network → server → share), capture its
    /// smb:// remount address, and default the destination to the share root.
    private func locateServer() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.message = "Browse to your server's music share (e.g. Network → your ROCK → Data) and select it"
        p.prompt = "Use This Share"
        if p.runModal() == .OK, let url = p.url {
            if let vals = try? url.resourceValues(forKeys: [.volumeURLForRemountingKey]),
               let remount = vals.volumeURLForRemounting {
                store.smbAddress = remount.absoluteString
            }
            destFolder = url
        }
    }

    private func pickDestFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.canCreateDirectories = true
        p.message = "Choose the folder to copy the Artist/Album tree into"
        p.prompt = "Choose"
        if let d = destFolder { p.directoryURL = d }
        if p.runModal() == .OK, let url = p.url {
            destFolder = url
            // keep the reconnect address in sync if they picked on another share
            if let vals = try? url.resourceValues(forKeys: [.volumeURLForRemountingKey]),
               let remount = vals.volumeURLForRemounting {
                store.smbAddress = remount.absoluteString
            }
        }
    }
}

// MARK: - Copy-conflict panel (embedded in the operation sheet)

struct ConflictPanel: View {
    let conflict: CopyConflict
    let onDecision: (ConflictDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(conflict.identical
                    ? "This file already exists (identical size)"
                    : "This file already exists — and it's different",
                  systemImage: conflict.identical ? "doc.on.doc" : "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(conflict.identical ? Color.secondary : Color.orange)
            HStack(spacing: 12) {
                ArtworkView(key: conflict.srcURL.deletingLastPathComponent().path,
                            sampleURL: conflict.srcURL, size: 44, corner: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(conflict.name).fontWeight(.medium).lineLimit(1)
                    Text("\(conflict.artist) — \(conflict.album)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text("Yours: \(fmtBytes(conflict.srcSize))   ·   On server: \(fmtBytes(conflict.dstSize))\(conflict.dstDate.map { " (modified \(Self.df.string(from: $0)))" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button("Overwrite") { onDecision(.overwrite) }
                Button("Overwrite All") { onDecision(.overwriteAll) }
                Spacer()
                Button("Skip") { onDecision(.skip) }.keyboardShortcut(.defaultAction)
                Button("Skip All") { onDecision(.skipAll) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35)))
    }

    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
}

// MARK: - Album artwork

/// Lazily loads and caches album artwork from the files' own tags.
/// Keyed by album directory so each album is read once.
@MainActor
final class ArtworkCache: ObservableObject {
    static let shared = ArtworkCache()
    private var images: [String: NSImage] = [:]
    private var misses: Set<String> = []
    private var inflight: Set<String> = []

    func cached(_ key: String) -> NSImage? { images[key] }

    func request(key: String, sampleURL: URL?) {
        guard images[key] == nil, !misses.contains(key), !inflight.contains(key),
              let url = sampleURL else { return }
        inflight.insert(key)
        Task {
            let img = await Self.load(url: url)
            self.inflight.remove(key)
            if let img { self.images[key] = img } else { self.misses.insert(key) }
            self.objectWillChange.send()
        }
    }

    nonisolated private static func load(url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        guard let meta = try? await asset.load(.commonMetadata) else { return nil }
        let items = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .commonIdentifierArtwork)
        guard let item = items.first,
              let data = try? await item.load(.dataValue),
              let img = NSImage(data: data) else { return nil }
        return downscaled(img, maxSide: 320)
    }

    nonisolated private static func downscaled(_ img: NSImage, maxSide: CGFloat) -> NSImage {
        let sz = img.size
        guard max(sz.width, sz.height) > maxSide, sz.width > 0, sz.height > 0 else { return img }
        let scale = maxSide / max(sz.width, sz.height)
        let newSize = NSSize(width: sz.width * scale, height: sz.height * scale)
        let out = NSImage(size: newSize)
        out.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: newSize),
                 from: NSRect(origin: .zero, size: sz), operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }
}

/// Artwork thumbnail with a placeholder while (or if nothing) loads.
struct ArtworkView: View {
    @ObservedObject private var cache = ArtworkCache.shared
    let key: String
    let sampleURL: URL?
    let size: CGFloat
    var corner: CGFloat = 8

    var body: some View {
        Group {
            if let img = cache.cached(key) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Color.secondary.opacity(0.18), Color.secondary.opacity(0.10)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.34, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(Color.black.opacity(0.08)))
        .onAppear { cache.request(key: key, sampleURL: sampleURL) }
    }
}
