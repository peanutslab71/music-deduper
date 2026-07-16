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
import MDTagShim

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
    @Published var lines: [String] = []              // session log shown in the window
    @Published var deferred: [DeferredAlbum] = []    // Tier 2 — untouched, awaiting a verdict
    @Published var coverGaps: [CoverGap] = []        // albums missing artwork — fill by choice, never silently
    @Published var drmTracks: [String] = []          // protected (FairPlay) rels — info only, never touched

    /// An album with artwork gaps: no cover anywhere, or some tracks blank. The
    /// window offers the album's own best covers plus an on-demand online search;
    /// the chosen image fills ONLY the blank tracks (existing art is never
    /// replaced here — that's the review roll-up's job later).
    struct CoverGap: Identifiable {
        let dir: URL
        let art: AlbumArtContext
        var id: String { dir.path }
        var missingRels: [String] { art.rels.filter { art.relArt[$0] == nil } }
    }
    private var cancelled = false
    private var sessionID: String?

    /// An album whose identify pass proposed a SUBSTANTIVE name change: nothing was
    /// applied (every downstream fix was computed from the unaccepted names). The
    /// review roll-up shows the A/B lines; Accept writes the names then re-analyzes
    /// and applies the now-clean fix set, Keep leaves the album exactly as found.
    struct DeferredAlbum: Identifiable {
        let dir: URL
        let files: [URL]
        let fix: AlbumFix          // the identify fix, with its retained proposals
        var id: String { dir.path }
    }

    func cancel() { cancelled = true }

    func run(root: URL, store: PerfectStore) async {
        guard !running else { return }
        running = true; cancelled = false; lines = []; deferred = []; coverGaps = []; drmTracks = []
        PerfectStore.rememberRoot(root)   // so Runs/Logs list this library's runs
        // the user's persisted settings gate how much this run does (plan 6d):
        // Light/Standard/Thorough scopes merges + renames; the missing-tracks
        // toggle keeps a run offline-fast by skipping the release reconcile.
        let thoroughness = store.thoroughness
        let reconcileOnline = store.checkMissingTracks
        let session = UUID().uuidString
        sessionID = session
        defer { running = false; progress = ""; store.loadRuns() }

        // ---- Phase 1: normalize, reusing the choices confirmed in the Normalize
        // window (artist spellings, declined merges, compilation confirmations).
        progress = "Phase 1 — normalizing folders"
        let scanned = await Task.detached { PerfectStore.scanForNormalize(root: root) }.value
        let choices = Normalizer.ChoicesStore.load(root.path)
        let confirmedComps = Normalizer.compilationCandidates(scanned.tracks)
            .filter { !choices.declinedCompilations.contains($0.key) }
            .reduce(into: Set<String>()) { $0.formUnion($1.foldKeys) }
        // Light/Standard skip edition merges (Thorough-only, matching the wizard's
        // scoping) by declining every candidate for this run.
        var p1Declined = Set(choices.declinedMerges)
        if !thoroughness.doesMerges {
            p1Declined.formUnion(Organiser.albumMergeCandidates(scanned.tracks).map { $0.key })
        }
        let p1 = Normalizer.plan(scanned, canonicalArtistOverrides: choices.artistOverrides,
                                 declinedMerges: p1Declined,
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
            // Protected (FairPlay) tracks: listed for the manifest, never touched.
            drmTracks.append(contentsOf: album.files
                .filter { $0.pathExtension.lowercased() == "m4p" }
                .map { PerfectStore.rel($0, root) })
            let cached = AlbumReconcileStore.load(album.dir.path)
            let (fixes, art, reconcile) = await AlbumPerfect.analyze(root: root, files: album.files,
                                                                     reconciledMatch: cached,
                                                                     reconcileOnline: reconcileOnline)
            if let r = reconcile { AlbumReconcileStore.save(album.dir.path, r) }
            // Artwork gaps queue for a cover choice (6b): no cover anywhere, or some
            // tracks blank. Filling is a user pick, never silent.
            if !art.rels.isEmpty, art.ownCovers.isEmpty || art.rels.contains(where: { art.relArt[$0] == nil }) {
                coverGaps.append(CoverGap(dir: album.dir, art: art))
            }

            // Tier gating (v2 plan): a SUBSTANTIVE identify change means every
            // downstream fix was computed from the unaccepted names — defer the
            // WHOLE album to the review roll-up rather than auto-apply half of it.
            // VARIANT changes (word-subset or one-typo pairs) also defer: AcoustID
            // can return either form on different runs, so auto-applying them
            // oscillates A→B→A forever; a verdict settles them once.
            // Compilation flagging is Phase 1's confirm checklist, never silent.
            let verdictFix = fixes.first { f in
                if f.kind == .identify, f.applyable,
                   f.proposals.contains(where: {
                       $0.dominantNameKind == .substantive
                       || TrackProposal.nameVariant($0.curTitle, $0.newTitle)
                       || TrackProposal.nameVariant($0.curArtist, $0.newArtist)
                   }) { return true }
                return f.speculative && f.applyable   // e.g. a text-searched album name
            }
            if let vf = verdictFix {
                deferred.append(DeferredAlbum(dir: album.dir, files: album.files, fix: vf))
                continue
            }
            if await applyTierOne(fixes, root: root, session: session,
                                  name: album.dir.lastPathComponent,
                                  doesRenames: thoroughness.doesRenames) { applied += 1 } else { clean += 1 }
        }

        // ---- Final pass: re-file/merge on the CORRECTED tags, so a folder whose
        // album or album-artist the loop fixed moves to match. (Library-wide dedup
        // on final tags lands with the review roll-up increment.)
        if !cancelled {
            progress = "Final pass — organising on corrected tags"
            let rescan = await Task.detached { PerfectStore.scanForNormalize(root: root) }.value
            var p2Declined = Set(choices.declinedMerges)
            if !thoroughness.doesMerges {
                p2Declined.formUnion(Organiser.albumMergeCandidates(rescan.tracks).map { $0.key })
            }
            let p2 = Normalizer.plan(rescan, canonicalArtistOverrides: choices.artistOverrides,
                                     declinedMerges: p2Declined,
                                     confirmedCompilations: confirmedComps)
            if !p2.isEmpty {
                await PerfectStore.performLibraryOps(root: root, summary: "Perfect v2 — final organise",
                                                     tagWrites: p2.tagWrites, moves: p2.moves,
                                                     sessionID: session)
                lines.append("Final pass: \(p2.tagWrites.count) tag write(s), \(p2.moves.count) move(s)")
            }
            // Library-wide dedup on the FINAL tags: cross-folder copies that only
            // became duplicates after their album/artist was corrected (the batch's
            // step-0e capability, on the edition-folded cluster gate). Same
            // merge-of-best shape as the per-album engine.
            progress = "Final pass — removing cross-folder duplicates"
            let dd = await Task.detached { await PerfectV2Driver.libraryDedup(root: root) }.value
            if !dd.moves.isEmpty {
                await PerfectStore.performLibraryOps(root: root, summary: "Perfect v2 — duplicate removal",
                                                     tagWrites: dd.writes, moves: dd.moves,
                                                     artEmbeds: dd.embeds, sessionID: session)
                lines.append("Duplicates: \(dd.moves.count) removed across folders (best copies kept)")
            }
        } else {
            lines.append("Cancelled — applied runs stay undoable from Runs")
        }
        lines.append("Albums: \(applied) fixed · \(clean) already clean · \(deferred.count) deferred for review")
        ArtworkCache.shared.clear(); FoundArtCache.shared.clear()
    }

    /// Apply an album's Tier-1 fix set (one reversible run): enabled defaults
    /// honored, compilation flagging excluded (Phase-1 checklist), dependent
    /// renames dropped when the disc fix isn't applied. Returns false if the
    /// album needed nothing.
    private func applyTierOne(_ fixes: [AlbumFix], root: URL, session: String, name: String,
                              doesRenames: Bool = true) async -> Bool {
        let discOn = fixes.contains { $0.kind == .discOrder && $0.applyable && $0.enabled }
        let chosen = fixes.filter { f in
            f.applyable && f.enabled
            && f.kind != .compilation
            && (doesRenames || f.kind != .filename)   // Light keeps file names as they are
            && !(f.needsDiscOrder && !discOn)
        }
        guard !chosen.isEmpty else { return false }
        await PerfectStore.performLibraryOps(
            root: root, summary: "Perfect v2 — \(name)",
            tagWrites: chosen.flatMap { $0.tagWrites },
            moves: chosen.flatMap { $0.moves },
            artEmbeds: chosen.flatMap { $0.artEmbeds },
            performerAdds: chosen.flatMap { $0.performerAdds },
            sessionID: session)
        return true
    }

    /// Review verdict: ACCEPT the proposed names — write them (their own run in
    /// the same session), re-analyze the album so every dependent fix is computed
    /// from the now-real tags, and apply that clean fix set.
    func accept(_ d: DeferredAlbum, root: URL, store: PerfectStore) async {
        guard !running else { return }
        running = true
        defer { running = false; progress = ""; store.loadRuns() }
        let session = sessionID ?? UUID().uuidString
        sessionID = session
        progress = "Applying names — \(d.dir.lastPathComponent)"
        await PerfectStore.performLibraryOps(root: root,
                                             summary: "Perfect v2 — names for \(d.dir.lastPathComponent)",
                                             tagWrites: d.fix.tagWrites, moves: [],
                                             sessionID: session)
        progress = "Re-checking — \(d.dir.lastPathComponent)"
        let cached = AlbumReconcileStore.load(d.dir.path)
        // runIdentify: false — the verdict PINNED the names; a fresh identify pass
        // could propose different ones and leak into the dependent fixes.
        let (fixes, _, reconcile) = await AlbumPerfect.analyze(root: root, files: d.files,
                                                               reconciledMatch: cached,
                                                               runIdentify: false)
        if let r = reconcile { AlbumReconcileStore.save(d.dir.path, r) }
        // The user's verdict PINS the names: the re-analyze exists to compute the
        // dependent fixes from them, never to relitigate them — a fresh identify
        // pass can flip-flop (scoring shifts once the tag changes) and would
        // silently overwrite the decision made seconds earlier.
        _ = await applyTierOne(fixes.filter { $0.kind != .identify },
                               root: root, session: session, name: d.dir.lastPathComponent)
        deferred.removeAll { $0.id == d.id }
        lines.append("Accepted names — \(d.dir.lastPathComponent)")
        ArtworkCache.shared.clear(); FoundArtCache.shared.clear()
    }

    /// Review verdict: KEEP the album exactly as analyze found it — nothing was
    /// applied for it, so declining is simply dropping it from the queue.
    func keep(_ d: DeferredAlbum) {
        deferred.removeAll { $0.id == d.id }
        lines.append("Kept as-is — \(d.dir.lastPathComponent)")
    }

    /// Fill an album's artwork gaps with the chosen image — blank tracks only;
    /// existing art is never replaced here. One undoable run in the session.
    func applyCover(_ gap: CoverGap, image: Data, root: URL, store: PerfectStore) async {
        guard !running else { return }
        running = true
        defer { running = false; progress = ""; store.loadRuns() }
        let session = sessionID ?? UUID().uuidString
        sessionID = session
        progress = "Setting cover — \(gap.dir.lastPathComponent)"
        let mime = image.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
        let targets = gap.missingRels.isEmpty ? gap.art.rels : gap.missingRels
        await PerfectStore.performLibraryOps(root: root,
                                             summary: "Perfect v2 — cover for \(gap.dir.lastPathComponent)",
                                             tagWrites: [], moves: [],
                                             artEmbeds: targets.map { ($0, image, mime) },
                                             sessionID: session)
        coverGaps.removeAll { $0.id == gap.id }
        lines.append("Cover set on \(targets.count) track\(targets.count == 1 ? "" : "s") — \(gap.dir.lastPathComponent)")
        ArtworkCache.shared.clear(); FoundArtCache.shared.clear()
    }

    func skipCover(_ gap: CoverGap) {
        coverGaps.removeAll { $0.id == gap.id }
        lines.append("Left without cover — \(gap.dir.lastPathComponent)")
    }

    /// Cross-folder duplicate sweep over the whole library's FINAL tags. Returns
    /// the merge-of-best backfill (keeper's blank fields + missing cover filled
    /// from the losers) and the losers' quarantine moves — all applied as one
    /// reversible run by the caller.
    nonisolated static func libraryDedup(root: URL) async
        -> (writes: [(rel: String, field: String, value: String)],
            embeds: [(rel: String, image: Data, mime: String)],
            moves: [(from: String, to: String)]) {
        var tracks = await PerfectStore.buildTracksFromDisk(root: root, fm: .default)
        let clusters = buildClusters(&tracks, mode: .balanced, tol: 2.0, crossAlbum: false)
        var writes: [(rel: String, field: String, value: String)] = []
        var embeds: [(rel: String, image: Data, mime: String)] = []
        var moves: [(from: String, to: String)] = []
        let backfill = ["title", "artist", "album", "albumartist", "composer",
                        "lyricist", "label", "conductor", "date", "track", "disc"]
        for c in clusters where c.memberIDs.count > 1 {
            // Legitimate repeat appearances — the same recording on its studio album
            // AND on a greatest-hits/compilation — are NEVER auto-removed (plan §E:
            // "move aside for review, never auto-delete"; the by-ear review surface
            // will offer them). Only clusters whose members agree on the edition-
            // folded ALBUM are true stray copies.
            let albums = Set(c.memberIDs.map { Organiser.canonicalAlbumKey(tracks[$0].album) })
            guard albums.count == 1 else { continue }
            let keeper = tracks[c.keeperID]
            let keeperRel = PerfectStore.rel(keeper.url, root)
            for field in backfill where (PerfectStore.readField(keeper.url, field) ?? "").isEmpty {
                for id in c.memberIDs where id != c.keeperID {
                    let v = PerfectStore.readField(tracks[id].url, field) ?? ""
                    if !v.isEmpty { writes.append((keeperRel, field, v)); break }
                }
            }
            if md_has_artwork(keeper.url.path) == 0 {
                for id in c.memberIDs where id != c.keeperID {
                    var len: Int32 = 0, ty: Int32 = 0
                    if let b = md_copy_artwork(tracks[id].url.path, &len, &ty) {
                        let d = Data(bytes: b, count: Int(len)); free(b)
                        embeds.append((keeperRel, d,
                                       d.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"))
                        break
                    }
                }
            }
            for id in c.memberIDs where id != c.keeperID {
                moves.append((PerfectStore.rel(tracks[id].url, root), ""))
            }
        }
        return (writes, embeds, moves)
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
                if !driver.deferred.isEmpty {
                    Section("Names to confirm — these albums are untouched until you decide") {
                        ForEach(driver.deferred) { d in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(d.dir.lastPathComponent).fontWeight(.medium)
                                    Text(d.fix.summary).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Accept names") {
                                        if let root { Task { await driver.accept(d, root: root, store: perfect) } }
                                    }
                                    .controlSize(.small).disabled(driver.running || root == nil)
                                    Button("Keep as-is") { driver.keep(d) }
                                        .controlSize(.small).disabled(driver.running)
                                }
                                ForEach(Array(d.fix.lines.enumerated()), id: \.offset) { _, line in
                                    Text(line).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                if !driver.coverGaps.isEmpty {
                    Section("Covers to fill — albums missing artwork (blank tracks only; nothing is replaced)") {
                        ForEach(driver.coverGaps) { gap in
                            CoverGapRow(gap: gap, driver: driver, root: root, store: perfect)
                        }
                    }
                }
                if !driver.drmTracks.isEmpty {
                    Section("Protected (DRM) — listed only, never touched") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(driver.drmTracks.count) FairPlay-protected track(s). Most players (including Roon) can't play these; they can't be fingerprinted or re-tagged. Legitimate routes: re-download from your Apple purchase history, match via an Apple Music subscription, or re-rip from CD.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("Export list (CSV)…") { exportDRMList() }.controlSize(.small)
                                Spacer()
                            }
                            ForEach(driver.drmTracks.prefix(12), id: \.self) { Text($0).font(.caption2).foregroundStyle(.tertiary) }
                            if driver.drmTracks.count > 12 {
                                Text("… and \(driver.drmTracks.count - 12) more (export for the full list)")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
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

    /// The DRM manifest: one row per protected track (artist/album/title come from
    /// the Artist/Album/NN Title path shape), openable in Numbers/Excel.
    private func exportDRMList() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "protected-tracks.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var csv = "artist,album,file\n"
        for rel in driver.drmTracks {
            let parts = rel.split(separator: "/").map(String.init)
            let artist = parts.count >= 3 ? parts[parts.count - 3] : ""
            let album = parts.count >= 2 ? parts[parts.count - 2] : ""
            let esc = { (s: String) in "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            csv += "\(esc(artist)),\(esc(album)),\(esc(parts.last ?? rel))\n"
        }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// One artwork-gap row: artist — album, how many tracks are blank, the album's
/// own covers plus on-demand online candidates, and a pick-to-fill flow.
struct CoverGapRow: View {
    let gap: PerfectV2Driver.CoverGap
    @ObservedObject var driver: PerfectV2Driver
    let root: URL?
    let store: PerfectStore
    @State private var online: [Data] = []
    @State private var searching = false
    @State private var searched = false
    @State private var selected: Data?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(gap.art.artist.isEmpty ? gap.dir.deletingLastPathComponent().lastPathComponent : gap.art.artist) — \(gap.art.album.isEmpty ? gap.dir.lastPathComponent : gap.art.album)")
                        .fontWeight(.medium)
                    Text(gap.missingRels.isEmpty
                         ? "no cover on any track"
                         : "\(gap.missingRels.count) of \(gap.art.rels.count) track(s) without art")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let selected {
                    Button("Use this cover") {
                        if let root { Task { await driver.applyCover(gap, image: selected, root: root, store: store) } }
                    }
                    .buttonStyle(.borderedProminent).tint(.teal)
                    .controlSize(.small).disabled(driver.running || root == nil)
                }
                Button("Skip") { driver.skipCover(gap) }.controlSize(.small).disabled(driver.running)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(gap.art.ownCovers.enumerated()), id: \.offset) { _, data in
                        CoverThumb(data: data, selected: selected == data, badge: "in files")
                            .onTapGesture { selected = data }
                    }
                    ForEach(Array(online.enumerated()), id: \.offset) { _, data in
                        CoverThumb(data: data, selected: selected == data, badge: "online")
                            .onTapGesture { selected = data }
                    }
                    if !searched {
                        Button {
                            searching = true
                            Task {
                                let found = await CoverArtClient().candidates(releaseMBIDs: [],
                                                                              artist: gap.art.artist,
                                                                              album: gap.art.album)
                                await MainActor.run { online = found; searching = false; searched = true }
                            }
                        } label: {
                            if searching { ProgressView().controlSize(.small) }
                            else { Label("Find covers online", systemImage: "magnifyingglass") }
                        }
                        .controlSize(.small).disabled(searching)
                    } else if online.isEmpty {
                        Text("nothing found online").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
