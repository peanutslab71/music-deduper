//
//  Identify.swift
//  MusicDeduper
//
//  Perfect — identify tracks acoustically and propose the correct names.
//  Pipeline: Chromaprint fingerprint (ChromaSwift) → AcoustID lookup → the
//  canonical artist/title (and candidate albums) from MusicBrainz's data.
//
//  Fingerprinting is reliable for artist + title. An album is deliberately only
//  a *suggestion* (a recording appears on many releases), defaulting to whatever
//  best matches the file's existing album so we never force a wrong "correction".
//

import Foundation
import ChromaSwift

// MARK: - AcoustID response model (only the fields we use)

private struct ACResponse: Decodable {
    let status: String
    let results: [ACResult]?
}
private struct ACResult: Decodable {
    let score: Double
    let recordings: [ACRecording]?
}
private struct ACRecording: Decodable {
    let id: String?                   // MusicBrainz recording MBID — key to the relationship lookups
    let title: String?
    let artists: [ACArtist]?
    let releasegroups: [ACReleaseGroup]?
}
private struct ACArtist: Decodable { let name: String? }
private struct ACReleaseGroup: Decodable {
    let title: String?
    let type: String?
    let secondarytypes: [String]?
}

// MARK: - Proposal

/// One track's identification result — the current tags vs. what the acoustic
/// match says they should be. Album is a chosen suggestion, editable.
struct TrackProposal: Identifiable {
    let id = UUID()
    let url: URL
    let relPath: String
    let score: Double                 // AcoustID match score 0…1

    let curArtist: String
    let curTitle: String
    let curAlbum: String

    let newArtist: String
    let newTitle: String
    let albumCandidates: [String]     // suggested albums, best first
    var chosenAlbum: String           // editable
    var accepted: Bool

    let recordingID: String?          // MusicBrainz recording, for the relationship lookups
    let curHasArt: Bool               // does the file already have embedded cover art?
    var enrichment: Enrichment?       // composer/label/performers, filled by the MusicBrainz pass

    /// artwork will be offered when the file has none and we found a release to fetch from
    var canAddArt: Bool { !curHasArt && (enrichment?.releaseMBID != nil) }

    var artistChanged: Bool { !newArtist.isEmpty && newArtist != curArtist }
    var titleChanged: Bool  { !newTitle.isEmpty && newTitle != curTitle }
    var albumChanged: Bool  { !chosenAlbum.isEmpty && chosenAlbum != curAlbum }
    var hasChange: Bool { artistChanged || titleChanged || albumChanged }
}

// MARK: - Identifier

enum IdentifyError: Error { case noKey, fingerprint(Error), network(Error), decode }

struct Identifier {
    let apiKey: String
    private let session = URLSession(configuration: .ephemeral)

