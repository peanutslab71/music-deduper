//
//  Engine.swift
//  MusicLibrarian
//
//  Scanning, metadata (AVFoundation), duplicate clustering, keeper selection,
//  and file operations (copy, Trash, permanent delete). No third-party deps.
//

import Foundation
import AVFoundation
import AudioToolbox
import CryptoKit
import AppKit
import NetFS

// MARK: - Models

struct Track: Identifiable, Hashable {
    var id: Int
    var url: URL
    var name: String
    var relDir: String          // path relative to the scanned root, dir only
    var size: Int64
    var ext: String
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var trackNo: Int
    var discNo: Int
    var duration: Double         // seconds
    var lossless: Bool
    var bitrate: Int             // kbps
    var codec: String
    var sig: String? = nil       // content signature (lazy)

    var displayArtist: String { albumArtist.isEmpty ? artist : albumArtist }

    /// Measured bitrate when it read, else derived from size over duration.
    /// AVFoundation's estimatedDataRate comes back 0 for a fair few MP3s (VBR,
    /// or it just can't estimate), which used to score them at 0 and let a
    /// genuinely smaller 128k AAC win the keeper contest against a 320k MP3.
    var effectiveKbps: Double {
        if bitrate > 0 { return Double(bitrate) }
        guard duration > 0, size > 0 else { return 0 }
        return Double(size) * 8 / duration / 1000   // bytes → bits → kbps
    }
    var qualityScore: Double {
        var s = 0.0
        if lossless { s += 100_000 }
        s += effectiveKbps
        if lossless { s += min(Double(size) / 1_000_000, 2000) }
        s += duration * 0.1
        if !albumArtist.isEmpty { s += 5 }
        if !album.isEmpty { s += 5 }
        if !artist.isEmpty { s += 5 }
        if trackNo > 0 { s += 2 }
        return s
    }
    var formatLabel: String {
        (lossless ? "◆ " : "") + codec.uppercased() + (bitrate > 0 ? " \(bitrate)k" : "")
    }
}

struct Cluster: Identifiable {
    let id = UUID()
    var memberIDs: [Int]
    var keeperID: Int
    var reason: String
    var reclaim: Int64
    var title: String
    var artist: String
}

