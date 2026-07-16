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
    @Published var earChoices: [EarChoice] = []      // same recording, two albums — you pick by ear

    /// A by-ear verdict: keep A, keep B, or (the recommended legitimate-repeat
    /// default) keep both. Applied with the decisions batch; "keep both" persists
    /// so the pair never re-offers.
    struct EarChoice: Identifiable {
        let pair: EarPair
        var verdict: Verdict
        enum Verdict { case keepA, keepB, keepBoth }
        var id: String { pair.id }
    }

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

    /// One track's pending name decision (approved mockup: verdicts are PER TRACK).
    /// The default flips with confidence: a high-score, non-variant proposal
    /// pre-selects Accept; a risky one pre-selects Keep.
    struct TrackDecision: Identifiable {
        var proposal: TrackProposal
        var accept: Bool
        var id: String { proposal.relPath }
        var risky: Bool {
            proposal.score < 0.75
            || TrackProposal.nameVariant(proposal.curTitle, proposal.newTitle)
            || TrackProposal.nameVariant(proposal.curArtist, proposal.newArtist)
        }
    }

    /// An album deferred for verdicts: nothing was applied (every downstream fix
    /// was computed from the unaccepted names). Deciding is instant and offline;
    /// "Apply all decisions" writes the accepted names per album, re-analyzes with
    /// identify pinned off, and applies the now-clean fix set. Kept proposals are
    /// remembered per album so they never re-queue.
    struct DeferredAlbum: Identifiable {
        let dir: URL
        let files: [URL]
        var decisions: [TrackDecision] = []
        var albumSuggestion: AlbumFix? = nil   // speculative album-name guess (6a)
        var acceptAlbum = false                // a guess defaults to NOT accepted
        var id: String { dir.path }
        var artist: String { dir.deletingLastPathComponent().lastPathComponent }
        var album: String { dir.lastPathComponent }
    }

    func cancel() { cancelled = true }

    func run(root: URL, store: PerfectStore) async {
        guard !running else { return }
        running = true; cancelled = false; lines = []; deferred = []; coverGaps = []; drmTracks = []; earChoices = []
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
            var tierFixes = fixes
            let kept = KeptNamesStore.load(album.dir.path)
            var decisions: [TrackDecision] = []
            if let i = tierFixes.firstIndex(where: { $0.kind == .identify && $0.applyable }) {
                var f = tierFixes[i]
                // proposals the user KEPT on a previous run never re-queue and never
                // auto-apply — drop them and their writes
                let dropRels = Set(f.proposals.filter { kept.contains(KeptNamesStore.pairKey($0)) }.map { $0.relPath })
                if !dropRels.isEmpty {
                    f.proposals.removeAll { dropRels.contains($0.relPath) }
                    f.tagWrites.removeAll { dropRels.contains($0.rel) && ($0.field == "title" || $0.field == "artist") }
                    tierFixes[i] = f
                }
                let needing = f.proposals.filter {
                    $0.dominantNameKind == .substantive
                    || TrackProposal.nameVariant($0.curTitle, $0.newTitle)
                    || TrackProposal.nameVariant($0.curArtist, $0.newArtist)
                }
                decisions = needing.map { p in
                    var d = TrackDecision(proposal: p, accept: false)
                    d.accept = !d.risky
                    return d
                }
            }
            let suggestion = tierFixes.first { f in
                guard f.speculative, f.applyable, let v = f.tagWrites.first?.value else { return false }
                return !kept.contains("album>" + Organiser.fold(v))   // kept guesses stay gone
            }
            if !decisions.isEmpty || suggestion != nil {
                deferred.append(DeferredAlbum(dir: album.dir, files: album.files,
                                              decisions: decisions, albumSuggestion: suggestion))
                continue
            }
            if await applyTierOne(tierFixes, root: root, session: session,
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
            // Cross-album same-recording pairs → by-ear verdicts (Keep both is the
            // recommended default: a track on its album AND a hits set is legitimate).
            let earKept = KeptNamesStore.load(root.path + "#ear")
            earChoices = dd.earPairs
                .filter { !earKept.contains("ear>" + $0.id) }
                .map { EarChoice(pair: $0, verdict: .keepBoth) }
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

    /// Decide in batch, apply in batch (approved mockup): ticks are instant and
    /// offline; this runs the whole queue — per album: write the ACCEPTED names,
    /// re-analyze with identify pinned off (the verdict is ground truth; a fresh
    /// pass could flip and leak into dependent fixes), apply the now-clean fix
    /// set; remember every KEPT proposal so it never re-queues. One undoable run
    /// per album, all in the session.
    func applyDecisions(root: URL, store: PerfectStore) async {
        guard !running, !deferred.isEmpty || !earChoices.isEmpty else { return }
        running = true
        defer { running = false; progress = ""; store.loadRuns() }
        let session = sessionID ?? UUID().uuidString
        sessionID = session
        let queue = deferred
        let doesRenames = store.thoroughness.doesRenames
        for (n, d) in queue.enumerated() {
            progress = "Applying decisions — album \(n + 1) of \(queue.count): \(d.album)"
            var writes: [(rel: String, field: String, value: String)] = []
            var keptKeys: [String] = []
            for t in d.decisions {
                let p = t.proposal
                if t.accept {
                    if !p.newTitle.isEmpty, p.newTitle != p.curTitle { writes.append((p.relPath, "title", p.newTitle)) }
                    if !p.newArtist.isEmpty, p.newArtist != p.curArtist { writes.append((p.relPath, "artist", p.newArtist)) }
                } else {
                    keptKeys.append(KeptNamesStore.pairKey(p))
                }
            }
            if let s = d.albumSuggestion {
                if d.acceptAlbum { writes.append(contentsOf: s.tagWrites) }
                else if let v = s.tagWrites.first?.value { keptKeys.append("album>" + Organiser.fold(v)) }
            }
            if !keptKeys.isEmpty { KeptNamesStore.add(d.dir.path, keptKeys) }
            if !writes.isEmpty {
                await PerfectStore.performLibraryOps(root: root, summary: "Perfect v2 — names for \(d.album)",
                                                     tagWrites: writes, moves: [], sessionID: session)
            }
            let cached = AlbumReconcileStore.load(d.dir.path)
            let (fixes, _, reconcile) = await AlbumPerfect.analyze(root: root, files: d.files,
                                                                   reconciledMatch: cached,
                                                                   runIdentify: false)
            if let r = reconcile { AlbumReconcileStore.save(d.dir.path, r) }
            _ = await applyTierOne(fixes, root: root, session: session, name: d.album,
                                   doesRenames: doesRenames)
            deferred.removeAll { $0.id == d.id }
            lines.append("Decisions applied — \(d.artist) — \(d.album)")
        }
        // by-ear duplicate verdicts: keep-A/keep-B quarantine the loser in one
        // undoable run; keep-both persists so the pair never re-offers
        if !earChoices.isEmpty {
            var quarantines: [(from: String, to: String)] = []
            var keptEar: [String] = []
            for c in earChoices {
                switch c.verdict {
                case .keepA: quarantines.append((c.pair.bRel, ""))
                case .keepB: quarantines.append((c.pair.aRel, ""))
                case .keepBoth: keptEar.append("ear>" + c.pair.id)
                }
            }
            if !keptEar.isEmpty { KeptNamesStore.add(root.path + "#ear", keptEar) }
            if !quarantines.isEmpty {
                progress = "Applying duplicate decisions"
                await PerfectStore.performLibraryOps(root: root, summary: "Perfect v2 — duplicate decisions",
                                                     tagWrites: [], moves: quarantines, sessionID: session)
                lines.append("Duplicates: \(quarantines.count) resolved by ear")
            }
            earChoices = []
        }
        ArtworkCache.shared.clear(); FoundArtCache.shared.clear()
    }


    /// Fill an album's artwork gaps with the chosen image — blank tracks only;
    /// existing art is never replaced here. One undoable run in the session.
    /// Targets are REMAPPED before writing: the session's later passes may have
    /// renamed/moved files after the gap was captured, and a stale rel would
    /// silently no-op (the Some Old Bullshit miss) — a missing rel is re-resolved
    /// by filename inside the album folder, or dropped with a message.
    func applyCover(_ gap: CoverGap, image: Data, root: URL, store: PerfectStore) async {
        guard !running else { return }
        running = true
        defer { running = false; progress = ""; store.loadRuns() }
        let session = sessionID ?? UUID().uuidString
        sessionID = session
        progress = "Setting cover — \(gap.dir.lastPathComponent)"
        let mime = image.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
        let fm = FileManager.default
        let captured = gap.missingRels.isEmpty ? gap.art.rels : gap.missingRels
        var targets: [String] = []
        var lost = 0
        for rel in captured {
            if fm.fileExists(atPath: root.appendingPathComponent(rel).path) { targets.append(rel); continue }
            // moved since capture — same filename inside the (possibly renamed) album dir?
            let name = (rel as NSString).lastPathComponent
            let candidate = gap.dir.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) { targets.append(PerfectStore.rel(candidate, root)) }
            else { lost += 1 }
        }
        if lost > 0 { lines.append("Cover: \(lost) track(s) moved since the scan — run again to pick them up") }
        guard !targets.isEmpty else { coverGaps.removeAll { $0.id == gap.id }; return }
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
    /// A same-recording pair auto-dedup refused to decide (different albums —
    /// a legitimate-repeat candidate): offered on the by-ear review surface.
    struct EarPair: Identifiable, Sendable {
        let aRel: String, bRel: String
        let aInfo: String, bInfo: String
        let artist: String, title: String
        var id: String { aRel + "|" + bRel }
    }

    nonisolated static func libraryDedup(root: URL) async
        -> (writes: [(rel: String, field: String, value: String)],
            embeds: [(rel: String, image: Data, mime: String)],
            moves: [(from: String, to: String)],
            earPairs: [EarPair]) {
        var tracks = await PerfectStore.buildTracksFromDisk(root: root, fm: .default)
        let clusters = buildClusters(&tracks, mode: .balanced, tol: 2.0, crossAlbum: false)
        var writes: [(rel: String, field: String, value: String)] = []
        var embeds: [(rel: String, image: Data, mime: String)] = []
        var moves: [(from: String, to: String)] = []
        var earPairs: [EarPair] = []
        let backfill = ["title", "artist", "album", "albumartist", "composer",
                        "lyricist", "label", "conductor", "date", "track", "disc"]
        for c in clusters where c.memberIDs.count > 1 {
            // Legitimate repeat appearances — the same recording on its studio album
            // AND on a greatest-hits/compilation — are NEVER auto-removed (plan §E:
            // "move aside for review, never auto-delete"). They go to the by-ear
            // review surface instead. Only clusters whose members agree on the
            // edition-folded ALBUM are true stray copies.
            let albums = Set(c.memberIDs.map { Organiser.canonicalAlbumKey(tracks[$0].album) })
            guard albums.count == 1 else {
                let k = tracks[c.keeperID]
                func info(_ t: Track) -> String {
                    "\(fmtDur(t.duration)) · \(t.bitrate > 0 ? "\(t.bitrate) kbps" : t.ext) · \(t.album.isEmpty ? "?" : t.album)"
                }
                for id in c.memberIDs where id != c.keeperID {
                    let o = tracks[id]
                    earPairs.append(EarPair(aRel: PerfectStore.rel(k.url, root),
                                            bRel: PerfectStore.rel(o.url, root),
                                            aInfo: info(k), bInfo: info(o),
                                            artist: k.displayArtist, title: k.title))
                }
                continue
            }
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
        return (writes, embeds, moves, earPairs)
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
    @State private var confirmRevert = false
    @State private var cardIndex = 0
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
            // ---- the album carousel (approved mockup v2): one album per card,
            // everything it needs in one place; ‹ › / arrow keys / filmstrip to move.
            if !cardIDs.isEmpty {
                carousel
                filmstrip
                Divider()
            }
            List {
                if !driver.lines.isEmpty {
                    Section("Session") { ForEach(driver.lines, id: \.self) { Text($0).font(.caption) } }
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
        .safeAreaInset(edge: .bottom) {
            if !driver.deferred.isEmpty || !driver.earChoices.isEmpty || !driver.lines.isEmpty {
                HStack(spacing: 10) {
                    if !driver.deferred.isEmpty || !driver.earChoices.isEmpty {
                        let accepts = driver.deferred.reduce(0) { $0 + $1.decisions.filter(\.accept).count }
                            + driver.deferred.filter { $0.albumSuggestion != nil && $0.acceptAlbum }.count
                        Text("\(driver.deferred.count + driver.earChoices.count) item\(driver.deferred.count + driver.earChoices.count == 1 ? "" : "s") · \(accepts) change\(accepts == 1 ? "" : "s") accepted")
                            .fontWeight(.medium)
                    }
                    Text("nothing is written until you apply · every run undoable from Runs")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Revert library…", role: .destructive) { confirmRevert = true }
                        .disabled(driver.running || perfect.busy || root == nil)
                        .confirmationDialog("Revert this library to before Perfect ran?",
                                            isPresented: $confirmRevert, titleVisibility: .visible) {
                            Button("Revert everything", role: .destructive) {
                                if let root { perfect.undoLibrary(root) }
                            }
                        } message: {
                            Text("Every recorded run for this library is undone, newest first. Files and tags return to their pre-run state.")
                        }
                    if !driver.deferred.isEmpty || !driver.earChoices.isEmpty {
                        Button("Apply all decisions") {
                            if let root { Task { await driver.applyDecisions(root: root, store: perfect) } }
                        }
                        .buttonStyle(.borderedProminent).tint(.teal)
                        .disabled(driver.running || root == nil)
                    }
                }
                .padding(10)
                .background(.bar)
            }
        }
        .frame(minWidth: 700, minHeight: 460)
    }

    // ---- carousel plumbing ----

    /// Every album with something to decide, in one stable order: deferred name
    /// verdicts, by-ear duplicate pairs (keyed by their A-side's album folder),
    /// and cover gaps — merged so each album appears exactly ONCE.
    private var cardIDs: [String] {
        var order: [String] = []
        var seen = Set<String>()
        for d in driver.deferred where seen.insert(d.id).inserted { order.append(d.id) }
        if let root {
            for c in driver.earChoices {
                let dir = root.appendingPathComponent((c.pair.aRel as NSString).deletingLastPathComponent).path
                if seen.insert(dir).inserted { order.append(dir) }
            }
        }
        for g in driver.coverGaps where seen.insert(g.id).inserted { order.append(g.id) }
        return order
    }

    private func earChoiceIDs(for dirPath: String) -> [String] {
        guard let root else { return [] }
        return driver.earChoices.filter {
            root.appendingPathComponent(($0.pair.aRel as NSString).deletingLastPathComponent).path == dirPath
        }.map(\.id)
    }

    private var carousel: some View {
        let ids = cardIDs
        let index = min(cardIndex, max(ids.count - 1, 0))
        return HStack(spacing: 0) {
            Button { cardIndex = max(index - 1, 0) } label: {
                Image(systemName: "chevron.left").font(.title2)
            }
            .buttonStyle(.plain).padding(.horizontal, 8)
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(index == 0)
            if index < ids.count {
                CarouselAlbumCard(
                    dirPath: ids[index],
                    position: (index + 1, ids.count),
                    deferred: deferredBinding(ids[index]),
                    earIDs: earChoiceIDs(for: ids[index]),
                    driver: driver, root: root, store: perfect
                )
                .id(ids[index])
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Button { cardIndex = min(index + 1, ids.count - 1) } label: {
                Image(systemName: "chevron.right").font(.title2)
            }
            .buttonStyle(.plain).padding(.horizontal, 8)
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(index >= ids.count - 1)
        }
        .padding(.vertical, 8)
    }

    private var filmstrip: some View {
        let ids = cardIDs
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(ids.enumerated()), id: \.element) { i, id in
                    let dir = URL(fileURLWithPath: id)
                    VStack(spacing: 2) {
                        ZStack(alignment: .topTrailing) {
                            filmFrameImage(id)
                                .frame(width: 46, height: 46)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(i == min(cardIndex, ids.count - 1) ? Color.purple : Color.secondary.opacity(0.3),
                                                  lineWidth: i == min(cardIndex, ids.count - 1) ? 2 : 1))
                            filmBadges(id)
                        }
                        Text(dir.lastPathComponent).font(.system(size: 9)).lineLimit(1)
                            .frame(width: 52)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { cardIndex = i }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    @ViewBuilder private func filmFrameImage(_ id: String) -> some View {
        if let gap = driver.coverGaps.first(where: { $0.id == id }),
           let data = gap.art.ownCovers.first, let img = NSImage(data: data) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.12))
                Image(systemName: "music.note").foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private func filmBadges(_ id: String) -> some View {
        HStack(spacing: 2) {
            if let d = driver.deferred.first(where: { $0.id == id }), !d.decisions.isEmpty || d.albumSuggestion != nil {
                badge("N", .orange)
            }
            if !earChoiceIDs(for: id).isEmpty { badge("2×", .orange) }
            if driver.coverGaps.contains(where: { $0.id == id }) { badge("C", .purple) }
        }
        .offset(x: 4, y: -4)
    }

    private func badge(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Capsule().fill(c))
    }

    private func deferredBinding(_ id: String) -> Binding<PerfectV2Driver.DeferredAlbum>? {
        guard driver.deferred.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { driver.deferred.first(where: { $0.id == id })
                   ?? PerfectV2Driver.DeferredAlbum(dir: URL(fileURLWithPath: id), files: []) },
            set: { v in if let i = driver.deferred.firstIndex(where: { $0.id == id }) { driver.deferred[i] = v } }
        )
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
    var onSelect: ((Data) -> Void)? = nil   // carousel: preview the pick on the big cover
    // editable query — the escape hatch when the tag-driven search misses
    // (e.g. an album filed under Various Artists, or a renamed edition)
    @State private var queryArtist = ""
    @State private var queryAlbum = ""

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
                            .onTapGesture { selected = data; onSelect?(data) }
                    }
                    ForEach(Array(online.enumerated()), id: \.offset) { _, data in
                        CoverThumb(data: data, selected: selected == data, badge: "online")
                            .onTapGesture { selected = data; onSelect?(data) }
                    }
                    if !searched {
                        Button {
                            search()
                        } label: {
                            if searching { ProgressView().controlSize(.small) }
                            else { Label("Find covers online", systemImage: "magnifyingglass") }
                        }
                        .controlSize(.small).disabled(searching)
                    } else if online.isEmpty {
                        Text("nothing found online — edit the search below").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            if searched {
                // the manual escape hatch: edit the query when the tag-driven search misses
                HStack(spacing: 6) {
                    TextField("Artist", text: $queryArtist).textFieldStyle(.roundedBorder)
                        .font(.caption).frame(width: 160)
                    TextField("Album", text: $queryAlbum).textFieldStyle(.roundedBorder)
                        .font(.caption).frame(width: 220)
                    Button {
                        search()
                    } label: {
                        if searching { ProgressView().controlSize(.small) } else { Text("Search again") }
                    }
                    .controlSize(.small).disabled(searching)
                    Text("edit the search if the match misses").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func search() {
        if queryArtist.isEmpty && queryAlbum.isEmpty {
            // pre-fill from tags — but never search on "Various Artists", the
            // dead-end that hid The Specials' cover; leave artist blank instead
            let a = gap.art.artist
            queryArtist = Organiser.artistKey(a) == "variousartists" ? "" : a
            queryAlbum = gap.art.album.isEmpty ? gap.dir.lastPathComponent : gap.art.album
        }
        searching = true
        let a = queryArtist, al = queryAlbum
        Task {
            let found = await CoverArtClient().candidates(releaseMBIDs: [], artist: a, album: al)
            await MainActor.run { online = found; searching = false; searched = true }
        }
    }
}

// MARK: - Kept names (per-album "don't ask again")

/// Proposals the user KEPT: remembered per album folder so an identical
/// suggestion never re-queues (and never auto-applies) on later runs.
enum KeptNamesStore {
    private static func hash(_ s: String) -> String {
        var h: UInt64 = 5381; for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }; return String(h, radix: 16)
    }
    private static func file(_ folderPath: String) -> URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("Music Librarian/kept-names", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(hash(folderPath)).json")
    }
    /// The change a proposal describes, folded — stable across runs and cosmetic drift.
    static func pairKey(_ p: TrackProposal) -> String {
        TrackProposal.hardFold(p.curTitle) + ">" + TrackProposal.hardFold(p.newTitle)
        + "|" + TrackProposal.hardFold(p.curArtist) + ">" + TrackProposal.hardFold(p.newArtist)
    }
    static func load(_ folderPath: String) -> Set<String> {
        guard let u = file(folderPath), let d = try? Data(contentsOf: u),
              let a = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return Set(a)
    }
    static func add(_ folderPath: String, _ keys: [String]) {
        guard let u = file(folderPath) else { return }
        let merged = load(folderPath).union(keys)
        if let d = try? JSONEncoder().encode(Array(merged).sorted()) { try? d.write(to: u) }
    }
}

// MARK: - Deferred album card (per-track verdicts, approved mockup)

/// One deferred album: artist-first header, Accept-all/Keep-all quick actions,
/// then a verdict row per track (and the album-name suggestion when present).
struct DeferredAlbumCard: View {
    @Binding var album: PerfectV2Driver.DeferredAlbum
    let busy: Bool
    var showHeader = true   // false when embedded in a carousel card (which has its own)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if showHeader {
                    (Text(album.artist).foregroundColor(.purple).fontWeight(.semibold)
                     + Text(" — \(album.album)").fontWeight(.semibold))
                    Text("\(album.decisions.count) track\(album.decisions.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if album.decisions.count > 1 {
                    Button("Accept all") { setAll(true) }.controlSize(.small).disabled(busy)
                    Button("Keep all") { setAll(false) }.controlSize(.small).disabled(busy)
                }
            }
            ForEach($album.decisions) { $d in
                TrackDecisionRow(decision: $d, busy: busy)
            }
            if let s = album.albumSuggestion {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.folder").foregroundStyle(.orange)
                    Text(s.summary).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Picker("", selection: $album.acceptAlbum) {
                        Text("Accept").tag(true)
                        Text("Keep blank").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                    .disabled(busy)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func setAll(_ accept: Bool) {
        for i in album.decisions.indices { album.decisions[i].accept = accept }
    }
}

/// One track's A/B verdict row: old name struck through → proposed name, a
/// change-kind chip, the AcoustID score (amber when risky), ▶A/▶B audition
/// buttons, and the Accept/Keep segmented verdict.
struct TrackDecisionRow: View {
    @Binding var decision: PerfectV2Driver.TrackDecision
    let busy: Bool
    @ObservedObject private var audio = AudioPreview.shared
    @State private var previewURL: URL?
    @State private var previewLoading = false
    @State private var previewMissing = false

    private var p: TrackProposal { decision.proposal }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                if !p.newTitle.isEmpty, p.newTitle != p.curTitle {
                    changeLine(from: p.curTitle.isEmpty ? p.url.lastPathComponent : p.curTitle, to: p.newTitle)
                }
                if !p.newArtist.isEmpty, p.newArtist != p.curArtist {
                    changeLine(from: "artist: \(p.curArtist.isEmpty ? "—" : p.curArtist)", to: p.newArtist)
                }
            }
            Text(kindLabel)
                .font(.system(size: 9, weight: .semibold)).textCase(.uppercase)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(decision.risky ? Color.orange.opacity(0.18) : Color.purple.opacity(0.14)))
                .foregroundStyle(decision.risky ? Color.orange : Color.purple)
            Text(String(format: "%.2f", p.score))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(decision.risky ? Color.orange : Color.secondary)
            // ▶A — your file
            Button { audio.toggle(p.url) } label: {
                Image(systemName: audio.playingURL == p.url ? "stop.circle.fill" : "play.circle")
                    .foregroundStyle(audio.playingURL == p.url ? Color.red : Color.teal)
            }
            .buttonStyle(.plain).help("Play your file")
            // ▶B — the proposed match (online preview)
            Button { playProposed() } label: {
                if previewLoading { ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 16, height: 16) }
                else {
                    Image(systemName: previewMissing ? "waveform.slash"
                          : (previewURL != nil && audio.playingURL == previewURL ? "stop.circle.fill" : "waveform.circle"))
                        .foregroundStyle(previewMissing ? Color.secondary
                                         : (previewURL != nil && audio.playingURL == previewURL ? Color.red : Color.purple))
                }
            }
            .buttonStyle(.plain).disabled(previewLoading || previewMissing)
            .help(previewMissing ? "No online preview found for the proposed match" : "Hear the proposed match")
            Spacer()
            Picker("", selection: $decision.accept) {
                Text("Accept").tag(true)
                Text("Keep").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 140)
            .disabled(busy)
        }
        .padding(.leading, 8)
    }

    private var kindLabel: String {
        if TrackProposal.nameVariant(p.curTitle, p.newTitle)
            || TrackProposal.nameVariant(p.curArtist, p.newArtist) { return "variant" }
        return p.score < 0.75 ? "low confidence" : "retitle"
    }

    private func changeLine(from: String, to: String) -> some View {
        (Text(from).strikethrough().foregroundColor(.secondary)
         + Text("  →  ").foregroundColor(.secondary)
         + Text(to).fontWeight(.semibold))
            .font(.callout)
            .lineLimit(1)
    }

    private func playProposed() {
        if let u = previewURL { audio.toggle(u); return }
        guard !previewLoading else { return }
        previewLoading = true
        let artist = p.newArtist.isEmpty ? p.curArtist : p.newArtist
        let title = p.newTitle.isEmpty ? p.curTitle : p.newTitle
        Task {
            let url = await CoverArtClient().trackPreview(artist: artist, title: title)
            await MainActor.run {
                previewLoading = false
                if let url { previewURL = url; audio.toggle(url) } else { previewMissing = true }
            }
        }
    }
}

/// One by-ear duplicate: artist — title header, then the two copies with play
/// buttons and their vitals, and a Keep A / Keep B / Keep both verdict. "Keep
/// both" is the recommended default — a track on its album AND a hits set is
/// legitimate ownership, not a duplicate.
struct EarChoiceRow: View {
    @Binding var choice: PerfectV2Driver.EarChoice
    let rootURL: URL?
    let busy: Bool
    @ObservedObject private var audio = AudioPreview.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                (Text(choice.pair.artist).foregroundColor(.purple).fontWeight(.semibold)
                 + Text(" — \(choice.pair.title)").fontWeight(.semibold))
                Spacer()
                Picker("", selection: $choice.verdict) {
                    Text("Keep A").tag(PerfectV2Driver.EarChoice.Verdict.keepA)
                    Text("Keep B").tag(PerfectV2Driver.EarChoice.Verdict.keepB)
                    Text("Keep both").tag(PerfectV2Driver.EarChoice.Verdict.keepBoth)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                .disabled(busy)
            }
            copyLine(label: "A", rel: choice.pair.aRel, info: choice.pair.aInfo)
            copyLine(label: "B", rel: choice.pair.bRel, info: choice.pair.bInfo)
        }
        .padding(.vertical, 4)
    }

    private func copyLine(label: String, rel: String, info: String) -> some View {
        HStack(spacing: 8) {
            if let rootURL {
                let url = rootURL.appendingPathComponent(rel)
                Button { audio.toggle(url) } label: {
                    Image(systemName: audio.playingURL == url ? "stop.circle.fill" : "play.circle")
                        .foregroundStyle(audio.playingURL == url ? Color.red : Color.teal)
                }
                .buttonStyle(.plain).help("Play copy \(label)")
            }
            Text(label).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
            Text(info).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            Text(rel).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
        }
        .padding(.leading, 8)
    }
}

