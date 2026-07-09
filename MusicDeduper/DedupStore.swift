//
//  DedupStore.swift
//  MusicDeduper
//
//  Observable state + orchestration (scan / cluster / copy / delete).
//

import Foundation
import SwiftUI
import AppKit

@MainActor
final class DedupStore: ObservableObject {
    @Published var sourceURL: URL?
    @Published var tracks: [Track] = []
    @Published var clusters: [Cluster] = []
    @Published var status: String = "Pick a source folder to begin."
    @Published var progress: Double = 0          // 0...1
    @Published var busy: Bool = false
    @Published var matchMode: MatchMode = .balanced
    @Published var tolerance: Double = 2
    @Published var crossAlbum: Bool = false
    @Published var unreadableCount: Int = 0

    // SMB address (guest) used to auto-reconnect the destination if it drops mid-copy
    @Published var smbAddress: String = UserDefaults.standard.string(forKey: "smbAddress") ?? "" {
        didSet { UserDefaults.standard.set(smbAddress, forKey: "smbAddress") }
    }
    // the name the share was located under, when smbAddress was converted to an IP
    @Published var smbOriginalName: String = UserDefaults.standard.string(forKey: "smbOriginalName") ?? "" {
        didSet { UserDefaults.standard.set(smbOriginalName, forKey: "smbOriginalName") }
    }

    /// Store a newly-located share address, converting its hostname to an IP in the
    /// background (name lookup is often the first casualty of a flaky network, so
    /// reconnects go straight at the IP). The name is kept for display.
    func setShareAddress(_ address: String) {
        smbAddress = address
        smbOriginalName = ""
        Task.detached { [address] in
            guard let ip = ipVersionOfSMBAddress(address) else { return }
            await MainActor.run {
                if self.smbAddress == address {   // unchanged since we started resolving
                    self.smbOriginalName = address
                    self.smbAddress = ip
                }
            }
        }
    }

    // recently used source folders (paths, newest first)
    @Published var recentSources: [String] = UserDefaults.standard.stringArray(forKey: "recentSources") ?? []

    // copy-conflict flow: a differing file at the destination pauses the copy
    // until the user decides (or a sticky Overwrite All / Skip All policy is set)
    @Published var pendingConflict: CopyConflict?
    let conflictBox = ConflictBox()

    func resolveConflict(_ d: ConflictDecision) {
        if d == .overwriteAll || d == .skipAll { conflictBox.policy = d }
        conflictBox.answer(d)
        pendingConflict = nil
    }

    // progress-dialog state (copy / delete)
    @Published var opActive = false
    @Published var opFinished = false
    @Published var opTitle = ""
    @Published var opDone = 0
    @Published var opTotal = 0
    @Published var opOK = 0
    @Published var opSkip = 0
    @Published var opFail = 0
    @Published var opLog: [String] = []
    @Published var opNote = ""          // transient "retrying…" line
    let cancelBox = CancelBox()

    func requestCancel() { cancelBox.cancelled = true }

    // Keeps macOS from throttling us (App Nap) or idle-sleeping mid-operation.
    // The token must stay alive for the whole operation — App Nap resumes the
    // moment it deallocates — so it lives here, not in a task scope.
    private var activity: NSObjectProtocol?