enum MatchMode: String, CaseIterable, Identifiable {
    case strict, balanced, aggressive
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum DeleteMode { case trash, permanent }

// MARK: - Helpers

func fmtBytes(_ n: Int64) -> String {
    if n <= 0 { return "0 B" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = Double(n); var i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    return String(format: (v < 10 && i > 0) ? "%.1f %@" : "%.0f %@", v, units[i])
}

func fmtDur(_ s: Double) -> String {
    if s <= 0 { return "—" }
    let t = Int(s.rounded())
    return String(format: "%d:%02d", t / 60, t % 60)
}

// text normalisation for matching (mirrors the Python version)
func normText(_ raw: String) -> String {
    var s = raw.lowercased()
    s = s.replacingOccurrences(of: #"\(.*?\)|\[.*?\]"#, with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: #"\bfeat\.?\b.*$|\bft\.?\b.*$"#, with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: #"[‘’“”'\"`]"#, with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: "&", with: "and")
    s = s.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: #"\b(the|a|an)\b"#, with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespaces)
}

func normLoose(_ raw: String) -> String {
    normText(raw).replacingOccurrences(
        of: #"\b(remaster(ed)?|mono|stereo|version|edit|deluxe|explicit|album)\b"#,
        with: "", options: .regularExpression
    ).trimmingCharacters(in: .whitespaces)
}

func baseName(_ name: String) -> String {
    var n = name
    if let dot = n.range(of: ".", options: .backwards) { n = String(n[..<dot.lowerBound]) }
    n = n.replacingOccurrences(of: #"(\s*\(\d{1,2}\)|[ _\-]\d{1,2}|[ _\-]*copy)$"#,
                               with: "", options: [.regularExpression, .caseInsensitive])
    return n.trimmingCharacters(in: .whitespaces).lowercased()
}

let losslessExt: Set<String> = ["flac", "alac", "wav", "aif", "aiff", "aifc", "ape", "wv"]
let audioExt: Set<String> = ["mp3", "m4a", "m4b", "aac", "mp4", "flac", "alac",
                             "wav", "aif", "aiff", "aifc", "ogg", "opus", "wma"]

// MARK: - Metadata via AVFoundation

func readMetadata(url: URL, size: Int64) async -> Track {
    let ext = url.pathExtension.lowercased()
    var title = "", artist = "", album = "", albumArtist = ""
    var trackNo = 0, discNo = 0
    var duration = 0.0
    var bitrate = 0
    var codec = ext
    var lossless = losslessExt.contains(ext)

    let asset = AVURLAsset(url: url)
    if let d = try? await asset.load(.duration) {
        let secs = CMTimeGetSeconds(d)
        if secs.isFinite && secs > 0 { duration = secs }
    }
    if let common = try? await asset.load(.commonMetadata) {
        for item in common {
            guard let key = item.commonKey else { continue }
            let sval = try? await item.load(.stringValue)
            switch key {
            case .commonKeyTitle:      if let v = sval { title = v }
            case .commonKeyArtist:     if let v = sval { artist = v }
            case .commonKeyAlbumName:  if let v = sval { album = v }
            case .commonKeyCreator:    if artist.isEmpty, let v = sval { artist = v }
            default: break
            }
        }
    }
    // best-effort album-artist and track number across all metadata formats
    if let formats = try? await asset.load(.availableMetadataFormats) {
        for fmt in formats {
            guard let items = try? await asset.loadMetadata(for: fmt) else { continue }
            for item in items {
                let idStr = item.identifier?.rawValue ?? ""
                if idStr.contains("albumArtist") || idStr.contains("AlbumArtist")
                    || idStr.hasSuffix("TPE2") || idStr.hasSuffix("aART") {
                    if albumArtist.isEmpty, let v = try? await item.load(.stringValue) { albumArtist = v }
                } else if idStr.hasSuffix("trkn") || idStr.hasSuffix("TRCK") || idStr.contains("trackNumber") {
                    if let n = try? await item.load(.numberValue) { trackNo = n.intValue }
                    else if let v = try? await item.load(.stringValue) {
                        trackNo = Int(v.prefix(while: { $0.isNumber })) ?? trackNo
                    }
                } else if idStr.hasSuffix("disk") || idStr.hasSuffix("TPOS") || idStr.contains("discNumber") {
                    if let n = try? await item.load(.numberValue) { discNo = n.intValue }
                }
            }
        }
    }
    // audio track: bitrate + codec + lossless detection
    if let atrack = try? await asset.loadTracks(withMediaType: .audio).first {
        if let rate = try? await atrack.load(.estimatedDataRate), rate.isFinite, rate > 0 {
            bitrate = Int(rate / 1000)
        }
        if let descs = try? await atrack.load(.formatDescriptions), let desc = descs.first {
            let subtype = CMFormatDescriptionGetMediaSubType(desc)
            switch subtype {
            case kAudioFormatAppleLossless: lossless = true;  codec = "alac"
            case kAudioFormatFLAC:          lossless = true;  codec = "flac"
            case kAudioFormatLinearPCM:     lossless = true
            case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE: lossless = false; codec = "aac"
            case kAudioFormatMPEGLayer3:    lossless = false; codec = "mp3"
            default: break
            }
        }
    }

    if title.isEmpty {
        title = url.deletingPathExtension().lastPathComponent
    }
    return Track(id: 0, url: url, name: url.lastPathComponent, relDir: "",
                 size: size, ext: ext, title: title, artist: artist, album: album,
                 albumArtist: albumArtist, trackNo: trackNo, discNo: discNo,
                 duration: duration, lossless: lossless, bitrate: bitrate, codec: codec)
}

// MARK: - Content signature (exact-dup confirmation)

func contentSig(url: URL, size: Int64) -> String? {
    guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? fh.close() }
    var hasher = SHA256()
    let chunk = 64 * 1024
    if let head = try? fh.read(upToCount: chunk) { hasher.update(data: head) }
    if size > Int64(chunk) {
        try? fh.seek(toOffset: UInt64(max(0, size - Int64(chunk))))
        if let tail = try? fh.read(upToCount: chunk) { hasher.update(data: tail) }
    }
    hasher.update(data: Data(String(size).utf8))
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

// MARK: - Clustering

func buildClusters(_ tracks: inout [Track], mode: MatchMode, tol: Double,
                   crossAlbum: Bool, progress: (@Sendable (String) -> Void)? = nil) -> [Cluster] {
    struct N { let i: Int; let a: String; let ti: String; let al: String; let base: String }
    let normed: [N] = tracks.map { t in
        let a = (mode == .aggressive) ? normLoose(t.displayArtist) : normText(t.displayArtist)
        let ti = (mode == .aggressive) ? normLoose(t.title) : normText(t.title)
        return N(i: t.id, a: a, ti: ti, al: normText(t.album), base: baseName(t.name))
    }
    var buckets: [String: [N]] = [:]
    for n in normed { buckets[n.a + "\u{0}" + n.ti, default: []].append(n) }

    // which tracks need a content signature
    var needSig = Set<Int>()
    for arr in buckets.values where arr.count > 1 { for n in arr { needSig.insert(n.i) } }
    if mode == .strict { needSig = Set(tracks.map { $0.id }) }
    var done = 0
    for i in needSig {
        if tracks[i].sig == nil {
            tracks[i].sig = contentSig(url: tracks[i].url, size: tracks[i].size) ?? "ERR\(i)"
        }
        done += 1
        if done % 40 == 0 { progress?("Fingerprinting \(done)/\(needSig.count)") }
    }

    var clusters: [Cluster] = []
    var used = Set<Int>()

    func make(_ ids: [Int], _ reason: String) -> Cluster {
        let sorted = ids.sorted { tracks[$0].qualityScore > tracks[$1].qualityScore }
        let keeper = sorted[0]
        let reclaim = sorted.dropFirst().reduce(Int64(0)) { $0 + tracks[$1].size }
        return Cluster(memberIDs: sorted, keeperID: keeper, reason: reason, reclaim: reclaim,
                       title: tracks[keeper].title, artist: tracks[keeper].displayArtist)
    }

    // 1) exact byte-signature groups
    var bySig: [String: [Int]] = [:]
    for t in tracks {
        if let s = t.sig, !s.hasPrefix("ERR") { bySig[s, default: []].append(t.id) }
    }
    for ids in bySig.values where ids.count > 1 {
        clusters.append(make(ids, "identical bytes")); used.formUnion(ids)
    }

    if mode != .strict {
        // 2) metadata + duration groups
        for arr in buckets.values {
            let items = arr.filter { !used.contains($0.i) && !$0.ti.isEmpty }
            if items.count < 2 { continue }
            for x in 0..<items.count {
                let a = items[x]
                if used.contains(a.i) { continue }
                var group = [a.i]; used.insert(a.i)
                let ta = tracks[a.i]
                for y in (x + 1)..<items.count {
                    let b = items[y]
                    if used.contains(b.i) { continue }
                    let tb = tracks[b.i]
                    let durOK: Bool
                    if ta.duration > 0 && tb.duration > 0 { durOK = abs(ta.duration - tb.duration) <= tol }
                    else { durOK = (mode == .aggressive) }
                    if !durOK { continue }
                    let albumOK = crossAlbum || mode == .aggressive || a.al == b.al || a.al.isEmpty || b.al.isEmpty
                    let copyOK = a.base == b.base
                    let sigOK = ta.sig != nil && ta.sig == tb.sig
                    if albumOK || copyOK || sigOK { group.append(b.i); used.insert(b.i) }
                }
                if group.count > 1 { clusters.append(make(group, "same title/artist/length")) }
                else { used.remove(a.i) }
            }
        }
        // 3) filename-copy net (same dir + base + ext)
        var byDir: [String: [Int]] = [:]
        for t in tracks where !used.contains(t.id) {
            byDir[t.relDir + "\u{0}" + baseName(t.name) + "\u{0}" + t.ext, default: []].append(t.id)
        }
        for ids in byDir.values where ids.count > 1 {
            clusters.append(make(ids, "filename copy")); used.formUnion(ids)
        }
    }

    clusters.sort { $0.reclaim > $1.reclaim }
    return clusters
}

// MARK: - File operations

func sanitizeName(_ s: String) -> String {
    var out = s.replacingOccurrences(of: #"[\\/:*?\"<>|]"#, with: "_", options: .regularExpression)
    out = out.trimmingCharacters(in: .whitespaces)
    if out.count > 120 { out = String(out.prefix(120)) }
    return out.isEmpty ? "_" : out
}

// MARK: - Blocking file ops with a watchdog

/// Hand-off box for a blocking operation running on a disposable thread.
final class BlockingResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    func set(_ r: Result<T, Error>) { lock.lock(); if result == nil { result = r }; lock.unlock() }
    func get() -> Result<T, Error>? { lock.lock(); defer { lock.unlock() }; return result }
}

/// Run a blocking file operation (stat/copy on a network share can hang inside
/// the OS for minutes) on its own throwaway thread, with a deadline. Returns
/// the operation's result, or nil if it timed out or was cancelled — in which
/// case the thread is abandoned and whatever it eventually returns is ignored.
func runBlockingFileOp<T>(timeout: TimeInterval, cancel: CancelBox,
                          _ work: @escaping @Sendable () throws -> T) async -> Result<T, Error>? {
    let box = BlockingResultBox<T>()
    Thread.detachNewThread {
        do { box.set(.success(try work())) } catch { box.set(.failure(error)) }
    }
    var waited = 0.0
    while waited < timeout {
        if let r = box.get() { return r }
        if cancel.cancelled { return nil }
        try? await Task.sleep(nanoseconds: 250_000_000)
        waited += 0.25
    }
    return box.get()   // one last look before declaring it hung
}

// MARK: - SMB mount helpers (guest)

/// True if the destination is currently reachable (mount is alive).
func destReachable(_ url: URL) -> Bool {
    return (try? url.checkResourceIsReachable()) == true
}

/// Resolve a hostname to its IPv4 address using the system resolver.
/// Returns nil if it can't be resolved. May block for a few seconds — call
/// off the main thread, and ideally while the network is healthy.
func resolveIPv4(_ host: String) -> String? {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &res) == 0, let r = res else { return nil }
    defer { freeaddrinfo(r) }
    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    guard getnameinfo(r.pointee.ai_addr, r.pointee.ai_addrlen,
                      &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
    return String(cString: buf)
}

/// Rewrite an SMB address ("rock/Data", "smb://rock/Data") to use the host's
/// IPv4 address ("smb://192.168.1.128/Data"), so a re-mount doesn't also depend
/// on name lookup. Returns nil if the host is already an IP or can't be resolved
/// (bare names are also tried with ".local" appended, for mDNS-only hosts).
func ipVersionOfSMBAddress(_ address: String) -> String? {
    var s = address.trimmingCharacters(in: .whitespaces)
    guard !s.isEmpty else { return nil }
    if s.lowercased().hasPrefix("smb://") { s.removeFirst(6) }
    let parts = s.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    // strip any login prefix ("GUEST:@rock" → "rock") — Finder-captured
    // remount addresses include it
    let hostPart = String(parts[0])
    let host = hostPart.contains("@") ? String(hostPart.split(separator: "@").last ?? "") : hostPart
    let path = parts.count > 1 ? "/" + parts[1] : ""
    guard !host.isEmpty else { return nil }
    var addr4 = in_addr()
    if inet_pton(AF_INET, host, &addr4) == 1 { return nil }   // already an IP
    let ip = resolveIPv4(host) ?? (host.contains(".") ? nil : resolveIPv4(host + ".local"))
    guard let ip else { return nil }
    return "smb://" + ip + path
}

/// (Re)mount an SMB share as guest, directly through the system mounter (NetFS).
/// This deliberately does NOT go through Finder ("open smb://…" hands the mount
/// to Finder's machinery, which piles work onto Finder exactly when the server
/// is dead and Finder is already struggling). Blocking — call under a watchdog.
/// Returns true if the share is mounted when the call returns.
@discardableResult
func mountSMBGuest(_ address: String) -> Bool {
    var s = address.trimmingCharacters(in: .whitespaces)
    guard !s.isEmpty else { return false }
    if !s.lowercased().hasPrefix("smb://") { s = "smb://" + s }
    guard let url = URL(string: s) else { return false }
    let openOpts = NSMutableDictionary()
    openOpts[kNetFSUseGuestKey] = true
    openOpts[kNAUIOptionKey] = kNAUIOptionNoUI      // never pop a login dialog
    let mountOpts = NSMutableDictionary()
    mountOpts[kNetFSSoftMountKey] = true            // soft: error out rather than hang forever
    let rc = NetFSMountURLSync(url as CFURL, nil, nil, nil, openOpts, mountOpts, nil)
    return rc == 0 || rc == EEXIST                  // EEXIST: already mounted — fine
}
