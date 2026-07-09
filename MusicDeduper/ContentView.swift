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

    // ROCK copy gate — copying into a ROCK share while Roon Server runs can
    // hang it, so the copy is blocked until the server is stopped. No bypass.
    struct RockPrompt: Identifiable { let id = UUID(); let host: String; let dest: URL }
    @State private var rockPrompt: RockPrompt? = nil
    @State private var rockUnverified: RockPrompt? = nil       // host didn't answer — user must decide
    @State private var rockStopFailedHost: String? = nil
    @State private var rockRestartHost: String? = nil          // offer to start again after the copy
    @State private var restartHostAfterCopy: String? = nil     // we stopped it for this copy

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
        // ROCK gate: Roon Server MUST be stopped before copying into a ROCK share
        .alert("Roon Server is running",
               isPresented: Binding(get: { rockPrompt != nil },
                                    set: { if !$0 { rockPrompt = nil } }),
               presenting: rockPrompt) { p in
            Button("Stop Roon Server, then copy") { stopRoonThenCopy(p) }
            Button("Cancel", role: .cancel) { rockPrompt = nil }
        } message: { p in
            Text("The destination is a Roon ROCK server (\(p.host)) and Roon Server is running. Copying while it runs can cause it to stop or hang, so it must be stopped first. The app can stop it now and will offer to start it again when the copy finishes.")
        }
        .alert("Couldn't verify the destination",
               isPresented: Binding(get: { rockUnverified != nil },
                                    set: { if !$0 { rockUnverified = nil } }),
               presenting: rockUnverified) { p in
            Button("Check again") {
                let dest = p.dest
                rockUnverified = nil
                Task { @MainActor in await guardedCopy(to: dest) }
            }
            Button("It's not a ROCK — copy") {
                let dest = p.dest
                rockUnverified = nil
                store.copyKeepers(to: dest)
            }
            Button("Cancel", role: .cancel) { rockUnverified = nil }
        } message: { p in
            Text("\(p.host) didn't answer the ROCK admin check. If this destination IS a Roon ROCK, do not copy until Roon Server is stopped. If the Local Network permission was just granted (or is off in System Settings → Privacy & Security), fix that and choose Check again. Only continue if you're sure this is not a ROCK.")
        }
        .alert("Couldn't stop Roon Server",
               isPresented: Binding(get: { rockStopFailedHost != nil },
                                    set: { if !$0 { rockStopFailedHost = nil } }),
               presenting: rockStopFailedHost) { host in
            Button("Open ROCK settings page") {
                if let u = URL(string: "http://\(host)/") { NSWorkspace.shared.open(u) }
            }
            Button("OK", role: .cancel) { }
        } message: { host in
            Text("The ROCK at \(host) did not report Roon Server as stopped. Stop it manually from its settings page, then start the copy again.")
        }
        .alert("Start Roon Server again?",
               isPresented: Binding(get: { rockRestartHost != nil },
                                    set: { if !$0 { rockRestartHost = nil } }),
               presenting: rockRestartHost) { host in
            Button("Start Roon Server") { startRoonAgain(host) }
            Button("Not now", role: .cancel) { }
        } message: { host in
            Text("The copy has finished. Roon Server on \(host) was stopped for the copy — start it again now so it can import the new files?")
        }
        .onChange(of: store.opActive) { active in
            // when the copy's progress sheet closes, offer to restart the server we stopped
            if !active, let h = restartHostAfterCopy { restartHostAfterCopy = nil; rockRestartHost = h }
        }
        .task {
            // Surface the one-time macOS Local Network permission prompt at
            // launch (harmless read-only status call) rather than mid-copy.
            if let u = URL(string: store.smbAddress), let h = u.host {
                _ = await RockGuard.getState(host: h)
            }
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
            Task { @MainActor in await guardedCopy(to: dest) }
        }
    }

    /// If the destination is a ROCK with Roon Server running, block the copy
    /// until the server is stopped (no bypass). Anything that isn't a ROCK —
    /// local folder, plain NAS, no answer on the admin port — copies as before.
    /// The copy NEVER starts until the ROCK check has definitively answered.
    /// Retries ride out the one-time macOS Local Network permission dialog;
    /// if the host still can't be verified, the user must explicitly assert
    /// it isn't a ROCK before anything is copied.
    @MainActor private func guardedCopy(to dest: URL) async {
        guard let host = RockGuard.hostForDestination(dest, smbAddress: store.smbAddress) else {
            store.copyKeepers(to: dest)     // purely local destination
            return
        }
        store.status = "Checking \(host) for a running Roon Server… (allow Local Network access if macOS asks)"
        let state = await RockGuard.getStateWithRetry(host: host)
        store.status = ""
        switch state {
        case .some(let s) where s.isRock && s.roonRunning:
            rockPrompt = RockPrompt(host: host, dest: dest)
        case .some(let s) where s.isRock:
            store.status = "ROCK at \(host): Roon Server already stopped — copying."
            store.copyKeepers(to: dest)
        case .some:
            store.status = "\(host) is not a ROCK — copying."
            store.copyKeepers(to: dest)
        case .none:
            // Unverifiable network host — do NOT copy until the user decides.
            rockUnverified = RockPrompt(host: host, dest: dest)
        }
    }

    private func stopRoonThenCopy(_ p: RockPrompt) {
        rockPrompt = nil
        Task { @MainActor in
            store.status = "Stopping Roon Server on \(p.host)…"
            let stopped = await RockGuard.stopRoon(host: p.host)
            store.status = ""
            if stopped {
                restartHostAfterCopy = p.host
                store.copyKeepers(to: p.dest)
            } else {
                rockStopFailedHost = p.host
            }
        }
    }

    private func startRoonAgain(_ host: String) {
        Task { @MainActor in
            store.status = await RockGuard.startRoon(host: host)
                ? "Roon Server starting on \(host)."
                : "Couldn't reach \(host) — start Roon Server from its settings page."
        }
    }
}