    // Display sleep is behaviourally linked to Wi-Fi dropping power on many Macs,
    // which is exactly what kills an SMB copy — so this defaults on.
    @Published var keepDisplayAwake: Bool =
        UserDefaults.standard.object(forKey: "keepDisplayAwake") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepDisplayAwake, forKey: "keepDisplayAwake") }
    }

    private func opStart(title: String, total: Int) {
        cancelBox.cancelled = false
        opActive = true; opFinished = false; opTitle = title
        opTotal = total; opDone = 0; opOK = 0; opSkip = 0; opFail = 0; opLog = []; opNote = ""
        busy = true
        if activity == nil {
            // .userInitiated already implies idle-system-sleep prevention
            var opts: ProcessInfo.ActivityOptions =
                [.userInitiated, .suddenTerminationDisabled, .automaticTerminationDisabled]
            if keepDisplayAwake { opts.insert(.idleDisplaySleepDisabled) }
            activity = ProcessInfo.processInfo.beginActivity(options: opts, reason: title)
        }
    }
    private func opStep(done: Int, ok: Int, skip: Int, fail: Int, line: String) {
        opDone = done; opOK = ok; opSkip = skip; opFail = fail
        opLog.append(line)
        if opLog.count > 800 { opLog.removeFirst(opLog.count - 800) }
    }
    private func setNote(_ s: String) { opNote = s }
    private func opLogLine(_ line: String) {
        opLog.append(line)
        if opLog.count > 800 { opLog.removeFirst(opLog.count - 800) }
    }
    private func opFinishLine(_ summary: String) {
        opLog.append(summary); opFinished = true; busy = false; status = summary; opNote = ""
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
    }
    func closeOp() { opActive = false }

    // derived stats
    var artistCount: Int { Set(tracks.map { $0.displayArtist.isEmpty ? "Unknown Artist" : $0.displayArtist }).count }
    var removableCount: Int { clusters.reduce(0) { $0 + $1.memberIDs.count - 1 } }
    var reclaimBytes: Int64 { clusters.reduce(0) { $0 + $1.reclaim } }

    func trackByID(_ id: Int) -> Track? { id < tracks.count ? tracks[id] : tracks.first { $0.id == id } }

    // MARK: Source selection

    func pickSource() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Choose"
        p.message = "Choose your music source folder"
        if p.runModal() == .OK, let url = p.url {
            setSource(url)
        }
    }

    /// Set a source folder (picker, drag-and-drop, or recents) and scan it.
    func setSource(_ url: URL) {
        sourceURL = url
        var r = recentSources.filter { $0 != url.path }
        r.insert(url.path, at: 0)
        recentSources = Array(r.prefix(5))
        UserDefaults.standard.set(recentSources, forKey: "recentSources")
        scan()
    }

    // MARK: Scan

    func scan() {
        guard let root = sourceURL, !busy else { return }
        busy = true; progress = 0; tracks = []; clusters = []
        status = "Enumerating files…"
        let mode = matchMode, tol = tolerance, cross = crossAlbum

        Task.detached(priority: .userInitiated) {
            // enumerate audio files
            var urls: [URL] = []
            if let en = FileManager.default.enumerator(at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]) {
                while let obj = en.nextObject() {
                    if let u = obj as? URL, audioExt.contains(u.pathExtension.lowercased()) { urls.append(u) }
                }
            }
            await self.setStatus("Found \(urls.count) audio files — reading tags…")

            var built: [Track] = []
            var unreadable = 0
            let total = max(urls.count, 1)
            for (idx, u) in urls.enumerated() {
                let vals = try? u.resourceValues(forKeys: [.fileSizeKey])
                let size = Int64(vals?.fileSize ?? 0)
                if size == 0 { unreadable += 1 }
                var t = await readMetadata(url: u, size: size)
                let relDir = Self.relativeDir(of: u, root: root)
                t = Track(id: built.count, url: u, name: u.lastPathComponent, relDir: relDir,
                          size: size, ext: t.ext, title: t.title, artist: t.artist, album: t.album,
                          albumArtist: t.albumArtist, trackNo: t.trackNo, discNo: t.discNo,
                          duration: t.duration, lossless: t.lossless, bitrate: t.bitrate, codec: t.codec)
                built.append(t)
                if idx % 20 == 0 {
                    await self.setProgress(Double(idx) / Double(total))
                    await self.setStatus("Reading tags \(idx + 1)/\(total)")
                }
            }
            await self.setStatus("Finding duplicates…")
            var mutable = built
            let cl = buildClusters(&mutable, mode: mode, tol: tol, crossAlbum: cross) { s in
                Task { await self.setStatus(s) }
            }
            await self.finishScan(tracks: mutable, clusters: cl, unreadable: unreadable)
        }
    }

    nonisolated private static func relativeDir(of url: URL, root: URL) -> String {
        let full = url.deletingLastPathComponent().path
        let base = root.path
        if full.hasPrefix(base) {
            var r = String(full.dropFirst(base.count))
            if r.hasPrefix("/") { r.removeFirst() }
            return r
        }
        return full
    }

    private func setStatus(_ s: String) { status = s }
    private func setProgress(_ p: Double) { progress = p }

    private func finishScan(tracks: [Track], clusters: [Cluster], unreadable: Int) {
        self.tracks = tracks
        self.clusters = clusters
        self.unreadableCount = unreadable
        self.busy = false
        self.progress = 1
        self.selectedIDs = Set(tracks.map { $0.id })   // default: everything selected
        var msg = "Scanned \(tracks.count) tracks · \(clusters.count) duplicate group(s)."
        if unreadable > 0 { msg += "  ⚠ \(unreadable) file(s) unreadable (iCloud not downloaded?)." }
        self.status = msg
    }

    // MARK: Keeper override

    func setKeeper(clusterID: UUID, trackID: Int) {
        guard let idx = clusters.firstIndex(where: { $0.id == clusterID }) else { return }
        clusters[idx].keeperID = trackID
        clusters[idx].reclaim = clusters[idx].memberIDs
            .filter { $0 != trackID }
            .reduce(Int64(0)) { $0 + (trackByID($1)?.size ?? 0) }
    }

    var keeperTracks: [Track] {
        let inCluster = Set(clusters.flatMap { $0.memberIDs })
        let keepers = Set(clusters.map { $0.keeperID })
        return tracks.filter { !inCluster.contains($0.id) || keepers.contains($0.id) }
    }

    // MARK: Selection — which tracks the Copy step ships (everything else is untouched;
    // Clean up deliberately ignores selection: dedupe is library-wide hygiene)

    @Published var selectedIDs: Set<Int> = []

    enum AlbumSelection { case all, partial, none }

    func selectionState(of ids: [Int]) -> AlbumSelection {
        let n = ids.reduce(0) { $0 + (selectedIDs.contains($1) ? 1 : 0) }
        return n == 0 ? .none : (n == ids.count ? .all : .partial)
    }
    func setSelected(_ id: Int, _ on: Bool) {
        if on { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
    }
    /// Badge click: fully-selected album → none; partial or none → all.
    func toggleAlbum(_ ids: [Int]) {
        if selectionState(of: ids) == .all { selectedIDs.subtract(ids) }
        else { selectedIDs.formUnion(ids) }
    }
    func selectAll() { selectedIDs = Set(tracks.map { $0.id }) }
    func selectNone() { selectedIDs = [] }

    var selectedKeeperTracks: [Track] { keeperTracks.filter { selectedIDs.contains($0.id) } }
    var dropTracks: [Track] {
        clusters.flatMap { c in c.memberIDs.filter { $0 != c.keeperID } }.compactMap { trackByID($0) }
    }

    // MARK: Delete

    func deleteDuplicates(mode: DeleteMode) {
        let drops = dropTracks
        guard !drops.isEmpty else { return }
        let items = drops.map { ($0.url, $0.name) }
        opStart(title: (mode == .trash ? "Moving to Trash" : "Deleting") + " \(drops.count) duplicate(s)…", total: drops.count)
        let box = cancelBox
        Task.detached(priority: .userInitiated) {
            var ok = 0, fail = 0, cancelled = false
            let fm = FileManager.default
            for (i, item) in items.enumerated() {
                if box.cancelled { cancelled = true; break }
                let (u, name) = item
                do {
                    if mode == .trash { try fm.trashItem(at: u, resultingItemURL: nil) }
                    else { try fm.removeItem(at: u) }
                    ok += 1
                    await self.opStep(done: i + 1, ok: ok, skip: 0, fail: fail, line: "🗑 \(name)")
                } catch {
                    fail += 1
                    await self.opStep(done: i + 1, ok: ok, skip: 0, fail: fail, line: "✗ \(name) — \(error.localizedDescription)")
                }
            }
            let summary = cancelled
                ? "■ Cancelled — \(ok) removed before stop."
                : "✔ Done — \(ok) removed" + (fail > 0 ? ", \(fail) failed." : ".")
            await self.finishDelete(summary: summary)
        }
    }

    private func finishDelete(summary: String) {
        // Rebuild from what still exists on disk (handles partial failures + cancellation).
        var survivors = tracks.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        for i in survivors.indices { survivors[i].id = i }
        tracks = survivors
        clusters = buildClusters(&tracks, mode: matchMode, tol: tolerance, crossAlbum: crossAlbum)
        selectedIDs = Set(tracks.map { $0.id })   // IDs renumbered — reset to all
        opFinishLine(summary)
    }

    // MARK: Copy keepers

    // files that gave up after all retries in the last copy run — offered a "Retry failed"
    @Published var failedCopyIDs: [Int] = []
    private var lastCopyDest: URL?

    func copyKeepers(to dest: URL) {
        let items = selectedKeeperTracks
        runCopy(items, to: dest,
                title: "Copying \(items.count) selected keeper(s) → \(dest.lastPathComponent)")
    }

    func retryFailedCopies() {
        guard let dest = lastCopyDest, !failedCopyIDs.isEmpty else { return }
        let items = failedCopyIDs.compactMap { trackByID($0) }
        runCopy(items, to: dest, title: "Retrying \(items.count) failed file(s) → \(dest.lastPathComponent)")
    }

    // auto-pause: the run pauses itself after this many consecutive failures
    // (the server has clearly gone away — grinding on just multiplies timeouts)
    private static let pauseAfterConsecutiveFails = 3
    @Published var opPaused = false
    let resumeBox = ResumeBox()
    func resumeCopy() { resumeBox.resumed = true }
    private func setPaused(_ p: Bool) { opPaused = p }

    private func runCopy(_ items: [Track], to dest: URL, title: String) {
        let keepers = items
        lastCopyDest = dest
        failedCopyIDs = []
        opStart(title: title, total: keepers.count)
        opPaused = false
        let box = cancelBox
        let conflicts = conflictBox
        conflicts.reset()
        let pause = resumeBox
        pause.reset()
        let addr = smbAddress

        // Keep-alive: touch the destination every 30s so the SMB session never
        // sits idle long enough for the server (or macOS) to drop it.
        let keepAlive = Task.detached(priority: .background) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { break }
                _ = try? FileManager.default.contentsOfDirectory(atPath: dest.path)
            }
        }

        Task.detached(priority: .userInitiated) {
            // Resolve the share's hostname to an IP now, while the connection is
            // healthy — re-mounts then use the IP directly instead of also having
            // to win a name lookup on a network that's already misbehaving.
            let reconnectAddr: String = {
                guard !addr.isEmpty, let ip = ipVersionOfSMBAddress(addr) else { return addr }
                return ip
            }()
            if reconnectAddr != addr {
                await self.opLogLine("ℹ \(addr) is \(reconnectAddr) — reconnects will use the IP")
            }
            let counters = CopyCounters()
            let throttle = MountThrottle()

            // The lead loop stays sequential (conflict prompts must appear one at
            // a time); the actual data copies fan out to at most 3 at once —
            // parallel streams amortise the per-file round trips that dominate
            // small-file transfers on old SMB dialects.
            await withTaskGroup(of: Void.self) { group in
                var inFlight = 0
                // One listing per album folder instead of one existence check per
                // file — a listing costs the same round trip but answers for the
                // whole album, so new albums cost zero per-file checks.
                var dirCache: [String: [String: (size: Int64, date: Date?)]] = [:]
                var lastLimit = 3
                for t in keepers {
                    if box.cancelled { break }

                    // server clearly gone → pause and wait for Resume (or Cancel)
                    if counters.consecutiveFailCount >= Self.pauseAfterConsecutiveFails {
                        await self.opLogLine("⏸ \(Self.pauseAfterConsecutiveFails) files in a row failed — the server has gone away. Paused; press Resume when it's back.")
                        await self.setPaused(true)
                        while !box.cancelled && !pause.resumed {
                            try? await Task.sleep(nanoseconds: 300_000_000)
                        }
                        counters.resetConsecutive()
                        pause.reset()
                        await self.setPaused(false)
                        if box.cancelled { break }
                        await self.opLogLine("▶ Resumed.")
                    }

                    let dir = dest.appendingPathComponent(sanitizeName(t.displayArtist.isEmpty ? "Unknown Artist" : t.displayArtist))
                                    .appendingPathComponent(sanitizeName(t.album.isEmpty ? "Unknown Album" : t.album))
                    let target = dir.appendingPathComponent(t.name)

                    // Existence check via the cached album-folder listing (one
                    // watchdogged round trip per folder, not per file). A folder
                    // that doesn't exist yet lists as empty — no conflicts.
                    if dirCache[dir.path] == nil {
                        let listResult = await runBlockingFileOp(timeout: 20, cancel: box) {
                            () -> [String: (size: Int64, date: Date?)] in
                            var m: [String: (size: Int64, date: Date?)] = [:]
                            let items = (try? FileManager.default.contentsOfDirectory(
                                at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
                            for u in items {
                                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                                m[u.lastPathComponent] = (Int64(v?.fileSize ?? 0), v?.contentModificationDate)
                            }
                            return m
                        }
                        if listResult == nil && box.cancelled { break }
                        if case .success(let m) = listResult { dirCache[dir.path] = m }
                        else { dirCache[dir.path] = [:] }   // hung/failed listing → let the copy worker fight it out
                    }

                    // file already exists at the destination → that's a conflict,
                    // the user decides (Overwrite / Skip, each or All). No silent skips.
                    if let existing = dirCache[dir.path]?[t.name] {
                        let exSize = existing.size
                        let identical = Int64(exSize) == t.size
                        var decision = conflicts.policy
                        if decision == nil {
                            await self.presentConflict(CopyConflict(
                                name: t.name,
                                artist: t.displayArtist, album: t.album,
                                srcURL: t.url, srcSize: t.size,
                                dstSize: Int64(exSize), dstDate: existing.date,
                                identical: identical))
                            while !box.cancelled {
                                if let d = conflicts.take() { decision = d; break }
                                try? await Task.sleep(nanoseconds: 200_000_000)
                            }
                            await self.presentConflict(nil)
                            if box.cancelled { break }
                        }
                        if decision == .skip || decision == .skipAll {
                            let s = counters.recordSkip()
                            await self.opStep(done: s.done, ok: s.ok, skip: s.skip, fail: s.fail,
                                              line: "• kept existing \(t.name)\(identical ? " (identical size)" : "")")
                            continue
                        }
                        // overwrite falls through to the copy below (target removed there)
                    }

                    let limit = counters.currentLimit
                    if limit != lastLimit {
                        await self.opLogLine(limit > lastLimit
                            ? "⇧ link is clean — stepping up to \(limit) parallel copies"
                            : "⇩ retries seen — back to \(limit) parallel copies")
                        lastLimit = limit
                    }
                    while inFlight >= limit {
                        await group.next()
                        inFlight -= 1
                    }
                    group.addTask {
                        await self.copyOneFile(t, dir: dir, target: target, dest: dest,
                                               box: box, counters: counters, throttle: throttle,
                                               reconnectAddr: reconnectAddr, addr: addr)
                    }
                    inFlight += 1
                }
                await group.waitForAll()
            }

            // Sweep: one automatic retry pass over files that failed mid-run —
            // by the time the run ends the share has usually recovered, so a
            // second look often lands them. Files that fail again stay in the
            // Retry-failed list for the manual button.
            if !box.cancelled {
                let sweepIDs = Set(counters.beginSweep())
                if !sweepIDs.isEmpty {
                    await self.opLogLine("⟲ Sweeping \(sweepIDs.count) failed file(s)…")
                    for t in keepers where sweepIDs.contains(t.id) {
                        if box.cancelled { break }
                        let dir = dest.appendingPathComponent(sanitizeName(t.displayArtist.isEmpty ? "Unknown Artist" : t.displayArtist))
                                        .appendingPathComponent(sanitizeName(t.album.isEmpty ? "Unknown Album" : t.album))
                        let target = dir.appendingPathComponent(t.name)
                        await self.copyOneFile(t, dir: dir, target: target, dest: dest,
                                               box: box, counters: counters, throttle: throttle,
                                               reconnectAddr: reconnectAddr, addr: addr, sweep: true)
                    }
                }
            }

            keepAlive.cancel()
            let c = counters.finalSnapshot()
            let summary = box.cancelled
                ? "■ Cancelled — copied \(c.ok), skipped \(c.skip)."
                : "✔ Done — copied \(c.ok), skipped \(c.skip)"
                  + (c.fail > 0 ? ", \(c.fail) failed — use Retry failed." : ".")
            await self.finishCopy(summary: summary, failedIDs: c.failedIDs)
        }
    }

    /// Copy one file with retries, watchdog, and (throttled) share re-mount.
    /// Runs off the main actor; up to 3 of these are in flight at once.
    nonisolated private func copyOneFile(_ t: Track, dir: URL, target: URL, dest: URL,
                                         box: CancelBox, counters: CopyCounters,
                                         throttle: MountThrottle,
                                         reconnectAddr: String, addr: String,
                                         sweep: Bool = false) async {
        var copied = false
        var attempt = 0
        let maxAttempts = 5
        // watchdog: 10s base + 1.5s per MB — a healthy copy never gets near
        // it, a wedged share is declared hung instead of blocking for minutes
        let opTimeout = min(90.0, 10.0 + Double(t.size) / 1_000_000.0 * 1.5)
        while !box.cancelled {
            let srcURL = t.url, wantSize = t.size
            let result = await runBlockingFileOp(timeout: opTimeout, cancel: box) {
                let fm = FileManager.default
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
                try fm.copyItem(at: srcURL, to: target)
                // verify the whole file landed — a mid-copy stall can leave a truncated file
                let landed = ((try? fm.attributesOfItem(atPath: target.path))?[.size] as? NSNumber)?.int64Value
                guard landed == wantSize else {
                    try? fm.removeItem(at: target)
                    throw NSError(domain: "MusicDeduper", code: 1, userInfo: [
                        NSLocalizedDescriptionKey:
                            "incomplete copy (\(landed ?? 0) of \(wantSize) bytes landed)"])
                }
            }
            if case .success = result { copied = true; break }
            if result == nil && box.cancelled { break }

            let desc: String
            if case .failure(let e) = result { desc = e.localizedDescription }
            else { desc = "no response after \(Int(opTimeout))s — share not answering" }
            attempt += 1
            counters.noteRetry()   // any struggle → back to 3 parallel streams
            if attempt >= maxAttempts {
                await self.opLogLine("✗ giving up on “\(t.name)” after \(maxAttempts) tries: \(desc)")
                break
            }
            if attempt == 1 {
                await self.opLogLine("… waiting on “\(t.name)”: \(desc)")
            }
            // if the share has dropped, actively re-mount it (guest, directly via
            // the system mounter — never through Finder) at most once per 30s
            // across all workers, itself under a watchdog
            var reconn = ""
            if !addr.isEmpty && !destReachable(dest) && throttle.shouldAttempt() {
                let mountResult = await runBlockingFileOp(timeout: 30, cancel: box) {
                    mountSMBGuest(reconnectAddr)
                }
                let mounted = { if case .success(true) = mountResult { return true }; return false }()
                reconn = mounted ? "  · reconnected to \(reconnectAddr)" : "  · reconnect pending"
                await self.opLogLine(mounted ? "⟳ Reconnected to \(reconnectAddr)" : "⚠ Reconnect to \(reconnectAddr) didn't complete")
            }
            let waitS = min(attempt * 2, 10)   // back off: 2s, 4s … capped at 10s
            await self.setNote("⟳ Retrying “\(t.name)” (attempt \(attempt)): \(desc)\(reconn)  · waiting \(waitS)s")
            var slept = 0.0
            while slept < Double(waitS) && !box.cancelled {
                try? await Task.sleep(nanoseconds: 400_000_000); slept += 0.4
            }
        }
        await self.setNote("")
        if copied {
            let s = sweep ? counters.recordSweepOK() : counters.recordOK(clean: attempt == 0)
            let suffix = attempt > 0 ? "  (after \(attempt) retr\(attempt == 1 ? "y" : "ies"))" : ""
            await self.opStep(done: s.done, ok: s.ok, skip: s.skip, fail: s.fail,
                              line: "\(sweep ? "⟲ swept " : "✓ ")\(sanitizeName(t.displayArtist))/\(sanitizeName(t.album))/\(t.name)\(suffix)")
        } else if !box.cancelled {
            // out of attempts — record it; the lead loop may auto-pause
            let s = sweep ? counters.recordSweepFail(t.id) : counters.recordFail(t.id)
            await self.opStep(done: s.done, ok: s.ok, skip: s.skip, fail: s.fail,
                              line: "✗ \(t.name) — \(sweep ? "still failing after the sweep" : "failed after \(maxAttempts) tries")")
        }
    }

    private func finishCopy(summary: String, failedIDs: [Int]) {
        failedCopyIDs = failedIDs
        opPaused = false
        opFinishLine(summary)
    }
    private func presentConflict(_ c: CopyConflict?) { pendingConflict = c }
}

