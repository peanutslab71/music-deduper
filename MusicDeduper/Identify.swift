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
    var url: URL                      // updated if Organise moves the file
    var relPath: String
    let score: Double                 // AcoustID match score 0…1

    let curArtist: String
    let curTitle: String
    let curAlbum: String

    let newArtist: String
    let newTitle: String
    let albumCandidates: [String]     // suggested albums, best first
    var chosenAlbum: String           // editable
    var accepted: Bool
    var reviewed: Bool = false        // a decision was made in the review queue → leaves the queue

    let recordingID: String?          // MusicBrainz recording, for the relationship lookups
    let curHasArt: Bool               // does the file already have embedded cover art?
    let curComposer: String           // existing composer tag (to know if it's a blank to fill)
    let curLabel: String              // existing label tag
    var enrichment: Enrichment?       // composer/label/performers, filled by the MusicBrainz pass

    /// artwork will be offered when the file has none and we found a release to fetch from
    var canAddArt: Bool { !curHasArt && (enrichment?.releaseMBID != nil) }

    /// credits/label the enrichment can fill into currently-blank fields
    var hasCreditGap: Bool {
        guard let e = enrichment else { return false }
        if e.composer != nil && curComposer.isEmpty { return true }
        if e.label != nil && curLabel.isEmpty { return true }
        if !e.performers.isEmpty { return true }
        return false
    }

    /// worth showing / applying: a name change, artwork to add, or a credit gap to fill
    var isActionable: Bool { hasChange || canAddArt || hasCreditGap }

    /// Needs a deliberate look. A genuinely different title/artist (substantive)
    /// always does. Otherwise — a cosmetic tidy or an "adds detail" change — only
    /// if the audio match itself is shaky. Case/punctuation and version-qualifier
    /// changes no longer flood the queue; they're handled in bulk by kind.
    var needsReview: Bool {
        if reviewed { return false }              // already decided → gone from the queue
        if dominantNameKind == .substantive { return true }   // different words → look
        return score < 0.7                        // else only if the match is uncertain
    }

    var artistChanged: Bool { !newArtist.isEmpty && Self.differs(newArtist, curArtist) }
    var titleChanged: Bool  { !newTitle.isEmpty && Self.differs(newTitle, curTitle) }
    var albumChanged: Bool  { !chosenAlbum.isEmpty && Self.differs(chosenAlbum, curAlbum) }
    var hasChange: Bool { artistChanged || titleChanged || albumChanged }

    /// Real difference test used for "is this a change worth showing?". A value that
    /// only differs by typography — curly vs straight quotes/apostrophes, dash style,
    /// an ellipsis character, or whitespace — is NOT a change: it's invisible to the
    /// user and pointless churn. Genuine spelling/word/case differences still count.
    static func differs(_ a: String, _ b: String) -> Bool { typoFold(a) != typoFold(b) }

    static func typoFold(_ s: String) -> String {
        var t = s
        let map: [(String, String)] = [
            ("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201B}", "'"), ("\u{02BC}", "'"), ("`", "'"),
            ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{201E}", "\""),
            ("\u{2013}", "-"), ("\u{2014}", "-"), ("\u{2015}", "-"), ("\u{2212}", "-"),
            ("\u{2026}", "..."), ("\u{00A0}", " ")
        ]
        for (from, to) in map { t = t.replacingOccurrences(of: from, with: to) }
        // collapse runs of whitespace and trim
        t = t.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return t
    }

    // What KIND of change each proposed field is — so the review UI can label it and
    // quiet the trivial ones instead of treating a case fix like a real re-title.
    var titleChangeKind: ChangeKind  { titleChanged  ? Self.classifyChange(curTitle,  newTitle)   : .none }
    var artistChangeKind: ChangeKind { artistChanged ? Self.classifyChange(curArtist, newArtist)  : .none }
    var albumChangeKind: ChangeKind  { albumChanged  ? Self.classifyChange(curAlbum,  chosenAlbum) : .none }
    /// The most significant name change on this track — drives the summary grouping.
    var dominantNameKind: ChangeKind { ChangeKind.strongest([titleChangeKind, artistChangeKind, albumChangeKind]) }

    /// Aggressive fold for classification: typoFold + lowercase + drop punctuation +
    /// collapse spaces. Two strings equal under this differ only cosmetically.
    static func hardFold(_ s: String) -> String {
        let t = typoFold(s).lowercased()
        let scalars = t.unicodeScalars.map { sc -> Character in
            (CharacterSet.alphanumerics.contains(sc) || sc == " ") ? Character(sc) : " "
        }
        return String(scalars).components(separatedBy: " ").filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Classify how different `to` is from `from`.
    static func classifyChange(_ from: String, _ to: String) -> ChangeKind {
        if from == to { return .none }
        let a = hardFold(from), b = hardFold(to)
        if a == b { return .cosmetic }
        if a.isEmpty || b.isEmpty { return .substantive }
        if a.contains(b) || b.contains(a) { return .additive }        // one adds words/qualifiers
        let ta = Set(a.split(separator: " ")), tb = Set(b.split(separator: " "))
        let shared = ta.intersection(tb).count
        let smaller = max(1, min(ta.count, tb.count))
        return Double(shared) / Double(smaller) >= 0.6 ? .additive : .substantive
    }
}