// MARK: - ROCK admin API client

/// Minimal client for the Roon ROCK web-admin API — the same endpoints the
/// device's own Settings page calls (POST /1/getstate, /1/stop, /1/restart).
/// Used to gate copies: a mass copy into a ROCK share while Roon Server is
/// running can make it stop or hang, so the server must be stopped first.
enum RockGuard {
    struct State { let isRock: Bool; let roonRunning: Bool; let model: String }

    /// Host to probe for a given copy destination: the smb:// remount host of
    /// the destination's volume. Falls back to the reconnect-target address
    /// only for network volumes (never probes for purely local destinations).
    static func hostForDestination(_ dest: URL, smbAddress: String) -> String? {
        if let vals = try? dest.resourceValues(forKeys: [.volumeURLForRemountingKey]),
           let remount = vals.volumeURLForRemounting, let h = remount.host {
            return h
        }
        if dest.path.hasPrefix("/Volumes/"),
           let u = URL(string: smbAddress), let h = u.host {
            return h
        }
        return nil
    }

    static func getState(host: String) async -> State? {
        guard let data = await post(host: host, path: "1/getstate", timeout: 2.5),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["status"] as? String) == "Success",
              let d = obj["data"] as? [String: Any] else { return nil }
        let vendor = d["device_vendor"] as? String ?? ""
        let model = d["device_model"] as? String ?? ""
        let st = d["state"] as? [String: Any]
        // the API reports 1/0, not true/false — go via NSNumber to be safe
        let running = (st?["roon_running"] as? NSNumber)?.boolValue ?? false
        let isRock = vendor.localizedCaseInsensitiveContains("roon")
                  || model.localizedCaseInsensitiveContains("core kit")
        return State(isRock: isRock, roonRunning: running, model: model)
    }

    /// Ask the ROCK to stop Roon Server, then poll until it reports stopped.
    /// Returns false if the stop wasn't confirmed within ~30 seconds.
    /// (Roon Server's endpoints are 1/stopsoftware & 1/restartsoftware —
    /// the softwaretype is the empty string; "vendor" is the OS layer.)
    static func stopRoon(host: String) async -> Bool {
        guard await post(host: host, path: "1/stopsoftware", timeout: 10) != nil else { return false }
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let s = await getState(host: host), !s.roonRunning { return true }
        }
        return false
    }

    static func startRoon(host: String) async -> Bool {
        await post(host: host, path: "1/restartsoftware", timeout: 10) != nil
    }

    /// getState with retries — rides out the one-time macOS Local Network
    /// permission dialog instead of timing out past it on first run.
    static func getStateWithRetry(host: String, attempts: Int = 4) async -> State? {
        for i in 0..<attempts {
            if let s = await getState(host: host) { return s }
            if i < attempts - 1 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        }
        return nil
    }

    private static func post(host: String, path: String, timeout: TimeInterval) async -> Data? {
        guard let url = URL(string: "http://\(host)/\(path)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
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