/// Simple thread-shared cancel flag readable from a background task without hopping actors.
final class CancelBox: @unchecked Sendable {
    var cancelled = false
}

/// Resume flag for the auto-pause (same pattern as CancelBox).
final class ResumeBox: @unchecked Sendable {
    var resumed = false
    func reset() { resumed = false }
}

/// Shared, locked progress counters for the parallel copy workers.
/// Also self-tunes the parallelism: 3 streams normally, stepping up to 4 after
/// a clean stretch and straight back to 3 the moment any retry appears.
final class CopyCounters: @unchecked Sendable {
    struct Snap { let done: Int; let ok: Int; let skip: Int; let fail: Int }
    private let lock = NSLock()
    private var ok = 0, skip = 0, fail = 0, done = 0, consec = 0
    private var failed: [Int] = []
    private var cleanStreak = 0
    private var limit = 3

    var consecutiveFailCount: Int { lock.lock(); defer { lock.unlock() }; return consec }
    func resetConsecutive() { lock.lock(); consec = 0; lock.unlock() }

    /// Current parallel-worker limit (3, or 4 after 20 clean files in a row).
    var currentLimit: Int { lock.lock(); defer { lock.unlock() }; return limit }
    /// Any failed copy attempt (even one that later succeeds) drops back to 3.
    func noteRetry() { lock.lock(); cleanStreak = 0; limit = 3; lock.unlock() }

