//
//  Perfect.swift
//  MusicDeduper
//
//  "Perfect" — library restoration. Phase 1 (Tidy): scan a library, diagnose
//  fixable problems, review them, and commit the approved ones — removing
//  items to a recoverable quarantine and writing a before/after change log.
//
//  This first slice handles the unambiguous, locally-detectable classes:
//  junk files, empty folders, and DRM (protected) tracks. Duplicate-folder
//  merges, illegal-character renames, duplicate-recording handling, and the
//  identify/tag phases build on this.
//

import Foundation
import AVFoundation
import SwiftUI

// MARK: - Model

enum FixKind: String {
    case junk           // OS litter / temp / orphan files
    case emptyFolder    // folder with no files anywhere inside
    case drm            // FairPlay-protected, unplayable

    var title: String {
        switch self {
        case .junk:        return "Remove junk files"
        case .emptyFolder: return "Delete empty folders"
        case .drm:         return "Protected (DRM) tracks"
        }
    }
    var safe: Bool { self != .drm }   // drm is informational, never removed
}

struct PerfectFinding: Identifiable {
    let id = UUID()
    let kind: FixKind
    let url: URL
    let relPath: String     // path relative to the library root
    let detail: String      // short reason / description
    let bytes: Int64
    var accepted: Bool
}

// MARK: - Store

@MainActor
final class PerfectStore: ObservableObject {
    @Published var root: URL?
    @Published var status = "Choose a music library to diagnose."
    @Published var busy = false
    @Published var progress = ""
    @Published var findings: [PerfectFinding] = []
    @Published var diagnosed = false

    // commit-result summary
    @Published var lastRunSummary: String?
    @Published var lastQuarantine: URL?

    private let cancelFlag = CancelBox()

    // scanned totals for the header
    @Published var totalFiles = 0
    @Published var totalFolders = 0
    @Published var totalBytes: Int64 = 0

    func setRoot(_ url: URL) {
        root = url
        findings = []
        diagnosed = false
        lastRunSummary = nil
        status = "Ready to diagnose \(url.lastPathComponent)."
    }

