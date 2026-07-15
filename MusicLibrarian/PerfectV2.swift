//
//  PerfectV2.swift — the Perfect v2 driver (behind the "perfectV2" flag).
//
//  The thin replacement for the batch wizard pipeline: Phase-1 normalize (with
//  the user's saved Normalize choices) → the proven per-album engine
//  (AlbumPerfect.analyze) over every folder → a final organise pass on the
//  corrected tags. Every apply is one reversible run stamped with the session's
//  ID, so Runs offers "Revert session" back to the pre-run library.
//
//  Enable with:  defaults write com.local.musiclibrarian perfectV2 -bool YES
//  (hidden while the old wizard remains the shipping path — plan step 7 flips it).
//

import SwiftUI

extension PerfectStore {
    /// The v2 rollout flag (plan step 5/7). Hidden: set via `defaults write`.
    static var perfectV2Enabled: Bool { UserDefaults.standard.bool(forKey: "perfectV2") }
}

/// Drives one Perfect v2 session over a library. Owned by the v2 window; all the
/// disk work runs off-main, one album at a time, cancellable between albums.
@MainActor
final class PerfectV2Driver: ObservableObject {
    @Published var running = false
    @Published var progress = ""
    @Published var lines: [String] = []            // session log shown in the window
    @Published var deferredAlbums: [String] = []   // queued for review (Tier 2) — untouched
    private var cancelled = false

    func cancel() { cancelled = true }

    func run(root: URL, store: PerfectStore) async {
        guard !running else { return }
        running = true; cancelled = false; lines = []; deferredAlbums = []
        let session = UUID().uuidString
        defer { running = false; progress = ""; store.loadRuns() }

        // ---- Phase 1: normalize, reusing the choices confirmed in the Normalize
        // window (artist spellings, declined merges, compilation confirmations).
        progress = "Phase 1 — normalizing folders"
        let scanned = await Task.detached { PerfectStore.scanForNormalize(root: root) }.value
        let choices = Normalizer.ChoicesStore.load(root.path)
        let confirmedComps = Normalizer.compilationCandidates(scanned.tracks)
            .filter { !choices.declinedCompilations.contains($0.key) }
            .reduce(into: Set<String>()) { $0.formUnion($1.foldKeys) }
        let p1 = Normalizer.plan(scanned, canonicalArtistOverrides: choices.artistOverrides,
                                 declinedMerges: Set(choices.declinedMerges),
                                 confirmedCompilations: confirmedComps)
        if !p1.isEmpty {
            await PerfectStore.performLibraryOps(root: root, summary: "Perfect v2 — Phase 1 normalize",
                                                 tagWrites: p1.tagWrites, moves: p1.moves,
                                                 sessionID: session)
            lines.append("Phase 1: \(p1.tagWrites.count) tag write(s), \(p1.moves.count) move(s)")
        } else {
            lines.append("Phase 1: nothing to normalize")
        }
        guard !cancelled else { lines.append("Cancelled — applied runs stay undoable from Runs"); return }

        // ---- Per-album loop over the normalized tree: the same engine as
        // "Perfect this album", one reversible run per album.
        let albums = await Task.detached { PerfectV2Driver.albumFolders(root: root) }.value
        var applied = 0, clean = 0
        for (idx, album) in albums.enumerated() {
            if cancelled { break }
            progress = "Album \(idx + 1) of \(albums.count) — \(album.dir.lastPathComponent)"
            let cached = AlbumReconcileStore.load(album.dir.path)
            let (fixes, _, reconcile) = await AlbumPerfect.analyze(root: root, files: album.files,
                                                                   reconciledMatch: cached)
            if let r = reconcile { AlbumReconcileStore.save(album.dir.path, r) }

            // Tier gating (v2 plan): an identify change means every downstream fix
            // was computed from the identified names — defer the WHOLE album to the
            // review roll-up (next increment) rather than auto-apply half of it.
            // Compilation flagging is Phase 1's confirm checklist, never silent.
            if fixes.contains(where: { $0.kind == .identify && $0.applyable }) {
                deferredAlbums.append(album.dir.lastPathComponent)
                continue
            }
            let discOn = fixes.contains { $0.kind == .discOrder && $0.applyable && $0.enabled }
            let chosen = fixes.filter { f in
                f.applyable && f.enabled                    // enabled defaults honored —
                && f.kind != .compilation                   // ambiguous splits stay queued
                && !(f.needsDiscOrder && !discOn)
            }
            guard !chosen.isEmpty else { clean += 1; continue }
            await PerfectStore.performLibraryOps(
                root: root, summary: "Perfect v2 — \(album.dir.lastPathComponent)",
                tagWrites: chosen.flatMap { $0.tagWrites },
                moves: chosen.flatMap { $0.moves },
                performerAdds: chosen.flatMap { $0.performerAdds },
                sessionID: session)
            applied += 1
        }

        // ---- Final pass: re-file/merge on the CORRECTED tags, so a folder whose
        // album or album-artist the loop fixed moves to match. (Library-wide dedup
        // on final tags lands with the review roll-up increment.)
        if !cancelled {
            progress = "Final pass — organising on corrected tags"
            let rescan = await Task.detached { PerfectStore.scanForNormalize(root: root) }.value
            let p2 = Normalizer.plan(rescan, canonicalArtistOverrides: choices.artistOverrides,
                                     declinedMerges: Set(choices.declinedMerges),
                                     confirmedCompilations: confirmedComps)
            if !p2.isEmpty {
                await PerfectStore.performLibraryOps(root: root, summary: "Perfect v2 — final organise",
                                                     tagWrites: p2.tagWrites, moves: p2.moves,
                                                     sessionID: session)
                lines.append("Final pass: \(p2.tagWrites.count) tag write(s), \(p2.moves.count) move(s)")
            }
        } else {
            lines.append("Cancelled — applied runs stay undoable from Runs")
        }
        lines.append("Albums: \(applied) fixed · \(clean) already clean · \(deferredAlbums.count) deferred for review")
        ArtworkCache.shared.clear(); FoundArtCache.shared.clear()
    }