    func recordOK(clean: Bool) -> Snap {
        lock.lock(); defer { lock.unlock() }
        ok += 1; done += 1; consec = 0
        if clean { cleanStreak += 1; if cleanStreak >= 20 { limit = 4 } }
        else { cleanStreak = 0; limit = 3 }
        return Snap(done: done, ok: ok, skip: skip, fail: fail)
    }
    func recordSkip() -> Snap {
        lock.lock(); defer { lock.unlock() }
        skip += 1; done += 1; consec = 0
        return Snap(done: done, ok: ok, skip: skip, fail: fail)
    }
    func recordFail(_ id: Int) -> Snap {
        lock.lock(); defer { lock.unlock() }
        fail += 1; done += 1; consec += 1; failed.append(id)
        return Snap(done: done, ok: ok, skip: skip, fail: fail)
    }
    /// Start the end-of-run sweep: hand back the failed IDs and clear the list
    /// (sweep results re-populate it; `fail`/`done` already counted these files).
    func beginSweep() -> [Int] {
        lock.lock(); defer { lock.unlock() }
        let f = failed; failed = []; consec = 0
        return f
    }
    func recordSweepOK() -> Snap {
        lock.lock(); defer { lock.unlock() }
        ok += 1; fail -= 1   // it counted as failed; the sweep landed it after all
        return Snap(done: done, ok: ok, skip: skip, fail: fail)
    }
    func recordSweepFail(_ id: Int) -> Snap {
        lock.lock(); defer { lock.unlock() }
        failed.append(id)    // fail/done already counted on the first pass
        return Snap(done: done, ok: ok, skip: skip, fail: fail)
    }
    func finalSnapshot() -> (ok: Int, skip: Int, fail: Int, failedIDs: [Int]) {
        lock.lock(); defer { lock.unlock() }
        return (ok, skip, fail, failed)
    }
}