    func pickRoot() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Choose"
        p.message = "Choose the music library to make perfect"
        if p.runModal() == .OK, let url = p.url { setRoot(url) }
    }

    // findings grouped by kind, in display order
    var groups: [(kind: FixKind, items: [PerfectFinding])] {
        let order: [FixKind] = [.junk, .emptyFolder, .drm]
        return order.compactMap { k in
            let items = findings.filter { $0.kind == k }
            return items.isEmpty ? nil : (k, items)
        }
    }
    var acceptedCount: Int { findings.filter { $0.accepted && $0.kind.safe }.count }

    // MARK: Diagnose

    func diagnose() {
        guard let root else { return }
        busy = true; diagnosed = false; findings = []
        status = "Diagnosing…"; progress = ""
        cancelFlag.cancelled = false
        let box = cancelFlag
        Task.detached(priority: .userInitiated) {
            var found: [PerfectFinding] = []
            var files = 0, folders = 0
            var bytes: Int64 = 0
            let fm = FileManager.default

            // Enumerate everything once. Track which directories contain any file
            // (anywhere below) so we can flag the truly-empty ones afterwards.
            var dirHasContent = Set<String>()
            var allDirs: [URL] = []

            if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                      options: []) {
                for case let u as URL in en {
                    if box.cancelled { break }
                    let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    if v?.isDirectory == true {
                        folders += 1
                        allDirs.append(u)
                        continue
                    }
                    files += 1
                    let size = Int64(v?.fileSize ?? 0)
                    bytes += size
                    let rel = Self.rel(u, root)

                    // mark every ancestor directory as having content
                    var p = u.deletingLastPathComponent()
                    while p.path.count >= root.path.count {
                        dirHasContent.insert(p.path)
                        if p.path == root.path { break }
                        p = p.deletingLastPathComponent()
                    }

                    if let junkReason = Self.junkReason(u) {
                        found.append(PerfectFinding(kind: .junk, url: u, relPath: rel,
                                                    detail: junkReason, bytes: size, accepted: true))
                    } else if Self.isAudio(u), Self.isDRM(u) {
                        found.append(PerfectFinding(kind: .drm, url: u, relPath: rel,
                                                    detail: "FairPlay-protected — most players can't play this",
                                                    bytes: size, accepted: false))
                    }
                    if files % 50 == 0 {
                        await self.setProgress("Scanned \(files) files…")
                    }
                }
            }

            // empty folders = directories with no file anywhere inside
            for d in allDirs where !dirHasContent.contains(d.path) {
                found.append(PerfectFinding(kind: .emptyFolder, url: d, relPath: Self.rel(d, root),
                                            detail: "No audio or files inside", bytes: 0, accepted: true))
            }

            let (ff, fo, fb) = (files, folders, bytes)
            await self.finishDiagnose(found: found, files: ff, folders: fo, bytes: fb, cancelled: box.cancelled)
        }
    }

    private func setProgress(_ s: String) { progress = s }

    private func finishDiagnose(found: [PerfectFinding], files: Int, folders: Int, bytes: Int64, cancelled: Bool) {
        findings = found.sorted { $0.relPath.lowercased() < $1.relPath.lowercased() }
        totalFiles = files; totalFolders = folders; totalBytes = bytes
        busy = false; diagnosed = !cancelled; progress = ""
        let junk = found.filter { $0.kind == .junk }.count
        let empties = found.filter { $0.kind == .emptyFolder }.count
        let drm = found.filter { $0.kind == .drm }.count
        status = cancelled
            ? "Diagnosis cancelled."
            : "\(files) files · \(folders) folders · \(fmtBytes(bytes)) — found \(junk) junk, \(empties) empty folder(s), \(drm) protected track(s)."
    }

    func cancel() { cancelFlag.cancelled = true }

    // MARK: Commit — quarantine accepted safe items + write a change log

    func commit() {
        guard let root else { return }
        let toRemove = findings.filter { $0.accepted && $0.kind.safe }
        guard !toRemove.isEmpty else { return }
        busy = true; status = "Applying changes…"
        let items = toRemove.map { ($0.url, $0.relPath, $0.kind) }
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let stamp = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }()
            let quarantine = root.appendingPathComponent("Music Librarian Quarantine/\(stamp)", isDirectory: true)
            try? fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
            var log = "Music Librarian — change log \(Date())\nLibrary: \(root.path)\n\n"
            var moved = 0, failed = 0

            // move deepest paths first so removing a folder doesn't orphan a
            // child move (empties last after their contents)
            let ordered = items.sorted { $0.1.count > $1.1.count }
            for (url, rel, kind) in ordered {
                guard fm.fileExists(atPath: url.path) else { continue }
                let dest = quarantine.appendingPathComponent(rel)
                do {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: url, to: dest)
                    moved += 1
                    log += "QUARANTINED (\(kind.rawValue)): \(rel)\n"
                } catch {
                    failed += 1
                    log += "FAILED to move \(rel): \(error.localizedDescription)\n"
                }
            }
            log += "\n\(moved) item(s) moved to quarantine, \(failed) failed.\nRestore by moving items back from this folder.\n"
            try? log.write(to: quarantine.appendingPathComponent("changelog.txt"), atomically: true, encoding: .utf8)

            await self.finishCommit(moved: moved, failed: failed, quarantine: quarantine)
        }
    }

    private func finishCommit(moved: Int, failed: Int, quarantine: URL) {
        busy = false
        lastQuarantine = quarantine
        lastRunSummary = "Moved \(moved) item(s) to quarantine" + (failed > 0 ? ", \(failed) failed." : ".")
        // drop the removed findings and re-flag state
        findings.removeAll { $0.accepted && $0.kind.safe }
        status = lastRunSummary ?? status
    }

    // MARK: Detection helpers

    nonisolated static func rel(_ u: URL, _ root: URL) -> String {
        let p = u.path, base = root.path
        if p.hasPrefix(base) {
            var r = String(p.dropFirst(base.count))
            if r.hasPrefix("/") { r.removeFirst() }
            return r
        }
        return u.lastPathComponent
    }

    nonisolated static func junkReason(_ u: URL) -> String? {
        let name = u.lastPathComponent
        if name == ".DS_Store" { return "macOS folder metadata" }
        if name.hasPrefix("._") { return "macOS AppleDouble metadata" }
        if name == "Thumbs.db" || name == "desktop.ini" { return "Windows metadata" }
        if name.hasSuffix(".crswap") { return "leftover temporary file" }
        if name.contains("smbdelete") { return "leftover server-delete marker" }
        return nil
    }

    nonisolated static let audioExts: Set<String> = ["mp3","m4a","m4p","aac","flac","wav","aiff","aif","alac","ogg","wma","opus"]
    nonisolated static func isAudio(_ u: URL) -> Bool { audioExts.contains(u.pathExtension.lowercased()) }

    /// FairPlay-protected content is reported by AVFoundation directly.
    nonisolated static func isDRM(_ u: URL) -> Bool {
        if u.pathExtension.lowercased() == "m4p" { return true }   // fast path
        let ext = u.pathExtension.lowercased()
        guard ext == "m4a" || ext == "mp4" || ext == "aac" else { return false }
        return AVURLAsset(url: u).hasProtectedContent
    }
}
