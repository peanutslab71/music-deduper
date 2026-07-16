//
//  ContentView.swift
//  MusicLibrarian
//
//  Wizard shell: Source → Review → Clean up → Copy.
//  Step views live in WizardUI.swift; scanning/copy logic in DedupStore.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var store = DedupStore()
    // the Perfect session is owned by the app (shared with the Library/Runs/Logs
    // windows) and injected here
    @EnvironmentObject private var perfect: PerfectStore
    @ObservedObject private var audio = AudioPreview.shared   // docked player bar visibility
    @State private var step: WizardStep = .library
    @State private var reviewTab = 0            // 0 duplicates · 1 library
    @State private var destFolder: URL? = nil

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

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .source:
            SourceStepView(store: store)
        case .review:
            ReviewStepView(store: store, reviewTab: $reviewTab)
        case .cleanup:
            CleanupStepView(store: store) { deletePhase = .choose }
        case .copy:
            CopyStepView(store: store, destFolder: $destFolder) { dest in
                Task { @MainActor in await guardedCopy(to: dest) }
            }
        case .browse:
            ServerFilesView(store: store)
        case .perfect:
            // Perfect v2 (the library-first carousel) is the shipping path; the
            // old 8-step wizard remains as a legacy escape hatch:
            //   defaults write com.local.musiclibrarian perfectV2 -bool NO
            if PerfectStore.perfectV2Enabled {
                PerfectV2View()
            } else {
                PerfectView(store: perfect)
            }
        case .library:
            LibraryBrowserView()
        }
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            StepBar(step: $step, hasScan: !store.tracks.isEmpty)
            Divider()

            stepContent

            if audio.playingURL != nil {
                Divider()
                PlayerBar()
            }
            Divider()
            footer
        }
        .frame(minWidth: 940, minHeight: 620)
        // Transfer is copy-out only — when the source scan finishes, go straight to
        // Copy (dedup/organise now happen in Perfect, not here).
        .onChange(of: store.busy) { busy in
            if !busy && step == .source && !store.tracks.isEmpty {
                step = .copy
            }
        }
        .onAppear(perform: resumeMidRunIfNeeded)
    }

    // On launch, if a Perfect session was left mid-run (cancelled/closed before
    // Apply), reopen that library and drop the user back into Perfect at the same
    // step — so an interrupted session flows on rather than starting from scratch.
    @State private var didResumeCheck = false
    private func resumeMidRunIfNeeded() {
        guard !didResumeCheck else { return }
        didResumeCheck = true
        guard perfect.root == nil, let url = PerfectStore.resumableLibrary() else { return }
        perfect.setRoot(url)     // loads the saved plan + restores the wizard step
        step = .perfect
    }

    private var withDeleteFlow: some View {
        chrome
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

    var body: some View {
        withDeleteFlow
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

    // MARK: Footer — slim status bar

    private var footer: some View {
        HStack(spacing: 12) {
            Text(store.status).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            if store.busy { ProgressView(value: store.progress).frame(width: 140) }
            Spacer()
            if !store.tracks.isEmpty {
                Text("\(store.artistCount) artists · \(store.tracks.count) tracks")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: Actions

    private func performDelete() {
        deletePhase = .none
        store.deleteDuplicates(mode: chosenMode)
    }

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
/// device's own Settings page calls (POST /1/getstate, /1/stopsoftware,
/// /1/restartsoftware). Used to gate copies: a mass copy into a ROCK share
/// while Roon Server is running can make it stop or hang, so the server
/// must be stopped first.
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
                if store.opStreamLimit > 0 && !store.opFinished {
                    Label("\(store.opActiveStreams) of \(store.opStreamLimit) streams",
                          systemImage: "arrow.triangle.branch")
                        .foregroundStyle(store.opActiveStreams > 0 ? Color.accentColor : Color.secondary)
                        .help("Files copying in parallel right now / current adaptive limit")
                }
                Spacer()
                Text("✓ \(store.opOK)    • \(store.opSkip)    ✗ \(store.opFail)").foregroundStyle(.secondary)
            }
            .font(.caption).monospaced()
            // fixed-height row so showing/clearing the note never resizes the
            // dialog (that resize was the flicker on runs of small files)
            Text(store.opNote.isEmpty ? " " : store.opNote)
                .font(.caption).monospacedDigit()
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, minHeight: 15, alignment: .leading)
                .lineLimit(1).truncationMode(.middle)
            // several files in a row failed — server is gone, run paused itself
            if store.opPaused {
                HStack(spacing: 10) {
                    Label("The server has stopped responding — copy paused.",
                          systemImage: "pause.circle.fill")
                        .foregroundStyle(.orange)
                        .fontWeight(.medium)
                    Spacer()
                    Button("Resume") { store.resumeCopy() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
            // copy paused on a differing file — decide before anything continues
            if let c = store.pendingConflict {
                ConflictPanel(conflict: c) { store.resolveConflict($0) }
            }
            // newest entry at the top — no scrolling needed to follow along
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(store.opLog.enumerated()).reversed(), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(6)
            }
            .frame(height: 240)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                if let start = store.opStartDate, store.opStreamLimit > 0, !store.opFinished {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(Self.statsLine(now: ctx.date, start: start,
                                            bytesDone: store.opBytesDone, bytesTotal: store.opBytesTotal,
                                            filesDone: store.opDone))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if store.opFinished {
                    if let log = store.lastRunLogURL {
                        Button("Open log") { NSWorkspace.shared.open(log) }
                    }
                    if !store.failedCopyIDs.isEmpty {
                        Button("Retry \(store.failedCopyIDs.count) failed") { store.retryFailedCopies() }
                    }
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

    private static let etaClock: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()

    private static func fmtClock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func statsLine(now: Date, start: Date, bytesDone: Int64, bytesTotal: Int64,
                          filesDone: Int) -> String {
        let elapsed = max(1, now.timeIntervalSince(start))
        var s = "⏱ \(fmtClock(elapsed))"
        guard bytesDone > 0, elapsed >= 3 else { return s + "  ·  estimating…" }
        let rate = Double(bytesDone) / elapsed
        s += "  ·  \(fmtBytes(Int64(rate)))/s"
        if filesDone > 0 {
            s += "  ·  avg \(String(format: "%.1f", elapsed / Double(filesDone)))s/file"
        }
        if bytesTotal > bytesDone {
            let left = Double(bytesTotal - bytesDone) / rate
            s += "  ·  ~\(fmtClock(left)) left  ·  finishes ≈ \(etaClock.string(from: now.addingTimeInterval(left)))"
        }
        return s
    }
}