// MARK: - Carousel album card (approved mockup v2)

/// One album, everything it needs in one place: big cover (instant preview of a
/// pick), artist-first title, needs chips, then blocks for names, this album's
/// duplicate calls, and the cover chooser.
struct CarouselAlbumCard: View {
    let dirPath: String
    let position: (Int, Int)
    let deferred: Binding<PerfectV2Driver.DeferredAlbum>?
    let earIDs: [String]
    @ObservedObject var driver: PerfectV2Driver
    let root: URL?
    let store: PerfectStore
    @State private var previewCover: Data?

    private var dir: URL { URL(fileURLWithPath: dirPath) }
    private var gap: PerfectV2Driver.CoverGap? { driver.coverGaps.first { $0.id == dirPath } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                bigCover
                VStack(alignment: .leading, spacing: 4) {
                    (Text(dir.deletingLastPathComponent().lastPathComponent)
                        .foregroundColor(.purple).fontWeight(.semibold)
                     + Text(" — \(dir.lastPathComponent)").fontWeight(.semibold))
                        .font(.title3)
                    needsChips
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Album \(position.0) of \(position.1)").font(.caption).foregroundStyle(.secondary)
                    Text("← → keys").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if let deferred {
                block("Names") { DeferredAlbumCard(album: deferred, busy: driver.running, showHeader: false) }
            }
            if !earIDs.isEmpty {
                block("Duplicates — the same recording elsewhere") {
                    ForEach(earIDs, id: \.self) { id in
                        if let b = earBinding(id) { EarChoiceRow(choice: b, rootURL: root, busy: driver.running) }
                    }
                }
            }
            if let gap {
                block(gap.missingRels.isEmpty ? "Cover — none on any track (tap to preview)"
                                              : "Cover — \(gap.missingRels.count) of \(gap.art.rels.count) track(s) without art") {
                    CoverGapRow(gap: gap, driver: driver, root: root, store: store,
                                onSelect: { previewCover = $0 })
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private var bigCover: some View {
        ZStack {
            if let data = previewCover ?? gap?.art.ownCovers.first, let img = NSImage(data: data) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color.secondary.opacity(0.1))
                Image(systemName: "music.note").font(.system(size: 34)).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 110, height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
    }

    private var needsChips: some View {
        HStack(spacing: 6) {
            if let d = deferred?.wrappedValue {
                if !d.decisions.isEmpty { chip("\(d.decisions.count) name\(d.decisions.count == 1 ? "" : "s")", .orange) }
                if d.albumSuggestion != nil { chip("album name?", .orange) }
            }
            if !earIDs.isEmpty { chip("\(earIDs.count) repeat\(earIDs.count == 1 ? "" : "s")", .orange) }
            if let gap { chip(gap.missingRels.isEmpty ? "no cover" : "cover gaps", .purple) }
        }
    }

    private func chip(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 10, weight: .semibold)).textCase(.uppercase)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.15)))
            .foregroundStyle(c)
    }

    @ViewBuilder private func block<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .semibold)).textCase(.uppercase)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))
    }

    private func earBinding(_ id: String) -> Binding<PerfectV2Driver.EarChoice>? {
        guard let first = driver.earChoices.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { driver.earChoices.first(where: { $0.id == id }) ?? first },
            set: { v in if let i = driver.earChoices.firstIndex(where: { $0.id == id }) { driver.earChoices[i] = v } }
        )
    }
}
