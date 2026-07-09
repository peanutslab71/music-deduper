//
//  DirectSMB.swift
//  MusicDeduper
//
//  The app's own network layer: an in-process SMB2 client (libsmb2 via the
//  AMSMB2 wrapper) that talks directly to the server over TCP. No kernel
//  mount, no Finder, no /Volumes — the app owns timeouts, reconnects and
//  error reporting, which is exactly what old servers (Roon ROCK runs a
//  2015 Samba capped at dialect 2.002, with no session recovery features)
//  need from a client.
//

import Foundation
import Network
import AMSMB2

/// One server + one share, guest login. Thread-safe; any operation that finds
/// the connection dead throws, the caller drops it with `dropConnection()`,
/// and the next operation dials fresh.
final class DirectSMBClient: @unchecked Sendable {
    let host: String
    let share: String
    private let lock = NSLock()
    private var manager: SMB2Manager?

    /// Accepts the addresses we already store: "smb://GUEST:@rock/Data",
    /// "smb://192.168.1.128/Data", "rock/Data".
    init?(address: String) {
        var s = address.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("smb://") { s = "smb://" + s }
        guard let u = URL(string: s), var h = u.host else { return nil }
        if h.contains("@") { h = String(h.split(separator: "@").last ?? "") }
        let comps = u.path.split(separator: "/")
        guard let shareName = comps.first, !h.isEmpty else { return nil }
        self.host = h
        self.share = String(shareName)
    }

    /// Map a path under the kernel mount to a share-relative path:
    /// "/Volumes/Data/Storage/x.mp3" → "Storage/x.mp3".
    /// Handles macOS's "Data-1"-style duplicate mount names. Nil if the URL
    /// isn't under a mount of this share.
    func shareRelative(_ url: URL) -> String? {
        let p = url.path
        guard p.hasPrefix("/Volumes/") else { return nil }
        let rest = p.dropFirst("/Volumes/".count)
        guard let slash = rest.firstIndex(of: "/") else {
            // the share root itself
            return rest.lowercased().hasPrefix(share.lowercased()) ? "" : nil
        }
        let vol = rest[..<slash].lowercased()
        guard vol == share.lowercased() || vol.hasPrefix(share.lowercased() + "-") else { return nil }
        return String(rest[rest.index(after: slash)...])
    }

    private var current: SMB2Manager? {
        lock.lock(); defer { lock.unlock() }
        return manager
    }

    /// Forget the session; the next operation reconnects from scratch.
    func dropConnection() {
        lock.lock(); manager = nil; lock.unlock()
    }

    func connect(timeout: TimeInterval = 30) async throws {
        guard let url = URL(string: "smb://\(host)"),
              let m = SMB2Manager(url: url,
                                  credential: URLCredential(user: "guest", password: "",
                                                            persistence: .forSession)) else {
            throw Self.error("couldn't create a connection to \(host)")
        }
        m.timeout = timeout
        try await m.connectShare(name: share)
        lock.lock(); manager = m; lock.unlock()
    }

    private func ensure() async throws -> SMB2Manager {
        if let m = current { return m }
        try await connect()
        guard let m = current else { throw Self.error("not connected") }
        return m
    }

    var isConnected: Bool { current != nil }

    /// Protocol-level keep-alive (a real SMB ECHO, not a directory nudge).
    func keepAlive() async {
        guard let m = current else { return }
        do { try await m.echo() } catch { dropConnection() }
    }

    /// List a folder: name → size. A missing folder returns empty.
    func listSizes(dir: String) async throws -> [String: Int64] {
        let m = try await ensure()
        let items: [[URLResourceKey: Any]]
        do { items = try await m.contentsOfDirectory(atPath: dir) }
        catch { return [:] }   // most likely: folder doesn't exist yet
        var out: [String: Int64] = [:]
        for it in items {
            guard let name = it[.nameKey] as? String else { continue }
            out[name] = Self.asInt64(it[.fileSizeKey])
        }
        return out
    }

    /// Create a folder path, one level at a time ("already exists" is fine —
    /// anything real resurfaces on the write).
    func mkdirs(_ path: String) async throws {
        guard !path.isEmpty else { return }
        let m = try await ensure()
        var built = ""
        for comp in path.split(separator: "/") {
            built += (built.isEmpty ? "" : "/") + comp
            do { try await m.createDirectory(atPath: built) }
            catch { }
        }
    }