    /// The AcoustID application key, injected at build time via Secrets.xcconfig.
    static var configuredKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "ACOUSTID_API_KEY") as? String) ?? ""
    }

    /// Fingerprint one file and look it up. Returns nil on no match. `current*`
    /// are the file's existing tags, used to pick the closest album.
    func identify(url: URL, relPath: String,
                  curArtist: String, curTitle: String, curAlbum: String,
                  curHasArt: Bool) async throws -> TrackProposal? {
        guard !apiKey.isEmpty else { throw IdentifyError.noKey }

        // Decode + fingerprint inside an autorelease pool so the (tens-of-MB) PCM
        // buffers are freed the instant we're done with this file, instead of
        // accumulating across the whole library and ballooning memory.
        let fp: AudioFingerprint
        do { fp = try autoreleasepool { try AudioFingerprint(from: url) } }
        catch { throw IdentifyError.fingerprint(error) }

        let (score, rec) = try await lookup(fingerprint: fp.base64, duration: Int(fp.duration.rounded()))
        guard let rec else { return nil }

        // Use only the PRIMARY billed artist. Never comma-join credited names —
        // Roon (and any parser) breaks on it, and real names contain commas
        // ("Earth, Wind & Fire"). Genuine multi-artist billing (as separate tag
        // values) and additional performers (as performer credits) arrive with the
        // MusicBrainz-relationship layer. See docs/metadata-mapping.md.
        let artist = rec.artists?.first?.name ?? ""
        let title = rec.title ?? ""
        // Album is ambiguous (a recording lives on many releases) and the file's
        // own album tag is often correct and not even among the candidates — so
        // the default is NO album change. The fingerprint's albums are offered as
        // options, with the current album kept first and selected.
        let ranked = rankAlbums(rec.releasegroups ?? [], preferring: curAlbum)
        var candidates = ranked
        var chosen = ranked.first ?? ""
        if !curAlbum.isEmpty {
            candidates = ([curAlbum] + ranked).reduced()
            chosen = curAlbum          // keep the existing album unless the user picks another
        }

        let proposal = TrackProposal(
            url: url, relPath: relPath, score: score,
            curArtist: curArtist, curTitle: curTitle, curAlbum: curAlbum,
            newArtist: artist, newTitle: title,
            albumCandidates: candidates,
            chosenAlbum: chosen,
            accepted: true,
            recordingID: rec.id,
            curHasArt: curHasArt,
            enrichment: nil)
        return proposal
    }

    /// AcoustID lookup → (score, best recording). Own parser so a response shape
    /// we don't expect fails cleanly rather than silently.
    private func lookup(fingerprint: String, duration: Int) async throws -> (Double, ACRecording?) {
        var comps = URLComponents(string: "https://api.acoustid.org/v2/lookup")!
        // meta uses '+' as a separator (space); URLComponents encodes the rest
        comps.percentEncodedQuery =
            "client=\(apiKey)&duration=\(duration)&meta=recordings+releasegroups"
            + "&fingerprint=\(fingerprint.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? fingerprint)"
        var req = URLRequest(url: comps.url!)
        req.setValue("MusicDeduper ( neil.cottyincar@gmail.com )", forHTTPHeaderField: "User-Agent")

        let data: Data
        do { (data, _) = try await session.data(for: req) }
        catch { throw IdentifyError.network(error) }

        guard let resp = try? JSONDecoder().decode(ACResponse.self, from: data),
              resp.status == "ok" else { throw IdentifyError.decode }
        guard let top = resp.results?.first else { return (0, nil) }
        return (top.score, top.recordings?.first)
    }

    /// Rank candidate albums: an exact/one-line match to the current album wins,
    /// then studio Albums over compilations/live, then leave the order as-is.
    private func rankAlbums(_ groups: [ACReleaseGroup], preferring current: String) -> [String] {
        let cur = current.lowercased()
        func score(_ g: ACReleaseGroup) -> Int {
            var s = 0
            let t = (g.title ?? "").lowercased()
            if !cur.isEmpty && t == cur { s += 100 }
            else if !cur.isEmpty && (t.contains(cur) || cur.contains(t)) { s += 40 }
            if (g.type ?? "") == "Album" { s += 10 }
            let sec = g.secondarytypes ?? []
            if sec.contains("Compilation") || sec.contains("Live") { s -= 8 }
            return s
        }
        return groups
            .compactMap { $0.title == nil ? nil : $0 }
            .sorted { score($0) > score($1) }
            .compactMap { $0.title }
            .reduced()   // de-dup, keep order
    }
}

private extension Array where Element == String {
    func reduced() -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for s in self where !seen.contains(s) { seen.insert(s); out.append(s) }
        return out
    }
}

// MARK: - MusicBrainz relationship enrichment

/// The extra metadata a MusicBrainz recording gives us beyond names: composer,
/// lyricist, label, and performer credits (sidemen with instruments). These are
/// filled only when the file's field is blank — see docs/metadata-mapping.md.
struct Enrichment {
    var composer: String?
    var lyricist: String?
    var label: String?
    var catalogNumber: String?
    var date: String?
    var performers: [Performer] = []       // (name, role) — go in the credits field, never artist
    var releaseMBID: String?               // for fetching cover art (not a credit itself)
    struct Performer { let name: String; let role: String }

    var isEmpty: Bool {
        composer == nil && lyricist == nil && label == nil && catalogNumber == nil
            && date == nil && performers.isEmpty
    }
}

// Minimal MusicBrainz JSON models (only the fields we read)
private struct MBRecording: Decodable { let relations: [MBRelation]?; let releases: [MBRef]? }
private struct MBWork: Decodable { let relations: [MBRelation]? }
private struct MBRelease: Decodable {
    let date: String?
    let labelInfo: [MBLabelInfo]?
    enum CodingKeys: String, CodingKey { case date; case labelInfo = "label-info" }
}
private struct MBRelation: Decodable {
    let type: String
    let artist: MBRef?
    let work: MBRef?
    let attributes: [String]?
}
private struct MBRef: Decodable { let id: String?; let name: String?; let title: String? }
private struct MBLabelInfo: Decodable {
    let label: MBRef?
    let catalogNumber: String?
    enum CodingKeys: String, CodingKey { case label; case catalogNumber = "catalog-number" }
}