/// How different a proposed value is from the current one.
enum ChangeKind: Equatable {
    case none          // identical
    case cosmetic      // same once case / punctuation / spacing are ignored
    case additive      // one contains the other, or only qualifiers differ (adds detail)
    case substantive   // genuinely different words

    var label: String {
        switch self {
        case .none:        return ""
        case .cosmetic:    return "case & punctuation"
        case .additive:    return "adds detail"
        case .substantive: return "different"
        }
    }
    /// The most significant of several changes, for a one-line row summary.
    static func strongest(_ kinds: [ChangeKind]) -> ChangeKind {
        if kinds.contains(.substantive) { return .substantive }
        if kinds.contains(.additive)    { return .additive }
        if kinds.contains(.cosmetic)    { return .cosmetic }
        return .none
    }
}

// MARK: - Identifier

enum IdentifyError: Error { case noKey, fingerprint(Error), network(Error), decode }

struct Identifier {
    let apiKey: String
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// The AcoustID application key, injected at build time via Secrets.xcconfig.
    static var configuredKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "ACOUSTID_API_KEY") as? String) ?? ""
    }

    /// Fingerprint one file and look it up. Returns nil on no match. `current*`
    /// are the file's existing tags, used to pick the closest album.
    /// Placeholder tag values that should be treated as blank (and filled), not kept.
    static func isJunkValue(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { return true }
        if t == "unknown" || t.hasPrefix("unknown ") || t.contains("unknown album")
            || t.contains("unknown artist") || t == "various" || t == "various artists" { return true }
        if t.range(of: "^track ?0*\\d+$", options: .regularExpression) != nil { return true }
        return false
    }

    /// Step 1 — decode + fingerprint (pure CPU/IO, no network). Safe to run on
    /// many files at once. The autorelease pool frees the tens-of-MB PCM buffer
    /// the instant we're done, so memory doesn't balloon across the library.
    func fingerprint(_ url: URL) -> AudioFingerprint? {
        try? autoreleasepool { try AudioFingerprint(from: url) }
    }

    /// Step 2 — the AcoustID lookup for an already-computed fingerprint. This is
    /// the rate-limited part (3 req/sec), kept separate so fingerprinting can run
    /// ahead of it in parallel.
    func resolve(url: URL, relPath: String, fingerprint fp: AudioFingerprint,
                 curArtist: String, curTitle: String, curAlbum: String,
                 curHasArt: Bool, curComposer: String, curLabel: String) async throws -> TrackProposal? {
        guard !apiKey.isEmpty else { throw IdentifyError.noKey }
        // treat placeholder tags as blank so they get filled, not trusted
        let cleanArtist = Self.isJunkValue(curArtist) ? "" : curArtist
        let cleanAlbum = Self.isJunkValue(curAlbum) ? "" : curAlbum

        let (score, recordings) = try await lookup(fingerprint: fp.base64, duration: Int(fp.duration.rounded()))
        // Consensus pick that trusts the existing tag — never overrides a good
        // artist on one junk cluster entry (e.g. AC/DC → "Maynard Ferguson").
        guard let pick = Self.chooseRecording(recordings, existingArtist: cleanArtist) else { return nil }
        let artist = pick.artist
        let title = pick.rec.title ?? ""
        // Album: keep the existing album if present; if it's blank/junk, fill it
        // from the fingerprint's release. Alternatives are offered either way.
        let ranked = rankAlbums(pick.rec.releasegroups ?? [], preferring: cleanAlbum)
        var candidates = ranked
        var chosen = ranked.first ?? ""
        if !cleanAlbum.isEmpty {
            candidates = ([cleanAlbum] + ranked).reduced()
            chosen = cleanAlbum        // keep the existing album unless the user picks another
        }

        let proposal = TrackProposal(
            url: url, relPath: relPath, score: score,
            curArtist: cleanArtist, curTitle: curTitle, curAlbum: cleanAlbum,
            newArtist: artist, newTitle: title,
            albumCandidates: candidates,
            chosenAlbum: chosen,
            accepted: true,
            recordingID: pick.rec.id,
            curHasArt: curHasArt,
            curComposer: curComposer, curLabel: curLabel,
            enrichment: nil)
        return proposal
    }

    /// AcoustID lookup → (score, best recording). Own parser so a response shape
    /// we don't expect fails cleanly rather than silently.
    private func lookup(fingerprint: String, duration: Int) async throws -> (Double, [ACRecording]) {
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
        guard let results = resp.results, let top = results.first else { return (0, []) }
        // Pool the recordings from every result. A fingerprint cluster usually
        // contains the correct recording many times over plus the odd mis-tagged
        // junk entry — so we never let a single entry (or its position) decide.
        return (top.score, results.flatMap { $0.recordings ?? [] })
    }

    // Normalised artist key for matching (case, & vs and, punctuation).
    private static func nk(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: " & ", with: " and ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
    private static func mostCommon(_ xs: [String]) -> String? {
        guard !xs.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for x in xs { counts[x, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key
    }

    /// Choose a recording by consensus, trusting the existing tag:
    /// - existing artist present and the cluster corroborates it → keep that
    ///   artist, take the most common title among the agreeing recordings;
    /// - existing artist present but absent from the cluster → return nil (the
    ///   match is unreliable — leave the file alone, never override a good tag);
    /// - existing artist blank/junk → fill from the cluster's majority.
    private static func chooseRecording(_ recs: [ACRecording], existingArtist: String)
        -> (artist: String, rec: ACRecording)? {
        guard !recs.isEmpty else { return nil }
        func recArtist(_ r: ACRecording) -> String { r.artists?.first?.name ?? "" }
        let curKey = nk(existingArtist)
        let pool: [ACRecording]
        let useArtist: String
        if !curKey.isEmpty {
            let matching = recs.filter { nk(recArtist($0)) == curKey }
            guard !matching.isEmpty else { return nil }   // cluster disagrees → keep as-is
            pool = matching; useArtist = existingArtist
        } else {
            guard let artist = mostCommon(recs.map(recArtist).filter { !$0.isEmpty }) else { return nil }
            pool = recs.filter { nk(recArtist($0)) == nk(artist) }; useArtist = artist
        }
        guard let title = mostCommon(pool.compactMap { $0.title }.filter { !$0.isEmpty }),
              let rec = pool.first(where: { $0.title == title }) else { return nil }
        return (useArtist, rec)
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
private struct MBRelease: Decodable {
    let date: String?
    let labelInfo: [MBLabelInfo]?
    let relations: [MBRelation]?
    enum CodingKeys: String, CodingKey { case date; case labelInfo = "label-info"; case relations }
}
// A release with its full tracklist, each track's recording relations, and the
// works those recordings link to — everything for one album in a single request.
private struct MBReleaseFull: Decodable {
    let date: String?
    let labelInfo: [MBLabelInfo]?
    let relations: [MBRelation]?          // url-rels (the Discogs link)
    let media: [MBMedia]?
    enum CodingKeys: String, CodingKey { case date; case labelInfo = "label-info"; case relations; case media }
}
private struct MBMedia: Decodable { let tracks: [MBTrack]? }
private struct MBTrack: Decodable { let recording: MBTrackRecording? }
private struct MBTrackRecording: Decodable { let id: String?; let title: String?; let relations: [MBRelation]? }
// A recording with the releases it appears on (title + track count), used to pick
// the album release that matches the track's album tag.
private struct MBRecordingReleases: Decodable { let releases: [MBReleaseStub]? }
private struct MBReleaseStub: Decodable {
    let id: String?
    let title: String?
    let media: [MBMediaCount]?
}
private struct MBMediaCount: Decodable {
    let trackCount: Int?
    enum CodingKeys: String, CodingKey { case trackCount = "track-count" }
}
private struct MBRelation: Decodable {
    let type: String
    let artist: MBRef?
    let work: MBWorkRef?
    let url: MBUrl?
    let attributes: [String]?
}
// The work linked to a recording, with its own relations (composer/lyricist)
// carried inline when we ask for work-level-rels — so no extra request per track.
private struct MBWorkRef: Decodable {
    let id: String?
    let title: String?
    let relations: [MBRelation]?
}
private struct MBUrl: Decodable { let resource: String? }
private struct MBRef: Decodable { let id: String?; let name: String?; let title: String? }
private struct MBLabelInfo: Decodable {
    let label: MBRef?
    let catalogNumber: String?
    enum CodingKeys: String, CodingKey { case label; case catalogNumber = "catalog-number" }
}

// Minimal Discogs models
private struct DiscogsRelease: Decodable {
    let extraartists: [DiscogsCredit]?
    let labels: [DiscogsLabel]?
    let genres: [String]?
    let styles: [String]?
    let year: Int?
}
private struct DiscogsCredit: Decodable { let name: String?; let role: String? }
private struct DiscogsLabel: Decodable { let name: String?; let catno: String? }

/// Looks up MusicBrainz relationships for a recording. An actor so its per-run
/// caches are safe, and it serialises requests — MusicBrainz allows ~1 req/sec,
/// so each network call waits a beat, and works/releases are cached to avoid
/// repeat lookups (many tracks share a release).
actor MusicBrainzClient {
    // A stalled request must fail fast and let the loop move on, never hang the
    // whole credits pass. Without these, one slow response blocks everything.
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    private let userAgent = "MusicDeduper ( neil.cottyincar@gmail.com )"
    private let discogsUA = "MusicDeduper/1.4 +https://github.com/peanutslab71/music-deduper"
    // Optional Discogs personal token (from Secrets.xcconfig). Present → 60/min
    // and authenticated; blank → 25/min unauthenticated.
    private let discogsToken = (Bundle.main.object(forInfoDictionaryKey: "DISCOGS_TOKEN") as? String) ?? ""
    private var releaseCache: [String: (label: String?, catalog: String?, date: String?, discogs: String?)] = [:]
    private var discogsCache: [String: DiscogsRelease?] = [:]
    // Counters so a run can report how many network calls it actually made.
    private(set) var mbRequests = 0
    private(set) var discogsRequests = 0
    func stats() -> (mb: Int, discogs: Int) { (mbRequests, discogsRequests) }

    func enrich(recordingID: String) async -> Enrichment {
        var e = Enrichment()
        // One request: performers, the linked work AND that work's own relations
        // (composer/lyricist, via work-level-rels), plus the releases — so we no
        // longer spend a second rate-limited request per track on the work.
        guard let rec: MBRecording = await get(
            "recording/\(recordingID)?inc=work-rels+work-level-rels+artist-rels+releases") else { return e }

        // performers + composer/lyricist (the latter from the work carried inline
        // via work-level-rels — no extra request per track).
        readCredits(rec.relations ?? [], into: &e)
        // label / catalog / date + Discogs link, via the first release
        if let releaseID = rec.releases?.first?.id {
            e.releaseMBID = releaseID
            let r = await cachedRelease(releaseID)
            e.label = r.label; e.catalogNumber = r.catalog; e.date = r.date
            // Discogs tops up the credits MusicBrainz is thin on (CC0, embeddable)
            if let discogsID = r.discogs, let d = await cachedDiscogs(discogsID) {
                mergeDiscogs(&e, d)
            }
        }
        return e
    }

    /// A single recording lookup only (1 request): performers + composer/lyricist
    /// + the recording's own release MBID (for artwork). No release/Discogs calls —
    /// used for a track that missed its album batch but can borrow that album's
    /// label/date instead of re-fetching them.
    func recordingOnly(recordingID: String) async -> Enrichment {
        var e = Enrichment()
        guard let rec: MBRecording = await get(
            "recording/\(recordingID)?inc=work-rels+work-level-rels+artist-rels+releases") else { return e }
        readCredits(rec.relations ?? [], into: &e)
        e.releaseMBID = rec.releases?.first?.id
        return e
    }

    /// Credits for an ENTIRE album in ~2 requests instead of one-per-track. Picks
    /// the seed track's release that matches the album tag (not just its first,
    /// which is often a single/compilation), then pulls that release's whole
    /// tracklist with every recording's performers and work's composer inline.
    /// Returns credits keyed by BOTH recording MBID and normalised title, so a
    /// track matches even when its fingerprint pointed at a different pressing.
    struct AlbumCredits {
        var byRecording: [String: Enrichment] = [:]
        var byTitle: [String: Enrichment] = [:]
        // album-level info a fallback track can borrow instead of re-fetching
        var releaseMBID: String? = nil
        var label: String? = nil
        var catalog: String? = nil
        var date: String? = nil
    }

    func albumCredits(seedRecordingID: String, albumTitle: String, groupSize: Int) async -> AlbumCredits {
        guard let rec: MBRecordingReleases = await get("recording/\(seedRecordingID)?inc=releases+media"),
              let releaseID = bestRelease(rec.releases, matching: albumTitle, size: groupSize),
              let rel: MBReleaseFull = await get(
                "release/\(releaseID)?inc=recordings+artist-rels+recording-level-rels+work-rels+work-level-rels+labels+url-rels")
        else { return AlbumCredits() }

        let label = rel.labelInfo?.first?.label?.name
        let catalog = rel.labelInfo?.first?.catalogNumber
        let date = rel.date
        // curated Discogs release link → fetch once, applied to every track
        var discogs: DiscogsRelease? = nil
        for r in rel.relations ?? [] where r.type == "discogs" {
            if let res = r.url?.resource, res.contains("/release/"),
               let last = res.split(separator: "/").last {
                let digits = String(last).filter { $0.isNumber }
                if !digits.isEmpty { discogs = await cachedDiscogs(digits); break }
            }
        }

        var out = AlbumCredits()
        out.releaseMBID = releaseID; out.label = label; out.catalog = catalog; out.date = date
        for m in rel.media ?? [] {
            for t in m.tracks ?? [] {
                guard let rc = t.recording else { continue }
                var e = Enrichment()
                e.releaseMBID = releaseID
                e.label = label; e.catalogNumber = catalog; e.date = date
                readCredits(rc.relations ?? [], into: &e)
                if let d = discogs { mergeDiscogs(&e, d) }
                if let rid = rc.id { out.byRecording[rid] = e }
                if let title = rc.title { out.byTitle[TrackProposal.typoFold(title).lowercased()] = e }
            }
        }
        return out
    }

    /// From the releases a recording appears on, choose the one to batch. Prefer an
    /// exact album-tag match, then a fuzzy one (either title contains the other —
    /// handles "Discovery" vs "Discovery (Deluxe)"). Among candidates, pick the
    /// pressing whose track count is CLOSEST to how many tracks we actually have
    /// for this album — the same-tracklist pressing, not a box set or a foreign
    /// edition with different songs (which gave near-zero batch coverage). Returns
    /// nil only when the recording has no releases at all.
    private func bestRelease(_ releases: [MBReleaseStub]?, matching album: String, size: Int) -> String? {
        guard let releases, !releases.isEmpty else { return nil }
        func tracks(_ r: MBReleaseStub) -> Int { (r.media ?? []).reduce(0) { $0 + ($1.trackCount ?? 0) } }
        // closest track count to `size`; ties broken toward the fuller pressing
        func pick(_ rs: [MBReleaseStub]) -> String? {
            rs.min(by: { a, b in
                let da = abs(tracks(a) - size), db = abs(tracks(b) - size)
                return da != db ? da < db : tracks(a) > tracks(b)
            })?.id
        }
        let key = TrackProposal.typoFold(album).lowercased()
        if !key.isEmpty {
            let exact = releases.filter { TrackProposal.typoFold($0.title ?? "").lowercased() == key }
            if let hit = pick(exact) { return hit }
            let fuzzy = releases.filter {
                let t = TrackProposal.typoFold($0.title ?? "").lowercased()
                return !t.isEmpty && (t.contains(key) || key.contains(t))
            }
            if let hit = pick(fuzzy) { return hit }
        }
        return pick(releases)
    }

    /// Pull performers and composer/lyricist out of a recording's relations.
    private func readCredits(_ relations: [MBRelation], into e: inout Enrichment) {
        for r in relations {
            if r.type == "instrument" || r.type == "vocal", let name = r.artist?.name {
                e.performers.append(.init(name: name, role: r.attributes?.first ?? r.type))
            }
            if let work = r.work {
                for x in work.relations ?? [] {
                    switch x.type {
                    case "composer": if e.composer == nil { e.composer = x.artist?.name }
                    case "lyricist": if e.lyricist == nil { e.lyricist = x.artist?.name }
                    case "writer":   if e.composer == nil { e.composer = x.artist?.name }
                    default: break
                    }
                }
            }
        }
    }

    /// Merge Discogs credits into the enrichment: fill blank composer/lyricist/
    /// label/date, and add the production + performer credits MusicBrainz lacks.
    private func mergeDiscogs(_ e: inout Enrichment, _ d: DiscogsRelease) {
        if e.label == nil { e.label = d.labels?.first?.name }
        if e.catalogNumber == nil { e.catalogNumber = d.labels?.first?.catno }
        if e.date == nil, let y = d.year, y > 0 { e.date = String(y) }
        var have = Set(e.performers.map { "\($0.name)|\($0.role)".lowercased() })
        for c in d.extraartists ?? [] {
            guard let name = c.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            for raw in (c.role ?? "").components(separatedBy: ",") {
                let role = raw.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                if role.isEmpty { continue }
                let low = role.lowercased()
                if e.composer == nil, low.contains("written-by") || low.contains("composed") || low == "music by" {
                    e.composer = name
                } else if e.lyricist == nil, low.contains("lyrics") || low.contains("words by") {
                    e.lyricist = name
                } else {
                    let key = "\(name)|\(role)".lowercased()
                    if !have.contains(key) { have.insert(key); e.performers.append(.init(name: name, role: role)) }
                }
            }
        }
    }

    private func cachedDiscogs(_ id: String) async -> DiscogsRelease? {
        if let c = discogsCache[id] { return c }
        discogsRequests += 1
        // 60/min with a token (~1s), 25/min without (~2.5s) — respect each limit.
        try? await Task.sleep(nanoseconds: discogsToken.isEmpty ? 2_500_000_000 : 1_050_000_000)
        var out: DiscogsRelease? = nil
        if let url = URL(string: "https://api.discogs.com/releases/\(id)") {
            var req = URLRequest(url: url)
            req.setValue(discogsUA, forHTTPHeaderField: "User-Agent")
            if !discogsToken.isEmpty {
                req.setValue("Discogs token=\(discogsToken)", forHTTPHeaderField: "Authorization")
            }
            if let (data, resp) = try? await session.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                out = try? JSONDecoder().decode(DiscogsRelease.self, from: data)
            }
        }
        discogsCache[id] = out
        return out
    }

    private func cachedRelease(_ id: String) async -> (label: String?, catalog: String?, date: String?, discogs: String?) {
        if let c = releaseCache[id] { return c }
        var out: (label: String?, catalog: String?, date: String?, discogs: String?) = (nil, nil, nil, nil)
        if let r: MBRelease = await get("release/\(id)?inc=labels+url-rels") {
            out.date = r.date
            if let li = r.labelInfo?.first {
                out.label = li.label?.name; out.catalog = li.catalogNumber
            }
            // curated Discogs release link → the numeric release id
            for rel in r.relations ?? [] where rel.type == "discogs" {
                if let res = rel.url?.resource, res.contains("/release/"),
                   let last = res.split(separator: "/").last {
                    let digits = String(last).filter { $0.isNumber }
                    if !digits.isEmpty { out.discogs = digits; break }
                }
            }
        }
        releaseCache[id] = out
        return out
    }

    /// One MusicBrainz GET, JSON-decoded, after a courtesy delay for the rate limit.
    private func get<T: Decodable>(_ path: String) async -> T? {
        mbRequests += 1
        try? await Task.sleep(nanoseconds: 1_000_000_000)   // ~1 req/sec (request latency adds headroom)
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
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 45
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
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

    /// Resolve ONE cover for a whole album: try each of the album's release MBIDs
    /// against the Cover Art Archive, and if none has an image fall back to Apple's
    /// free iTunes Search artwork (which covers well-known albums the Archive misses,
    /// e.g. Aretha's Gold). Returns the first image found, or nil.
    func albumCover(releaseMBIDs: [String], artist: String, album: String) async -> Data? {
        for mbid in releaseMBIDs {
            if let d = await frontCover(releaseMBID: mbid) { return d }
        }
        return await itunesCover(artist: artist, album: album)
    }

    /// Apple iTunes Search artwork (no key; ~20 req/min). Upsizes the 100px thumb
    /// URL to 600px. Picks the album result whose title best matches.
    func itunesCover(artist: String, album: String) async -> Data? {
        guard !album.isEmpty else { return nil }
        let key = "itunes|" + artist.lowercased() + "|" + album.lowercased()
        if let c = cache[key] { return c }
        var result: Data? = nil
        let termRaw = (artist + " " + album).trimmingCharacters(in: .whitespaces)
        let term = termRaw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "https://itunes.apple.com/search?term=\(term)&entity=album&limit=8"),
           let (data, resp) = try? await session.data(from: url),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = json["results"] as? [[String: Any]] {
            let wantAlbum = TrackProposal.typoFold(album).lowercased()
            // Only accept a title that actually matches — otherwise iTunes returns the
            // artist's top album and we'd embed a confidently-wrong cover. No match →
            // nil, which flags the album for the manual artwork picker instead.
            let ranked = results.compactMap { r -> (Int, [String: Any])? in
                let cn = TrackProposal.typoFold((r["collectionName"] as? String ?? "")).lowercased()
                let score = cn == wantAlbum ? 2 : (cn.contains(wantAlbum) || wantAlbum.contains(cn) ? 1 : 0)
                return score > 0 ? (score, r) : nil
            }.sorted { $0.0 > $1.0 }
            for (_, r) in ranked {
                guard let art = r["artworkUrl100"] as? String else { continue }
                let big = art.replacingOccurrences(of: "100x100bb", with: "600x600bb")
                if let iu = URL(string: big),
                   let (d, ir) = try? await session.data(from: iu),
                   (ir as? HTTPURLResponse)?.statusCode == 200, !d.isEmpty {
                    result = d; break
                }
            }
        }
        cache[key] = result
        return result
    }
}