    /// Size of a remote file, nil if it doesn't exist.
    func fileSize(_ path: String) async throws -> Int64? {
        let m = try await ensure()
        do {
            let attrs = try await m.attributesOfItem(atPath: path)
            return Self.asInt64(attrs[.fileSizeKey])
        } catch { return nil }
    }

    func remove(_ path: String) async {
        guard let m = current else { return }
        try? await m.removeFile(atPath: path)
    }

    /// Upload a local file to a remote path (any existing file at the path
    /// is removed first).
    func upload(local: URL, to path: String) async throws {
        let m = try await ensure()
        try? await m.removeFile(atPath: path)
        try await m.uploadItem(at: local, toPath: path, progress: nil)
    }

    /// Rename, replacing any existing destination.
    func rename(_ from: String, to: String) async throws {
        let m = try await ensure()
        try? await m.removeFile(atPath: to)
        try await m.moveItem(atPath: from, toPath: to)
    }

    /// Linux stores filenames composed (NFC); the Mac hands us decomposed
    /// (NFD). Normalize every path component we send, or accented names
    /// ("Dvořák") end up as mismatched duplicates.
    static func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

    static func error(_ msg: String) -> NSError {
        NSError(domain: "DirectSMB", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    /// A sibling connection to the same server/share — used by the pool so
    /// parallel copy workers each get their own TCP session instead of
    /// queueing behind one socket.
    func sibling() -> DirectSMBClient? {
        DirectSMBClient(address: "smb://\(host)/\(share)")
    }

    private static func asInt64(_ v: Any?) -> Int64 {
        if let n = v as? Int64 { return n }
        if let n = v as? Int { return Int64(n) }
        if let n = v as? NSNumber { return n.int64Value }
        return 0
    }
}

extension DirectSMBClient {
    /// Ask a server which shares it offers (guest login). System shares
    /// (IPC$ and friends) are filtered out.
    static func listShares(host: String, timeout: TimeInterval = 15) async throws -> [String] {
        guard let url = URL(string: "smb://\(host)"),
              let m = SMB2Manager(url: url,
                                  credential: URLCredential(user: "guest", password: "",
                                                            persistence: .forSession)) else {
            throw error("couldn't reach \(host)")
        }
        m.timeout = timeout
        let shares = try await m.listShares()
        return shares.map(\.name).filter { !$0.hasSuffix("$") }
    }
}

/// Finds SMB servers announcing themselves on the local network (Bonjour).
@MainActor
final class SMBServerBrowser: ObservableObject {
    @Published var servers: [String] = []   // advertised names, e.g. "rock"
    private var browser: NWBrowser?

    func start() {
        stop()
        let b = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { r -> String? in
                if case .service(let name, _, _, _) = r.endpoint { return name }
                return nil
            }.sorted()
            Task { @MainActor in self?.servers = names }
        }
        b.start(queue: .main)
        browser = b
    }
    func stop() { browser?.cancel(); browser = nil }
}

/// A small pool of independent connections to one share. Each parallel copy
/// worker checks a client out for the duration of its file, so N workers run
/// on N TCP sessions — on high-latency links (Wi-Fi + old dialects that cap
/// requests at 64KB) this is the difference between queueing and parallelism.
final class DirectSMBPool: @unchecked Sendable {
    private let lock = NSLock()
    private var idle: [DirectSMBClient] = []
    private let template: DirectSMBClient

    init(template: DirectSMBClient) {
        self.template = template
    }

    func acquire() -> DirectSMBClient {
        lock.lock()
        let c = idle.popLast()
        lock.unlock()
        return c ?? template.sibling() ?? template
    }

    func release(_ c: DirectSMBClient) {
        guard c !== template else { return }
        lock.lock()
        if idle.count < 8 { idle.append(c) } // else drop; its session just closes
        lock.unlock()
    }

    /// Keep every pooled session alive with a protocol-level echo.
    func keepAliveAll() async {
        lock.lock(); let clients = idle; lock.unlock()
        await template.keepAlive()
        for c in clients { await c.keepAlive() }
    }
}