/// Looks up MusicBrainz relationships for a recording. An actor so its per-run
/// caches are safe, and it serialises requests — MusicBrainz allows ~1 req/sec,
/// so each network call waits a beat, and works/releases are cached to avoid
/// repeat lookups (many tracks share a release).
actor MusicBrainzClient {
    private let session = URLSession(configuration: .ephemeral)
    private let userAgent = "MusicDeduper ( neil.cottyincar@gmail.com )"
    private var workCache: [String: (composer: String?, lyricist: String?)] = [:]
    private var releaseCache: [String: (label: String?, catalog: String?, date: String?)] = [:]

    func enrich(recordingID: String) async -> Enrichment {
        var e = Enrichment()
        guard let rec: MBRecording = await get(
            "recording/\(recordingID)?inc=work-rels+artist-rels+releases") else { return e }

        // performers (instrument / vocal relationships) → credits
        for r in rec.relations ?? [] where r.type == "instrument" || r.type == "vocal" {
            if let name = r.artist?.name {
                let role = (r.attributes?.first) ?? r.type
                e.performers.append(.init(name: name, role: role))
            }
        }
        // composer / lyricist via the linked work
        if let workID = (rec.relations ?? []).first(where: { $0.type == "performance" })?.work?.id {
            let w = await cachedWork(workID)
            e.composer = w.composer; e.lyricist = w.lyricist
        }
        // label / catalog / date via the first release; keep the release id for art
        if let releaseID = rec.releases?.first?.id {
            e.releaseMBID = releaseID
            let r = await cachedRelease(releaseID)
            e.label = r.label; e.catalogNumber = r.catalog; e.date = r.date
        }
        return e
    }

    private func cachedWork(_ id: String) async -> (composer: String?, lyricist: String?) {
        if let c = workCache[id] { return c }
        var out: (composer: String?, lyricist: String?) = (nil, nil)
        if let w: MBWork = await get("work/\(id)?inc=artist-rels") {
            for r in w.relations ?? [] {
                if r.type == "composer", out.composer == nil { out.composer = r.artist?.name }
                if r.type == "lyricist", out.lyricist == nil { out.lyricist = r.artist?.name }
            }
        }
        workCache[id] = out
        return out
    }

    private func cachedRelease(_ id: String) async -> (label: String?, catalog: String?, date: String?) {
        if let c = releaseCache[id] { return c }
        var out: (label: String?, catalog: String?, date: String?) = (nil, nil, nil)
        if let r: MBRelease = await get("release/\(id)?inc=labels") {
            out.date = r.date
            if let li = r.labelInfo?.first {
                out.label = li.label?.name; out.catalog = li.catalogNumber
            }
        }
        releaseCache[id] = out
        return out
    }

    /// One MusicBrainz GET, JSON-decoded, after a courtesy delay for the rate limit.
    private func get<T: Decodable>(_ path: String) async -> T? {
        try? await Task.sleep(nanoseconds: 1_100_000_000)   // ~1 req/sec
        guard let url = URL(string: "https://musicbrainz.org/ws/2/\(path)&fmt=json") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: req) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// Fetches front-cover images from the Cover Art Archive, keyed by release MBID.
/// Caches per release so all of an album's tracks share one download.
actor CoverArtClient {
    private let session = URLSession(configuration: .ephemeral)
    private var cache: [String: Data?] = [:]

    func frontCover(releaseMBID: String) async -> Data? {
        if let c = cache[releaseMBID] { return c }
        var result: Data? = nil
        // 500px front cover; the archive redirects to storage, URLSession follows it
        if let url = URL(string: "https://coverartarchive.org/release/\(releaseMBID)/front-500") {
            var req = URLRequest(url: url)
            req.setValue("MusicDeduper ( neil.cottyincar@gmail.com )", forHTTPHeaderField: "User-Agent")
            if let (data, resp) = try? await session.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                result = data
            }
        }
        cache[releaseMBID] = result
        return result
    }
}
