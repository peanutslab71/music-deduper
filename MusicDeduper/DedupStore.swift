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

    private func opStart(title: String, total: Int) {
        cancelBox.cancelled = false
        opActive = true; opFinished = false; opTitle = title
        opTotal = total; opDone = 0; opOK = 0; opSkip = 0; opFail = 0; opLog = []; opNote = ""
        busy = true
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
        opFinishLine(summary)
    }

    // MARK: Copy keepers

    func copyKeepers(to dest: URL) {
        let keepers = keeperTracks
        opStart(title: "Copying \(keepers.count) keeper(s) → \(dest.lastPathComponent)", total: keepers.count)
        let box = cancelBox
        let conflicts = conflictBox
        conflicts.reset()
        let addr = smbAddress
        Task.detached(priority: .userInitiated) {
            var ok = 0, skip = 0, fail = 0, cancelled = false
            let fm = FileManager.default
            for (n, t) in keepers.enumerated() {
                if box.cancelled { cancelled = true; break }
                let dir = dest.appendingPathComponent(sanitizeName(t.displayArtist.isEmpty ? "Unknown Artist" : t.displayArtist))
                                .appendingPathComponent(sanitizeName(t.album.isEmpty ? "Unknown Album" : t.album))
                let target = dir.appendingPathComponent(t.name)

                // already present with matching size → skip, no copy
                if let vals = try? target.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                   let exSize = vals.fileSize {
                    if Int64(exSize) == t.size {
                        skip += 1
                        await self.opStep(done: n + 1, ok: ok, skip: skip, fail: fail, line: "• skip \(t.name)")
                        continue
                    }
                    // exists but DIFFERS → pause and ask (unless an All policy is set)
                    var decision = conflicts.policy
                    if decision == nil {
                        await self.presentConflict(CopyConflict(
                            name: t.name,
                            artist: t.displayArtist, album: t.album,
                            srcURL: t.url, srcSize: t.size,
                            dstSize: Int64(exSize), dstDate: vals.contentModificationDate))
                        while !box.cancelled {
                            if let d = conflicts.take() { decision = d; break }
                            try? await Task.sleep(nanoseconds: 200_000_000)
                        }
                        await self.presentConflict(nil)
                        if box.cancelled { cancelled = true; break }
                    }
                    if decision == .skip || decision == .skipAll {
                        skip += 1
                        await self.opStep(done: n + 1, ok: ok, skip: skip, fail: fail, line: "• kept existing \(t.name)")
                        continue
                    }
                    // overwrite falls through to the copy below (target removed there)
                }

                // Retry this file until it succeeds — never skip. Only Cancel breaks out.
                var copied = false
                var attempt = 0
                while !box.cancelled {
                    do {
                        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                        if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
                        try fm.copyItem(at: t.url, to: target)
                        copied = true; break
                    } catch {
                        attempt += 1
                        let waitS = min(attempt * 2, 10)   // back off: 2s, 4s … capped at 10s
                        // log the first stall on this file
                        if attempt == 1 {
                            await self.opLogLine("… waiting on “\(t.name)”: \(error.localizedDescription)")
                        }
                        // if the share has dropped, actively re-mount it (guest) so we self-heal
                        var reconn = ""
                        if !addr.isEmpty && !destReachable(dest) {
                            let launched = mountSMBGuest(addr)
                            reconn = launched ? "  · reconnecting to \(addr)…" : "  · reconnect failed"
                            await self.opLogLine(launched ? "⟳ Reconnecting to \(addr)…" : "⚠ Reconnect to \(addr) failed")
                        }
                        await self.setNote("⟳ Retrying “\(t.name)” (attempt \(attempt)): \(error.localizedDescription)\(reconn)  · waiting \(waitS)s")
                        var slept = 0.0
                        while slept < Double(waitS) && !box.cancelled {
                            try? await Task.sleep(nanoseconds: 400_000_000); slept += 0.4
                        }
                    }
                }
                await self.setNote("")
                if copied {
                    ok += 1
                    let suffix = attempt > 0 ? "  (after \(attempt) retr\(attempt == 1 ? "y" : "ies"))" : ""
                    await self.opStep(done: n + 1, ok: ok, skip: skip, fail: fail,
                                      line: "✓ \(sanitizeName(t.displayArtist))/\(sanitizeName(t.album))/\(t.name)\(suffix)")
                } else {
                    cancelled = true; break   // reached only when the user cancels
                }
            }
            let summary = cancelled
                ? "■ Cancelled — copied \(ok), skipped \(skip)."
                : "✔ Done — copied \(ok), skipped \(skip)" + (fail > 0 ? ", \(fail) failed." : ".")
            await self.opFinishLine(summary)
        }
    }
    private func presentConflict(_ c: CopyConflict?) { pendingConflict = c }
}

/// Simple thread-shared cancel flag readable from a background task without hopping actors.
final class CancelBox: @unchecked Sendable {
    var cancelled = false
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