    /// One album folder = one directory that directly contains audio files.
    struct AlbumFolder { let dir: URL; let files: [URL] }
    nonisolated static func albumFolders(root: URL) -> [AlbumFolder] {
        let inputs = PerfectStore.organiseInputsFromDisk(root: root, fm: .default)
        var byDir: [String: [URL]] = [:]
        for t in inputs {
            let dirRel = (t.rel as NSString).deletingLastPathComponent
            byDir[dirRel, default: []].append(root.appendingPathComponent(t.rel))
        }
        return byDir.keys.sorted().map {
            AlbumFolder(dir: root.appendingPathComponent($0),
                        files: byDir[$0]!.sorted { $0.path < $1.path })
        }
    }
}

/// The v2 window: pick a library, run the driver, watch progress, see what was
/// deferred for review. Everything applied is session-stamped — one click in
/// Runs ("Revert session") restores the pre-run library.
struct PerfectV2View: View {
    @EnvironmentObject private var perfect: PerfectStore
    @StateObject private var driver = PerfectV2Driver()
    @State private var root: URL? = UserDefaults.standard.string(forKey: "libraryBrowserRoot")
        .map { URL(fileURLWithPath: $0) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text("Perfect v2").font(.headline)
                if let root { Text(root.lastPathComponent).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Choose Library…") { choose() }.disabled(driver.running)
                if driver.running {
                    Button("Cancel") { driver.cancel() }
                } else {
                    Button("Run") { if let root { Task { await driver.run(root: root, store: perfect) } } }
                        .buttonStyle(.borderedProminent).tint(.purple)
                        .disabled(root == nil)
                }
            }
            .padding(10)
            Divider()
            if driver.running {
                ProgressView(driver.progress).padding(10)
            }
            List {
                if !driver.lines.isEmpty {
                    Section("Session") { ForEach(driver.lines, id: \.self) { Text($0).font(.caption) } }
                }
                if !driver.deferredAlbums.isEmpty {
                    Section("Deferred for review — name changes need your OK (untouched)") {
                        ForEach(driver.deferredAlbums, id: \.self) { Text($0).font(.caption) }
                    }
                }
                if driver.lines.isEmpty && !driver.running {
                    Text("Runs Phase-1 normalize (using your saved Normalize choices), then the per-album engine over every folder, then a final organise on the corrected tags. Each album is one undoable run; the whole session reverts from Runs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = "Use Library"
        if panel.runModal() == .OK { root = panel.url }
    }
}