/// Rate-limits share re-mount attempts to one per 30s across all copy workers —
/// hammering a dead server with mount requests just piles up hung work.
final class MountThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Date?
    func shouldAttempt() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let l = last, Date().timeIntervalSince(l) < 30 { return false }
        last = Date()
        return true
    }
}

// MARK: - Copy-conflict plumbing

/// A file that exists at the destination but differs from the source.
struct CopyConflict: Identifiable {
    let id = UUID()
    let name: String
    let artist: String
    let album: String
    let srcURL: URL
    let srcSize: Int64
    let dstSize: Int64
    let dstDate: Date?
    let identical: Bool     // same size as the source (likely the same file)
}

enum ConflictDecision { case overwrite, skip, overwriteAll, skipAll }

/// Thread-shared decision hand-off between the UI and the copy task —
/// same polling pattern as CancelBox (the copy task polls `take()`).
final class ConflictBox: @unchecked Sendable {
    private let lock = NSLock()
    private var decision: ConflictDecision?
    private var _policy: ConflictDecision?
    var policy: ConflictDecision? {
        get { lock.lock(); defer { lock.unlock() }; return _policy }
        set { lock.lock(); _policy = newValue; lock.unlock() }
    }
    func reset() { lock.lock(); decision = nil; _policy = nil; lock.unlock() }
    func answer(_ d: ConflictDecision) { lock.lock(); decision = d; lock.unlock() }
    func take() -> ConflictDecision? {
        lock.lock(); defer { lock.unlock() }
        let d = decision; decision = nil; return d
    }
}
