//
//  ContentView.swift
//  MusicDeduper
//

import SwiftUI

struct ContentView: View {
    @StateObject private var store = DedupStore()
    @State private var tab: Int = 0

    // delete flow state machine
    private enum DeletePhase { case none, choose, confirm1, confirm2 }
    @State private var deletePhase: DeletePhase = .none
    @State private var chosenMode: DeleteMode = .trash

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            smbRow
            Divider()
            Picker("", selection: $tab) {
                Text("Duplicates").tag(0)
                Text("Library").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            .frame(maxWidth: 320)

            if tab == 0 { duplicatesView } else { libraryView }

            Divider()
            footer
        }
        .frame(minWidth: 900, minHeight: 560)
        // 1) choose Trash vs Permanent
        .confirmationDialog("Delete duplicates",
                            isPresented: bind(.choose), titleVisibility: .visible) {
            Button("Move to Trash (recoverable)") { chosenMode = .trash; deletePhase = .confirm1 }
            Button("Permanently delete", role: .destructive) { chosenMode = .permanent; deletePhase = .confirm1 }
            Button("Cancel", role: .cancel) { deletePhase = .none }
        } message: {
            Text("Remove \(store.removableCount) duplicate file(s) — reclaim \(fmtBytes(store.reclaimBytes)). Keepers are never touched.")
        }
        // 2) first confirmation
        .alert("Confirm delete (1 of 2)", isPresented: bind(.confirm1)) {
            Button("Continue…") { deletePhase = .confirm2 }
            Button("Cancel", role: .cancel) { deletePhase = .none }
        } message: {
            Text("You are about to remove \(store.removableCount) duplicate file(s), keeping the best copy of each. This frees about \(fmtBytes(store.reclaimBytes)).")
        }
        // 3) final confirmation
        .alert("Confirm delete (2 of 2)", isPresented: bind(.confirm2)) {
            Button(chosenMode == .trash ? "Move to Trash" : "Delete permanently",
                   role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) { deletePhase = .none }
        } message: {
            Text(chosenMode == .trash
                 ? "\(store.removableCount) file(s) will be moved to the Trash. You can restore them if needed. Are you absolutely sure?"
                 : "\(store.removableCount) file(s) will be PERMANENTLY deleted and cannot be recovered. Are you absolutely sure?")
        }
        // progress dialog for copy / delete, with live log + Cancel
        .sheet(isPresented: $store.opActive) {
            OperationSheet(store: store)
        }
    }

    private func bind(_ phase: DeletePhase) -> Binding<Bool> {
        Binding(get: { deletePhase == phase },
                set: { if !$0 && deletePhase == phase { deletePhase = .none } })
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { store.pickSource() } label: {
                Label("Pick source folder", systemImage: "folder")
            }
            .disabled(store.busy)
            if store.sourceURL != nil {
                Button { store.scan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(store.busy)
            }
            Divider().frame(height: 18)
            Text("Match:")
            Picker("", selection: $store.matchMode) {
                ForEach(MatchMode.allCases) { Text($0.label).tag($0) }
            }.labelsHidden().frame(width: 130)
            Text("± \(Int(store.tolerance))s")
            Stepper("", value: $store.tolerance, in: 0...10).labelsHidden()
            Toggle("across albums", isOn: $store.crossAlbum)
            Spacer()
            Text(statsText).font(.callout).foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private var smbRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
            Text("Reconnect target (SMB guest):").foregroundStyle(.secondary)
            TextField("smb://rock/Data", text: $store.smbAddress)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Button("Connect…") { establishMount() }
            Text("— app re-mounts this and resumes if the copy drops")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// Open the native network browser so the user can mount the ROCK share,
    /// then capture its smb:// remount address automatically.
    private func establishMount() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.message = "Browse to your ROCK share (Network → your server → Data) and select it"
        p.prompt = "Use This Share"
        if p.runModal() == .OK, let url = p.url {
            captureRemountAddress(from: url)
        }
    }

    /// Reads the smb:// URL that macOS would use to remount the volume `url` lives on.
    private func captureRemountAddress(from url: URL) {
        if let vals = try? url.resourceValues(forKeys: [.volumeURLForRemountingKey]),
           let remount = vals.volumeURLForRemounting {
            store.smbAddress = remount.absoluteString
        }
    }

    private var statsText: String {
        guard !store.tracks.isEmpty else { return "" }
        return "\(store.artistCount) artists · \(store.tracks.count) tracks · \(store.clusters.count) dup groups · reclaim \(fmtBytes(store.reclaimBytes))"
    }

    // MARK: Duplicates

    private var duplicatesView: some View {
        Group {
            if store.clusters.isEmpty {
                ContentUnavailableCompat(title: store.tracks.isEmpty ? "No folder scanned yet" : "No duplicate groups found 🎉",
                                         subtitle: store.tracks.isEmpty ? "Pick a source folder to begin." : "")
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
                            HStack {
                                Text("\(cluster.artist) — \(cluster.title)").fontWeight(.semibold)
                                Text("· \(cluster.memberIDs.count) copies · \(cluster.reason)")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("saves \(fmtBytes(cluster.reclaim))").foregroundStyle(.green)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func memberRow(cluster: Cluster, track t: Track) -> some View {
        let isKeeper = cluster.keeperID == t.id
        return HStack(spacing: 10) {
            Image(systemName: isKeeper ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isKeeper ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(isKeeper ? "KEEP" : "duplicate")
                    .font(.caption2).fontWeight(.bold)
                    .foregroundStyle(isKeeper ? .green : .orange)
                Text(t.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(t.formatLabel).font(.caption).monospaced()
            Text(fmtDur(t.duration)).font(.caption).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
            Text(fmtBytes(t.size)).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.setKeeper(clusterID: cluster.id, trackID: t.id) }
        .help("Click to keep this version")
    }

    // MARK: Library

    private var libraryView: some View {
        let tree = libraryTree()
        return List {
            ForEach(tree, id: \.artist) { a in
                DisclosureGroup {
                    ForEach(a.albums, id: \.album) { al in
                        DisclosureGroup {
                            ForEach(al.tracks, id: \.id) { t in
                                HStack {
                                    Text(t.trackNo > 0 ? String(format: "%02d", t.trackNo) : "  ")
                                        .font(.caption).monospaced().foregroundStyle(.secondary)
                                    Text(t.title).lineLimit(1)
                                    Spacer()
                                    Text("\(fmtDur(t.duration)) · \(t.formatLabel) · \(fmtBytes(t.size))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } label: {
                            Text("\(al.album)  (\(al.tracks.count))").fontWeight(.medium)
                        }
                    }
                } label: {
                    Text("\(a.artist)  ·  \(a.albums.count) album(s)").fontWeight(.semibold)
                }
            }
        }
        .listStyle(.inset)
        .frame(maxHeight: .infinity)
    }

    private struct AlbumNode { let album: String; let tracks: [Track] }
    private struct ArtistNode { let artist: String; let albums: [AlbumNode] }

    private func libraryTree() -> [ArtistNode] {
        var map: [String: [String: [Track]]] = [:]
        for t in store.tracks {
            let a = t.displayArtist.isEmpty ? "Unknown Artist" : t.displayArtist
            let al = t.album.isEmpty ? "Unknown Album" : t.album
            map[a, default: [:]][al, default: []].append(t)
        }
        return map.keys.sorted { $0.lowercased() < $1.lowercased() }.map { a in
            let albums = map[a]!.keys.sorted { $0.lowercased() < $1.lowercased() }.map { al in
                AlbumNode(album: al, tracks: map[a]![al]!.sorted {
                    ($0.discNo, $0.trackNo, $0.title.lowercased()) < ($1.discNo, $1.trackNo, $1.title.lowercased())
                })
            }
            return ArtistNode(artist: a, albums: albums)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(store.status).font(.callout).lineLimit(1).truncationMode(.middle)
            if store.busy { ProgressView(value: store.progress).frame(width: 160) }
            Spacer()
            Button { copyKeepers() } label: { Label("Copy keepers to…", systemImage: "square.and.arrow.up") }
                .disabled(store.tracks.isEmpty || store.busy)
            Button(role: .destructive) { deletePhase = .choose } label: {
                Label("Delete duplicates…", systemImage: "trash")
            }
            .disabled(store.clusters.isEmpty || store.busy)
        }
        .padding(10)
    }

    // MARK: Actions

    private func performDelete() {
        deletePhase = .none
        store.deleteDuplicates(mode: chosenMode)
    }

    private func copyKeepers() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.prompt = "Choose"; p.message = "Choose output folder (e.g. a mounted ROCK / NAS share)"
        if p.runModal() == .OK, let dest = p.url {
            captureRemountAddress(from: dest)   // keep the auto-reconnect address in sync
            store.copyKeepers(to: dest)
        }
    }
}

// MARK: - Progress dialog (copy / delete) with live log + Cancel

struct OperationSheet: View {
    @ObservedObject var store: DedupStore
    var body: some View {
        VStack(spacing: 12) {
            Text(store.opTitle).font(.headline)
            ProgressView(value: store.opTotal > 0 ? Double(store.opDone) / Double(store.opTotal) : 0)
            HStack {
                Text("\(store.opDone) / \(store.opTotal)")
                Spacer()
                Text("✓ \(store.opOK)    • \(store.opSkip)    ✗ \(store.opFail)").foregroundStyle(.secondary)
            }
            .font(.caption).monospaced()
            if !store.opNote.isEmpty {
                Text(store.opNote)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(store.opLog.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(6)
                }
                .frame(height: 240)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: store.opLog.count) { _ in
                    if !store.opLog.isEmpty { proxy.scrollTo(store.opLog.count - 1) }
                }
            }
            HStack {
                Spacer()
                if store.opFinished {
                    Button("Close") { store.closeOp() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .destructive) { store.requestCancel() }
                }
            }
        }
        .padding(16)
        .frame(width: 580)
        .interactiveDismissDisabled(!store.opFinished)
    }
}

// Fallback for older macOS without ContentUnavailableView
struct ContentUnavailableCompat: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.title3).foregroundStyle(.secondary)
            if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
