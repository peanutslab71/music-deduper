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

    /// Delete a file, or a folder with everything inside it. SMB has no
    /// Trash — this is permanent, and the UI must say so.
    func removeItem(_ path: String, isDir: Bool) async throws {
        let m = try await ensure()
        if isDir {
            try await m.removeDirectory(atPath: path, recursive: true)
        } else {
            try await m.removeFile(atPath: path)
        }
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

    /// Translate the errors odd servers produce into something a person can
    /// act on. EPERM at connect time = the box refused the session (often an
    /// authentication quirk in embedded firmware).
    static func friendly(_ error: Error, host: String) -> String {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == 1 {
            return "\(host) refused the session. If it needs a login, guest access may be "
                 + "disabled on it. As a fallback, mount it in Finder (⌘K) and browse it "
                 + "under This Mac → /Volumes."
        }
        return error.localizedDescription
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

/// Finds SMB servers two gentle ways: Bonjour (modern Macs/NASes advertise
/// there) AND a NetBIOS name broadcast — one UDP packet that old servers like
/// Roon ROCK answer with their names. NetBIOS is how Finder finds these boxes;
/// a single broadcast can't look like a port scan, so it never trips a router's
/// intrusion protection (which a 254-address connection sweep does).
@MainActor
final class SMBServerBrowser: ObservableObject {
    @Published var servers: [SMBServer] = []
    @Published var scanning = false
    private var browser: NWBrowser?
    private static var remembered: [SMBServer] = []
    private var generation = 0

    func start() {
        stop()
        servers = Self.remembered
        generation += 1
        let gen = generation

        // 1) Bonjour
        let b = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { r -> SMBServer? in
                if case .service(let name, _, _, _) = r.endpoint {
                    return SMBServer(host: name + ".local", display: name)
                }
                return nil
            }
            Task { @MainActor in self?.merge(found) }
        }
        b.start(queue: .main)
        browser = b

        // 2) NetBIOS broadcast — one packet, off the main thread
        scanning = true
        Task.detached { [weak self] in
            let hits = NetBIOS.discover(seconds: 3)
            await MainActor.run {
                guard let self, gen == self.generation else { return }
                for hit in hits {
                    self.merge([SMBServer(host: hit.ip,
                                          display: hit.name.map { "\($0)  (\(hit.ip))" } ?? hit.ip)])
                }
                self.scanning = false
            }
        }
    }

    func stop() {
        generation += 1
        browser?.cancel(); browser = nil
        scanning = false
    }

    func rescan() {
        Self.remembered = []
        start()
    }

    private func merge(_ found: [SMBServer]) {
        for s in found {
            // an IP-only entry is replaced if a nicer named entry for the same box arrives
            if let idx = servers.firstIndex(where: { $0.host == s.host }) {
                if servers[idx].display != s.display && s.display != s.host {
                    servers[idx] = s
                }
            } else {
                servers.append(s)
            }
        }
        servers.sort { $0.display.lowercased() < $1.display.lowercased() }
        Self.remembered = servers
    }
}

/// Minimal NetBIOS Name Service (NBNS) client — the old broadcast name protocol
/// SMB servers still answer, used here to discover them and read their names.
enum NetBIOS {
    struct Hit { let ip: String; let name: String? }

    /// Broadcast a wildcard node-status query and collect responders + names.
    static func discover(seconds: Int) -> [Hit] {
        guard let bcast = broadcastAddress() else { return [] }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        sendQuery(fd: fd, to: bcast, nbstat: true, broadcast: true)

        var names: [String: String?] = [:]
        let deadline = Date().addingTimeInterval(Double(seconds))
        while Date() < deadline {
            var from = sockaddr_in()
            var flen = socklen_t(MemoryLayout<sockaddr_in>.size)
            var buf = [UInt8](repeating: 0, count: 2048)
            let n = withUnsafeMutablePointer(to: &from) { fp in
                fp.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buf, buf.count, 0, $0, &flen)
                }
            }
            guard n > 0 else { continue }
            var ipbuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &ipbuf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: ipbuf)
            if names[ip] == nil {
                names[ip] = parseNodeStatus(Array(buf[0..<n]))
            }
        }
        return names.map { Hit(ip: $0.key, name: $0.value) }
    }

    private static func sendQuery(fd: Int32, to ip: String, nbstat: Bool, broadcast: Bool) {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(137).bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)
        let pkt = query(qtype: nbstat ? 0x0021 : 0x0020, broadcast: broadcast)
        _ = pkt.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) { ap in
                ap.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, pkt.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Build an NBNS query for the wildcard "*" name.
    private static func query(qtype: UInt16, broadcast: Bool) -> [UInt8] {
        var p: [UInt8] = [0xF0, 0x00]                 // txn id
        let flags: UInt16 = broadcast ? 0x0110 : 0x0000
        p += [UInt8(flags >> 8), UInt8(flags & 0xFF)]
        p += [0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]   // qd=1, others 0
        // wildcard name '*' + 15 nulls, first-level encoded to 32 bytes
        var name16: [UInt8] = [0x2A] + [UInt8](repeating: 0, count: 15)
        name16 = Array(name16.prefix(16))
        p.append(0x20)
        for b in name16 { p.append(0x41 + (b >> 4)); p.append(0x41 + (b & 0x0F)) }
        p.append(0x00)
        p += [UInt8(qtype >> 8), UInt8(qtype & 0xFF)]
        p += [0x00, 0x01]                              // class IN
        return p
    }

    /// Pull the machine name out of an NBSTAT node-status response.
    private static func parseNodeStatus(_ b: [UInt8]) -> String? {
        var i = 12
        guard i < b.count, b[i] == 0x20 else { return nil }
        i += 34 + 2 + 2 + 4          // encoded name + type + class + ttl
        guard i + 2 <= b.count else { return nil }
        i += 2                       // rdlength
        guard i < b.count else { return nil }
        let num = Int(b[i]); i += 1
        for _ in 0..<num {
            guard i + 18 <= b.count else { break }
            let nameBytes = Array(b[i..<i+15])
            let suffix = b[i+15]
            let flags = (UInt16(b[i+16]) << 8) | UInt16(b[i+17])
            i += 18
            let isGroup = (flags & 0x8000) != 0
            if !isGroup, suffix == 0x20 || suffix == 0x00 {
                let name = String(bytes: nameBytes, encoding: .ascii)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if !name.isEmpty, name != "__MSBROWSE__" { return name }
            }
        }
        return nil
    }

    /// Directed-broadcast address of the primary IPv4 interface (x.x.x.255).
    private static func broadcastAddress() -> String? {
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
                    if parts.count == 4, parts[0] != "169" {
                        return "\(parts[0]).\(parts[1]).\(parts[2]).255"
                    }
                }
            }
            ptr = ifa.ifa_next
        }
        return nil
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
