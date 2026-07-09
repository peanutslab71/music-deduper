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

    struct Entry: Identifiable, Hashable {
        let name: String
        let isDir: Bool
        let size: Int64
        let date: Date?
        var id: String { name }
    }

    /// Full listing of a folder — files and folders, sizes and dates
    /// (dot-entries hidden). Folders first, then by name.
    func listEntries(dir: String) async throws -> [Entry] {
        let m = try await ensure()
        let items = try await m.contentsOfDirectory(atPath: dir)
        return items.compactMap { it -> Entry? in
            guard let name = it[.nameKey] as? String, !name.hasPrefix(".") else { return nil }
            let isDir = (it[.isDirectoryKey] as? Bool)
                ?? ((it[.fileResourceTypeKey] as? URLFileResourceType) == .directory)
            return Entry(name: name, isDir: isDir,
                         size: Self.asInt64(it[.fileSizeKey]),
                         date: it[.contentModificationDateKey] as? Date)
        }
        .sorted {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.lowercased() < $1.name.lowercased()
        }
    }

    /// Create one folder, surfacing the real error (unlike mkdirs, which is
    /// deliberately forgiving for copy destinations).
    func createFolder(_ path: String) async throws {
        try await ensure().createDirectory(atPath: path)
    }

    /// Rename/move that refuses to replace anything — the manager's version.
    func moveNoReplace(_ from: String, to: String) async throws {
        let m = try await ensure()
        if (try? await m.attributesOfItem(atPath: to)) != nil {
            throw Self.error("“\((to as NSString).lastPathComponent)” already exists there")
        }
        try await m.moveItem(atPath: from, toPath: to)
    }

    /// List just the sub-folders of a folder (dot-folders hidden), sorted.
    /// "" lists the share root.
    func listFolders(dir: String) async throws -> [String] {
        let m = try await ensure()
        let items = try await m.contentsOfDirectory(atPath: dir)
        return items.compactMap { it -> String? in
            guard let name = it[.nameKey] as? String, !name.hasPrefix(".") else { return nil }
            let isDir = (it[.isDirectoryKey] as? Bool)
                ?? ((it[.fileResourceTypeKey] as? URLFileResourceType) == .directory)
            return isDir ? name : nil
        }
        .sorted { $0.lowercased() < $1.lowercased() }
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

struct SMBServer: Identifiable, Hashable {
    let host: String        // what we connect to (name.local or IP)
    let display: String     // what the user sees
    var id: String { host }
}

/// Finds SMB servers two ways at once: Bonjour (modern Macs/NASes advertise
/// there) AND an active sweep of the local subnet for machines answering on
/// the SMB port — old servers like Roon ROCK's 2015 Samba only announce via
/// NetBIOS, which Bonjour never sees, but they all answer port 445.
@MainActor
final class SMBServerBrowser: ObservableObject {
    @Published var servers: [SMBServer] = []
    @Published var scanning = false
    private var browser: NWBrowser?
    private var probes: [NWConnection] = []

    func start() {
        stop()
        // 1) Bonjour
        let b = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { r -> SMBServer? in
                if case .service(let name, _, _, _) = r.endpoint {
                    return SMBServer(host: name + ".local", display: name)
                }
                return nil
            }
            Task { @MainActor in
                guard let self else { return }
                for s in found where !self.servers.contains(where: { $0.host == s.host }) {
                    self.servers.append(s)
                    self.servers.sort { $0.display.lowercased() < $1.display.lowercased() }
                }
            }
        }
        b.start(queue: .main)
        browser = b
        // 2) subnet sweep for port 445
        scanSubnet()
    }

    func stop() {
        browser?.cancel(); browser = nil
        for p in probes { p.cancel() }
        probes = []
        scanning = false
    }

    private func scanSubnet() {
        guard let (base, myIP) = Self.localIPv4Base() else { return }
        scanning = true
        let queue = DispatchQueue(label: "smb-scan", attributes: .concurrent)
        var remaining = 0
        for i in 1...254 {
            let ip = "\(base).\(i)"
            if ip == myIP { continue }
            remaining += 1
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = 2
            let conn = NWConnection(host: NWEndpoint.Host(ip), port: 445,
                                    using: NWParameters(tls: nil, tcp: tcp))
            conn.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready:
                    conn.cancel()
                    Task { @MainActor in self?.addScanned(ip: ip) }
                    Task { @MainActor in self?.probeDone() }
                case .failed:
                    conn.cancel()
                    Task { @MainActor in self?.probeDone() }
                default:
                    break
                }
            }
            probes.append(conn)
            conn.start(queue: queue)
        }
        let total = remaining
        Task { @MainActor in self.probeTotal = total }
    }

    private var probeTotal = 0
    private var probeCount = 0
    private func probeDone() {
        probeCount += 1
        if probeCount >= probeTotal { scanning = false }
    }

    private func addScanned(ip: String) {
        guard !servers.contains(where: { $0.host == ip }) else { return }
        // don't duplicate a Bonjour entry that resolves to this same box
        let name = Self.reverseName(ip)
        if let name, servers.contains(where: { $0.display.lowercased() == name.split(separator: ".").first.map(String.init)?.lowercased() ?? "" }) {
            return
        }
        let short = name?.split(separator: ".").first.map(String.init)
        servers.append(SMBServer(host: ip, display: short.map { "\($0)  (\(ip))" } ?? ip))
        servers.sort { $0.display.lowercased() < $1.display.lowercased() }
    }

    /// First three octets of this Mac's primary IPv4, plus its own address.
    private static func localIPv4Base() -> (String, String)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            if ifa.ifa_addr?.pointee.sa_family == sa_family_t(AF_INET),
               (Int32(ifa.ifa_flags) & IFF_LOOPBACK) == 0,
               (Int32(ifa.ifa_flags) & IFF_UP) != 0 {
                var addr = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                               &addr, socklen_t(addr.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: addr)
                    let parts = ip.split(separator: ".")
                    if parts.count == 4, parts[0] != "169" {   // skip link-local
                        return (parts[0...2].joined(separator: "."), ip)
                    }
                }
            }
            ptr = ifa.ifa_next
        }
        return nil
    }

    private static func reverseName(_ ip: String) -> String? {
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ip, &sa.sin_addr) == 1 else { return nil }
        let saLen = socklen_t(sa.sin_len)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let ok = withUnsafePointer(to: &sa) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, saLen, &host, socklen_t(host.count),
                            nil, 0, NI_NAMEREQD) == 0
            }
        }
        return ok ? String(cString: host) : nil
    }
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
