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

/// Finds SMB servers two ways at once: Bonjour (modern Macs/NASes advertise
/// there) AND an active sweep of the local subnet for machines answering on
/// the SMB port — old servers like Roon ROCK's 2015 Samba only announce via
/// NetBIOS, which Bonjour never sees, but they all answer port 445.
@MainActor
final class SMBServerBrowser: ObservableObject {
    @Published var servers: [SMBServer] = []
    @Published var scanning = false
    private var browser: NWBrowser?
    private var live: [String: NWConnection] = [:]   // ip → in-flight probe
    // servers seen this session, so reopening the picker shows them at once
    private static var remembered: [SMBServer] = []
    private var generation = 0                        // invalidates an old scan's callbacks

    func start() {
        stop()
        servers = Self.remembered      // show what we already know immediately
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
        // 2) subnet sweep, bounded so we never open hundreds of sockets at once
        scanSubnet(gen: gen)
    }

    func stop() {
        generation += 1                // orphan any pending callbacks
        browser?.cancel(); browser = nil
        for c in live.values { c.cancel() }
        live = [:]
        scanning = false
    }

    private var scanPending: [String] = []
    private var scanDone = Set<String>()   // ips already accounted for (idempotent)

    private func scanSubnet(gen: Int) {
        guard let (base, myIP) = Self.localIPv4Base() else { return }
        scanning = true
        scanDone = []
        scanPending = Array(1...254).map { "\(base).\($0)" }.filter { $0 != myIP }
        // Keep this modest: some home routers treat a burst of connection
        // attempts as a SYN-flood and start dropping the source, which makes
        // the scan find nothing. 12-at-a-time still sweeps a /24 in seconds.
        let maxConcurrent = 12
        for _ in 0..<maxConcurrent { launchProbe(gen: gen) }
    }

    private func launchProbe(gen: Int) {
        guard gen == generation else { return }
        guard !scanPending.isEmpty else {
            if live.isEmpty { scanning = false }
            return
        }
        let ip = scanPending.removeFirst()
        let queue = DispatchQueue(label: "smb-scan")
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 2
        let conn = NWConnection(host: NWEndpoint.Host(ip), port: 445,
                                using: NWParameters(tls: nil, tcp: tcp))
        live[ip] = conn
        conn.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready:
                Task { @MainActor in self?.finishProbe(ip: ip, gen: gen, found: true) }
            case .failed:
                Task { @MainActor in self?.finishProbe(ip: ip, gen: gen, found: false) }
            default:
                break   // ignore .cancelled etc — finishProbe drives everything once
            }
        }
        conn.start(queue: queue)
    }

    private func finishProbe(ip: String, gen: Int, found: Bool) {
        guard gen == generation else { return }
        guard !scanDone.contains(ip) else { return }   // only the first result counts
        scanDone.insert(ip)
        if let c = live.removeValue(forKey: ip) { c.cancel() }
        if found { addScanned(ip: ip) }
        launchProbe(gen: gen)                            // exactly one replacement
        if live.isEmpty && scanPending.isEmpty { scanning = false }
    }

    func rescan() {
        Self.remembered = []
        start()
    }

    private func merge(_ found: [SMBServer]) {
        for s in found where !servers.contains(where: { $0.host == s.host }) {
            servers.append(s)
        }
        servers.sort { $0.display.lowercased() < $1.display.lowercased() }
        Self.remembered = servers
    }

    private func addScanned(ip: String) {
        guard !servers.contains(where: { $0.host == ip }) else { return }
        // show the responder immediately — the reverse name lookup can block
        // for many seconds on networks without reverse DNS, so it happens in
        // the background and upgrades the label when (if) it answers
        servers.append(SMBServer(host: ip, display: ip))
        servers.sort { $0.display.lowercased() < $1.display.lowercased() }
        Self.remembered = servers
        Task.detached { [weak self] in
            guard let name = Self.reverseName(ip) else { return }
            let short = String(name.split(separator: ".").first ?? "")
            await MainActor.run {
                guard let self else { return }
                if self.servers.contains(where: { $0.display.lowercased() == short.lowercased() }) {
                    self.servers.removeAll { $0.host == ip }
                } else if let idx = self.servers.firstIndex(where: { $0.host == ip }) {
                    self.servers[idx] = SMBServer(host: ip, display: "\(short)  (\(ip))")
                    self.servers.sort { $0.display.lowercased() < $1.display.lowercased() }
                }
                Self.remembered = self.servers
            }
        }
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

    nonisolated private static func reverseName(_ ip: String) -> String? {
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
