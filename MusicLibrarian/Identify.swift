//
//  Identify.swift
//  MusicLibrarian
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

// MARK: - MusicBrainz text-search response (recording → releases → album)

private struct MBRecordingSearch: Decodable {
    let recordings: [Rec]?
    struct Rec: Decodable { let releases: [Rel]? }
    struct Rel: Decodable {
        let title: String?
        let releaseGroup: RG?
        enum CodingKeys: String, CodingKey { case title; case releaseGroup = "release-group" }
    }
    struct RG: Decodable {
        let title: String?
        let primaryType: String?
        enum CodingKeys: String, CodingKey { case title; case primaryType = "primary-type" }
    }
}

// MARK: - Proposal

/// One track's identification result — the current tags vs. what the acoustic
/// match says they should be. Album is a chosen suggestion, editable.
struct TrackProposal: Identifiable, Codable {
    var id = UUID()
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

    /// Split a stuffed artist tag into a PRIMARY artist plus guest/session performers,
    /// the Roon-correct shape (one artist per track; everyone else is a credit). Returns
    /// nil when it's a single act or a real band/duo we must not break.
    ///
    /// `confident` distinguishes the safe machine-joined cases from ambiguous lists:
    ///  • "A feat./ft./featuring B"          → primary A, guest B      (confident)
    ///  • "A,B" (comma with NO space)         → machine join, split all (confident)
    ///  • "A, B, C & D" (spaced comma list)   → split, but confident=false — a spaced
    ///    "&"/comma list can be a band ("Crosby, Stills, Nash & Young"), so callers
    ///    should REVIEW these, not auto-apply.
    /// A bare "A & B" / "A and B" with no comma (Simon & Garfunkel, Aerosmith & Run-DMC)
    /// is treated as one band name → nil.
    static func splitArtistCredit(_ raw: String) -> (primary: String, performers: [(name: String, role: String)], confident: Bool)? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !Identifier.isJunkValue(s) else { return nil }

        func parts(_ str: String) -> [String] {
            str.components(separatedBy: CharacterSet(charactersIn: ",&"))
               .flatMap { $0.components(separatedBy: " and ") }
               .map { $0.trimmingCharacters(in: .whitespaces) }
               .filter { !$0.isEmpty }
        }

        // 1) feat/ft/featuring — a pop guest, unambiguous. All extras are performers.
        if let r = s.range(of: #"\s+(feat\.?|ft\.?|featuring)\s+"#, options: [.regularExpression, .caseInsensitive]) {
            // "A, feat. B" / "A & feat. B": the regex anchors on whitespace, so a
            // separator just before the keyword would survive into the primary
            let primary = String(s[s.startIndex..<r.lowerBound])
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",&")))
            let rest = parts(String(s[r.upperBound...]))
            guard !primary.isEmpty, !rest.isEmpty else { return nil }
            return (primary, rest.map { ($0, "performer") }, true)
        }
        // 2) comma present → a list of contributors. The PRIMARY is everything before
        // the first comma, kept intact — so a band whose own name contains "&" ("Hall &
        // Oates, Guest", "Simon & Garfunkel, London Symphony Orchestra") isn't truncated
        // to the fragment before the "&". Only the remainder is split into credits.
        if let comma = s.firstIndex(of: ",") {
            let primary = String(s[s.startIndex..<comma]).trimmingCharacters(in: .whitespaces)
            let extras = parts(String(s[s.index(after: comma)...]))
            guard !primary.isEmpty, !extras.isEmpty else { return nil }
            // Everyone after the primary becomes a NEUTRAL "performer" credit. Their real
            // role (conductor, orchestra, choir, soloist, instrument…) is typed by the
            // Credits step from the authoritative MusicBrainz/Discogs relationship data —
            // not guessed from words in the tag. So only a machine-join ("A,B" — a comma
            // with no space, never a human-written band name) auto-applies. A spaced list
            // ("A, B & C") could be a band, so without a lookup it's offered for review,
            // not applied.
            let machineJoin = s.range(of: #",\S"#, options: .regularExpression) != nil
            return (primary, extras.map { ($0, "performer") }, machineJoin)
        }
        // 3) no comma: a bare "&"/"and" is a band/duo name — leave it
        return nil
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

    /// The AcoustID key the run will use: the user's Keychain entry (Settings),
    /// falling back to a value baked in via Secrets.xcconfig for dev builds.
    static var configuredKey: String { APIKeys.acoustID }

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

    /// Text-search MusicBrainz for the album a recording appears on, for tracks the
    /// audio fingerprint couldn't place. Best-effort: prefers a studio album over a
    /// compilation/single, skips placeholder titles. Paced by the caller (~1/sec).
    func searchAlbum(artist: String, title: String) async -> String? {
        let a = artist.trimmingCharacters(in: .whitespaces)
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty, !t.isEmpty else { return nil }
        var comps = URLComponents(string: "https://musicbrainz.org/ws/2/recording")!
        comps.queryItems = [
            URLQueryItem(name: "query", value: "recording:\"\(t)\" AND artist:\"\(a)\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "3"),
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("MusicLibrarian ( \(APIKeys.contact) )", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: req),
              let res = try? JSONDecoder().decode(MBRecordingSearch.self, from: data) else { return nil }

        var candidates: [(title: String, isAlbum: Bool)] = []
        for rec in res.recordings ?? [] {
            for rel in rec.releases ?? [] {
                guard let name = rel.releaseGroup?.title ?? rel.title,
                      !name.isEmpty, !Organiser.isPlaceholderAlbum(name) else { continue }
                candidates.append((name, (rel.releaseGroup?.primaryType ?? "") == "Album"))
            }
        }
        if let studio = candidates.first(where: { $0.isAlbum }) { return studio.title }   // prefer a studio album
        let counts = Dictionary(grouping: candidates.map { $0.title }, by: { $0.lowercased() }).mapValues { $0.count }
        if let top = counts.max(by: { $0.value < $1.value }) {
            return candidates.first { $0.title.lowercased() == top.key }?.title
        }
        return nil
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
        req.setValue("MusicLibrarian ( neil.cottyincar@gmail.com )", forHTTPHeaderField: "User-Agent")

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
struct Enrichment: Codable {
    var composer: String?
    var lyricist: String?
    var label: String?
    var catalogNumber: String?
    var date: String?
    var performers: [Performer] = []       // (name, role) — go in the credits field, never artist
    var releaseMBID: String?               // for fetching cover art (not a credit itself)
    struct Performer: Codable { let name: String; let role: String }

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

// Reconcile: the full per-disc tracklist of a release, so a folder can be checked
// against what the album SHOULD contain (missing-track detection).
struct MBReleaseTrack: Sendable, Codable { let disc: Int; let track: Int; let title: String; let lengthMs: Int? }
struct MBReleaseMatch: Sendable, Codable { let id: String; let title: String; let date: String?; let discCount: Int; let tracks: [MBReleaseTrack] }

private struct MBSearchResult: Decodable { let releases: [MBSearchRelease]? }
private struct MBSearchRelease: Decodable {
    let id: String
    let title: String?
    let date: String?
    let media: [MBSearchMedia]?
}
private struct MBSearchMedia: Decodable {
    let position: Int?
    let format: String?
    let trackCount: Int?
    enum CodingKeys: String, CodingKey { case position, format; case trackCount = "track-count" }
}
private struct MBTracklistRelease: Decodable {
    let id: String?
    let title: String?
    let date: String?
    let media: [MBTracklistMedia]?
}
private struct MBTracklistMedia: Decodable {
    let position: Int?
    let tracks: [MBTracklistTrack]?
}
private struct MBTracklistTrack: Decodable {
    let position: Int?
    let number: String?
    let title: String?
    let length: Int?   // milliseconds
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

// ---- Extra reconcile/artwork sources: Deezer (no key) and Discogs release tracklists ----
// Deezer: album search → cover_xl (~1000px) + full ordered tracklist. Free, no key.
private struct DeezerSearch: Decodable { let data: [DeezerAlbum]? }
private struct DeezerAlbum: Decodable {
    let id: Int?
    let title: String?
    let artist: DeezerArtist?
    let cover_xl: String?
    let nb_tracks: Int?
}
private struct DeezerArtist: Decodable { let name: String? }
private struct DeezerAlbumDetail: Decodable {
    let title: String?
    let release_date: String?
    let tracks: DeezerTrackList?
}
private struct DeezerTrackList: Decodable { let data: [DeezerTrack]? }
private struct DeezerTrack: Decodable {
    let title: String?
    let disk_number: Int?
    let track_position: Int?
    let duration: Int?   // SECONDS on Deezer (MB/our model use ms)
}

// Discogs: release search → full tracklist + release images. Best coverage for
// compilations, reissues and box-sets that MusicBrainz is thin on. Optional token
// (Settings) lifts the rate limit; the existing discogsToken/UA are reused.
private struct DiscogsSearch: Decodable { let results: [DiscogsSearchResult]? }
private struct DiscogsSearchResult: Decodable {
    let id: Int?
    let title: String?
    let format: [String]?
    let year: String?
}
private struct DiscogsReleaseFull: Decodable {
    let title: String?
    let released: String?
    let year: Int?
    let tracklist: [DiscogsTrack]?
    let images: [DiscogsImage]?
}
private struct DiscogsTrack: Decodable {
    let position: String?
    let title: String?
    let duration: String?
    let type_: String?
}
private struct DiscogsImage: Decodable { let type: String?; let uri: String? }

// Deezer TRACK search — for a short preview clip to confirm an identify match by ear.
private struct DeezerTrackSearch: Decodable { let data: [DeezerTrackHit]? }
private struct DeezerTrackHit: Decodable {
    let title: String?
    let artist: DeezerArtist?
    let preview: String?   // ~30s MP3 URL
}

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
    // Identify ourselves to MusicBrainz with the user's contact (Settings), or
    // the app default when they haven't set one.
    private let userAgent = "MusicLibrarian ( \(APIKeys.contact) )"
    private let discogsUA = "MusicLibrarian/1.4 +https://github.com/peanutslab71/music-librarian"
    // Optional Discogs personal token (Settings → Keychain, or Secrets.xcconfig
    // fallback). Present → 60/min and authenticated; blank → 25/min.
    private let discogsToken = APIKeys.discogs
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

    /// Find the MusicBrainz release that best matches this album+artist and return its
    /// full per-disc tracklist, so a folder can be reconciled against what the album
    /// SHOULD contain. Picks a release whose disc count matches and whose tracklist
    /// actually contains the songs we have (≥60% title overlap); returns nil when no
    /// candidate lines up (so we never grey the wrong gaps).
    func matchRelease(artist: String, album: String, haveTitles: [String], discCount: Int) async -> MBReleaseMatch? {
        let lucene = "release:\"\(album)\" AND artist:\"\(artist)\""
        guard let enc = lucene.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let search: MBSearchResult = await get("release?query=\(enc)&limit=15") else { return nil }
        let cands = search.releases ?? []
        guard !cands.isEmpty else { return nil }
        func discs(_ r: MBSearchRelease) -> Int { r.media?.count ?? 0 }
        func total(_ r: MBSearchRelease) -> Int { (r.media ?? []).reduce(0) { $0 + ($1.trackCount ?? 0) } }
        let albumKey = TrackProposal.typoFold(album).lowercased()
        let ranked = cands.sorted { a, b in
            let da = discs(a) == discCount, db = discs(b) == discCount
            if da != db { return da }                       // disc count match first
            let ta = TrackProposal.typoFold(a.title ?? "").lowercased() == albumKey
            let tb = TrackProposal.typoFold(b.title ?? "").lowercased() == albumKey
            if ta != tb { return ta }                       // then exact title
            return total(a) > total(b)                      // then the fuller pressing
        }
        let want = Set(haveTitles.map { TrackProposal.typoFold($0).lowercased() }.filter { !$0.isEmpty })
        guard !want.isEmpty else { return nil }
        for cand in ranked.prefix(4) {
            guard let full: MBTracklistRelease = await get("release/\(cand.id)?inc=recordings") else { continue }
            var out: [MBReleaseTrack] = []
            for m in full.media ?? [] {
                let disc = m.position ?? 1
                for t in m.tracks ?? [] {
                    let tn = t.position ?? Int(t.number ?? "") ?? 0
                    out.append(MBReleaseTrack(disc: disc, track: tn, title: t.title ?? "", lengthMs: t.length))
                }
            }
            guard !out.isEmpty else { continue }
            let relTitles = Set(out.map { TrackProposal.typoFold($0.title).lowercased() })
            let overlap = want.filter { relTitles.contains($0) }.count
            if Double(overlap) / Double(want.count) >= 0.6 {
                return MBReleaseMatch(id: cand.id, title: full.title ?? cand.title ?? album,
                                      date: full.date ?? cand.date,
                                      discCount: full.media?.count ?? (out.map { $0.disc }.max() ?? 1),
                                      tracks: out)
            }
        }
        return nil
    }

    // ---- Multi-source reconcile ------------------------------------------------
    // MusicBrainz alone is thin on obscure comps/box-sets, so the missing-track
    // check tries several sources and keeps the tracklist that best fits what's on
    // disk. Data (titles/order) is CC0 from MB, licence-clean from Discogs; Deezer
    // is used only to fill gaps the others miss. Same reference tracklist also
    // drives disc assignment, so a richer match fixes reordering too.

    /// How well a candidate tracklist fits the folder: fraction of on-disk titles
    /// present in the release. Only tracklists clearing 0.6 are trusted.
    private func overlap(_ tracks: [MBReleaseTrack], _ want: Set<String>) -> Double {
        guard !want.isEmpty else { return 0 }
        let have = Set(tracks.map { TrackProposal.typoFold($0.title).lowercased() })
        return Double(want.filter { have.contains($0) }.count) / Double(want.count)
    }

    /// Try MusicBrainz, Discogs and Deezer, then keep the tracklist that fits the
    /// folder best. Ties break toward the disc-count match, then the fuller
    /// pressing (box-sets/comps list more, which is what we want to reconcile
    /// against). Declines when nothing clears the overlap gate.
    func bestRelease(artist: String, album: String, haveTitles: [String], discCount: Int) async -> MBReleaseMatch? {
        let want = Set(haveTitles.map { TrackProposal.typoFold($0).lowercased() }.filter { !$0.isEmpty })
        guard !want.isEmpty else { return nil }
        var cands: [MBReleaseMatch] = []
        if let m = await matchRelease(artist: artist, album: album, haveTitles: haveTitles, discCount: discCount) { cands.append(m) }
        if let d = await matchReleaseDiscogs(artist: artist, album: album, want: want) { cands.append(d) }
        if let z = await matchReleaseDeezer(artist: artist, album: album, want: want) { cands.append(z) }
        guard !cands.isEmpty else { return nil }
        return cands.max { a, b in
            let oa = overlap(a.tracks, want), ob = overlap(b.tracks, want)
            if abs(oa - ob) > 0.05 { return oa < ob }             // best fit first
            let da = a.discCount == discCount, db = b.discCount == discCount
            if da != db { return db }                             // then disc-count match
            return a.tracks.count < b.tracks.count                // then the fuller list
        }
    }

    /// Discogs release tracklist. Searches releases by artist + title, pulls the
    /// first whose tracklist clears the overlap gate. Skips heading/index rows and
    /// derives (disc, track) from Discogs positions ("2-13", "A1", "5").
    private func matchReleaseDiscogs(artist: String, album: String, want: Set<String>) async -> MBReleaseMatch? {
        guard !discogsToken.isEmpty else { return nil }   // /database/search 401s anonymously
        var comps = URLComponents(string: "https://api.discogs.com/database/search")!
        comps.queryItems = [.init(name: "type", value: "release"),
                            .init(name: "artist", value: artist),
                            .init(name: "release_title", value: album)]
        guard let searchURL = comps.url,
              let search: DiscogsSearch = await getDiscogs(searchURL),
              let hits = search.results, !hits.isEmpty else { return nil }
        for hit in hits.prefix(4) {
            guard let id = hit.id,
                  let url = URL(string: "https://api.discogs.com/releases/\(id)"),
                  let rel: DiscogsReleaseFull = await getDiscogs(url) else { continue }
            let tracks = Self.discogsTracks(rel.tracklist ?? [])
            guard !tracks.isEmpty, overlap(tracks, want) >= 0.6 else { continue }
            let date = rel.released?.isEmpty == false ? rel.released : rel.year.map(String.init)
            return MBReleaseMatch(id: "discogs:\(id)", title: rel.title ?? album, date: date,
                                  discCount: max(1, tracks.map { $0.disc }.max() ?? 1), tracks: tracks)
        }
        return nil
    }

    /// Turn Discogs positions into ordered (disc, track). Non-playable rows
    /// (headings, index tracks with no position) are dropped; a running counter
    /// backs up any position we can't parse so titles still line up.
    private static func discogsTracks(_ raw: [DiscogsTrack]) -> [MBReleaseTrack] {
        var out: [MBReleaseTrack] = []
        var run = 0
        var disc = 1, prevPlain = 0
        for t in raw {
            if let ty = t.type_, ty != "track" { continue }       // heading / index
            guard let title = t.title, !title.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            run += 1
            // Discogs puts the disc/medium in a SEPARATE field, not the position string:
            //  • an explicit numeric "disc-track" ("2-13") gives disc+track directly;
            //  • a plain "5" is a track WITHIN the current medium — Discogs restarts at 1
            //    for each disc, so when the number goes backwards a new disc has begun
            //    (without this, a 2-CD release collapses to one disc with duplicate track
            //    numbers, and songs you own show as "missing");
            //  • a vinyl side ("A1","B2") has no reliable number → running counter, one disc.
            var track = run
            let pos = (t.position ?? "").trimmingCharacters(in: .whitespaces)
            if pos.range(of: #"^\d+-\d+$"#, options: .regularExpression) != nil {
                let parts = pos.split(separator: "-")
                if let d = Int(parts[0]), let n = Int(parts[1]) { disc = d; track = n; prevPlain = n }
            } else if pos.range(of: #"^\d+$"#, options: .regularExpression) != nil, let n = Int(pos) {
                if n <= prevPlain { disc += 1 }                    // numbering reset → next disc
                track = n; prevPlain = n
            }                                                      // else (vinyl side / blank): keep run
            out.append(MBReleaseTrack(disc: max(1, disc), track: track, title: title, lengthMs: Self.parseDuration(t.duration)))
        }
        return out
    }

    private static func parseDuration(_ s: String?) -> Int? {
        guard let s = s, s.contains(":") else { return nil }
        let p = s.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2 else { return nil }
        return (p[0] * 60 + p[1]) * 1000
    }

    /// Deezer album tracklist (no key). Searches albums by artist+title, takes the
    /// best title/artist match, then pulls its full ordered tracklist.
    private func matchReleaseDeezer(artist: String, album: String, want: Set<String>) async -> MBReleaseMatch? {
        guard let alb = await deezerAlbum(artist: artist, album: album), let id = alb.id,
              let url = URL(string: "https://api.deezer.com/album/\(id)"),
              let detail: DeezerAlbumDetail = await getDeezer(url) else { return nil }
        var out: [MBReleaseTrack] = []
        var perDisc: [Int: Int] = [:]   // fallback counter resets per disc, not per release
        for t in detail.tracks?.data ?? [] {
            guard let title = t.title, !title.isEmpty else { continue }
            let disc = max(1, t.disk_number ?? 1)
            perDisc[disc, default: 0] += 1
            out.append(MBReleaseTrack(disc: disc, track: t.track_position ?? perDisc[disc]!,
                                      title: title, lengthMs: t.duration.map { $0 * 1000 }))
        }
        guard !out.isEmpty, overlap(out, want) >= 0.6 else { return nil }
        return MBReleaseMatch(id: "deezer:\(id)", title: detail.title ?? album, date: detail.release_date,
                              discCount: max(1, out.map { $0.disc }.max() ?? 1), tracks: out)
    }

    /// Find the best-matching Deezer album for artist+title (shared by reconcile).
    private func deezerAlbum(artist: String, album: String) async -> DeezerAlbum? {
        let q = "artist:\"\(artist)\" album:\"\(album)\""
        guard let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search/album?q=\(enc)&limit=10"),
              let search: DeezerSearch = await getDeezer(url) else { return nil }
        let wantAlbum = TrackProposal.typoFold(album).lowercased()
        let wantArtist = TrackProposal.typoFold(artist).lowercased()
        return (search.data ?? []).max { a, b in
            func score(_ x: DeezerAlbum) -> Int {
                let cn = TrackProposal.typoFold(x.title ?? "").lowercased()
                let an = TrackProposal.typoFold(x.artist?.name ?? "").lowercased()
                let al = cn == wantAlbum ? 2 : (cn.contains(wantAlbum) || wantAlbum.contains(cn) ? 1 : 0)
                let ar = !wantArtist.isEmpty && (an == wantArtist || an.contains(wantArtist) || wantArtist.contains(an)) ? 1 : 0
                return al > 0 && ar > 0 ? al + ar : 0
            }
            return score(a) < score(b)
        }.flatMap { alb in
            // require a real match, not just "the first album Deezer returned"
            let cn = TrackProposal.typoFold(alb.title ?? "").lowercased()
            let an = TrackProposal.typoFold(alb.artist?.name ?? "").lowercased()
            let al = cn == wantAlbum || cn.contains(wantAlbum) || wantAlbum.contains(cn)
            let ar = wantArtist.isEmpty || an == wantArtist || an.contains(wantArtist) || wantArtist.contains(an)
            return (al && ar) ? alb : nil
        }
    }

    // Deezer: no key, generous limits — a light pause is enough.
    private func getDeezer<T: Decodable>(_ url: URL) async -> T? {
        try? await Task.sleep(nanoseconds: 350_000_000)
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: req) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // Discogs: reuse the same token + UA + pacing as the credits path.
    private func getDiscogs<T: Decodable>(_ url: URL) async -> T? {
        discogsRequests += 1
        try? await Task.sleep(nanoseconds: discogsToken.isEmpty ? 2_500_000_000 : 1_050_000_000)
        var req = URLRequest(url: url)
        req.setValue(discogsUA, forHTTPHeaderField: "User-Agent")
        if !discogsToken.isEmpty { req.setValue("Discogs token=\(discogsToken)", forHTTPHeaderField: "Authorization") }
        guard let (data, _) = try? await session.data(for: req) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
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
        if let url = URL(string: "https://coverartarchive.org/release/\(releaseMBID)/front-1200") {
            var req = URLRequest(url: url)
            req.setValue("MusicLibrarian ( neil.cottyincar@gmail.com )", forHTTPHeaderField: "User-Agent")
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

    /// SEVERAL candidate covers for manual review — every release MBID's Cover Art
    /// Archive image plus the top matching iTunes results, deduped. This is what the
    /// Artwork step shows so you can pick the right one from the services, rather
    /// than trusting a single auto-picked cover.
    func candidates(releaseMBIDs: [String], artist: String, album: String) async -> [Data] {
        var out: [Data] = []
        var seen = Set<String>()
        func add(_ d: Data) {
            let k = "\(d.count):" + String(d.prefix(48).reduce(UInt64(0)) { $0 &+ UInt64($1) })
            if seen.insert(k).inserted { out.append(d) }
        }
        for mbid in releaseMBIDs { if let d = await frontCover(releaseMBID: mbid) { add(d) } }
        for d in await itunesCovers(artist: artist, album: album) { add(d) }
        for d in await deezerCovers(artist: artist, album: album) { add(d) }
        for d in await discogsCovers(artist: artist, album: album) { add(d) }
        return out
    }

    /// Deezer album cover (cover_xl, ~1000px). No key. Only the best title+artist
    /// match, so we never grab another album's art.
    /// A short (~30s) preview clip of a track, so you can confirm an identify match by
    /// ear before accepting it. Tries iTunes (previewUrl) then Deezer (preview), and
    /// downloads to a temp file AVAudioPlayer can play. Returns nil if neither has one.
    func trackPreview(artist: String, title: String) async -> URL? {
        guard !title.isEmpty else { return nil }
        var src = await itunesPreviewURL(artist: artist, title: title)
        if src == nil { src = await deezerPreviewURL(artist: artist, title: title) }
        guard let u = src,
              let (data, resp) = try? await session.data(from: u),
              (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        let ext = u.pathExtension.isEmpty ? "m4a" : u.pathExtension
        var h: UInt64 = 5381; for b in "\(artist)|\(title)".utf8 { h = (h &* 33) &+ UInt64(b) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mlpreview-\(String(h, radix: 16)).\(ext)")
        do { try data.write(to: tmp) } catch { return nil }
        return tmp
    }

    private func itunesPreviewURL(artist: String, title: String) async -> URL? {
        let termRaw = (artist + " " + title).trimmingCharacters(in: .whitespaces)
        guard let term = termRaw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(term)&entity=song&limit=15"),
              let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        let wantTitle = TrackProposal.typoFold(title).lowercased()
        let wantArtist = TrackProposal.typoFold(artist).lowercased()
        let ranked = results.compactMap { r -> (Int, String)? in
            guard let preview = r["previewUrl"] as? String else { return nil }
            let tn = TrackProposal.typoFold(r["trackName"] as? String ?? "").lowercased()
            let an = TrackProposal.typoFold(r["artistName"] as? String ?? "").lowercased()
            let titleOK = tn == wantTitle || tn.contains(wantTitle) || wantTitle.contains(tn)
            let artistOK = wantArtist.isEmpty || an == wantArtist || an.contains(wantArtist) || wantArtist.contains(an)
            guard titleOK else { return nil }
            return (artistOK ? 2 : 1, preview)
        }.sorted { $0.0 > $1.0 }
        return ranked.first.flatMap { URL(string: $0.1) }
    }

    private func deezerPreviewURL(artist: String, title: String) async -> URL? {
        let q = "track:\"\(title)\" artist:\"\(artist)\""
        guard let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search?q=\(enc)&limit=10"),
              let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let search = try? JSONDecoder().decode(DeezerTrackSearch.self, from: data) else { return nil }
        let wantTitle = TrackProposal.typoFold(title).lowercased()
        let wantArtist = TrackProposal.typoFold(artist).lowercased()
        let hit = (search.data ?? []).first { h in
            let tn = TrackProposal.typoFold(h.title ?? "").lowercased()
            let an = TrackProposal.typoFold(h.artist?.name ?? "").lowercased()
            let titleOK = tn == wantTitle || tn.contains(wantTitle) || wantTitle.contains(tn)
            let artistOK = wantArtist.isEmpty || an == wantArtist || an.contains(wantArtist) || wantArtist.contains(an)
            return titleOK && artistOK && !(h.preview ?? "").isEmpty
        }
        return hit?.preview.flatMap { URL(string: $0) }
    }

    func deezerCovers(artist: String, album: String, limit: Int = 3) async -> [Data] {
        guard !album.isEmpty else { return [] }
        let q = "artist:\"\(artist)\" album:\"\(album)\""
        guard let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search/album?q=\(enc)&limit=10") else { return [] }
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let search = try? JSONDecoder().decode(DeezerSearch.self, from: data) else { return [] }
        let wantAlbum = TrackProposal.typoFold(album).lowercased()
        let wantArtist = TrackProposal.typoFold(artist).lowercased()
        var out: [Data] = []
        for alb in search.data ?? [] {
            let cn = TrackProposal.typoFold(alb.title ?? "").lowercased()
            let an = TrackProposal.typoFold(alb.artist?.name ?? "").lowercased()
            let al = cn == wantAlbum || cn.contains(wantAlbum) || wantAlbum.contains(cn)
            let ar = wantArtist.isEmpty || an == wantArtist || an.contains(wantArtist) || wantArtist.contains(an)
            guard al, ar, let cover = alb.cover_xl, let cu = URL(string: cover) else { continue }
            if let (d, ir) = try? await session.data(from: cu),
               (ir as? HTTPURLResponse)?.statusCode == 200, !d.isEmpty { out.append(d) }
            if out.count >= limit { break }
        }
        return out
    }

    /// Discogs release cover (primary image), for the comps/box-sets the other
    /// services miss. Needs the user's Discogs token (Settings) — skipped without it.
    func discogsCovers(artist: String, album: String, limit: Int = 2) async -> [Data] {
        let token = APIKeys.discogs
        guard !token.isEmpty, !album.isEmpty else { return [] }
        let ua = "MusicLibrarian/1.4 +https://github.com/peanutslab71/music-librarian"
        var comps = URLComponents(string: "https://api.discogs.com/database/search")!
        comps.queryItems = [.init(name: "type", value: "release"),
                            .init(name: "artist", value: artist),
                            .init(name: "release_title", value: album)]
        func fetch(_ url: URL) async -> Data? {
            try? await Task.sleep(nanoseconds: 1_050_000_000)
            var req = URLRequest(url: url)
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            req.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
            guard let (d, r) = try? await session.data(for: req),
                  (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return d
        }
        guard let searchURL = comps.url, let sd = await fetch(searchURL),
              let search = try? JSONDecoder().decode(DiscogsSearch.self, from: sd) else { return [] }
        var out: [Data] = []
        for hit in (search.results ?? []).prefix(limit) {
            guard let id = hit.id, let url = URL(string: "https://api.discogs.com/releases/\(id)"),
                  let rd = await fetch(url),
                  let rel = try? JSONDecoder().decode(DiscogsReleaseFull.self, from: rd) else { continue }
            let imgs = rel.images ?? []
            let pick = imgs.first(where: { $0.type == "primary" }) ?? imgs.first
            guard let uri = pick?.uri, let iu = URL(string: uri) else { continue }
            var ireq = URLRequest(url: iu)
            ireq.setValue(ua, forHTTPHeaderField: "User-Agent")
            if let (d, ir) = try? await session.data(for: ireq),
               (ir as? HTTPURLResponse)?.statusCode == 200, !d.isEmpty { out.append(d) }
        }
        return out
    }

    /// The matched iTunes album-artwork URLs (metadata only — fast), upsized to
    /// 1200px. ONLY covers whose album title actually matches (exact, or one
    /// contains the other) — never the whole artist catalogue.
    func itunesArtworkURLs(artist: String, album: String, limit: Int = 6) async -> [URL] {
        guard !album.isEmpty else { return [] }
        let termRaw = (artist + " " + album).trimmingCharacters(in: .whitespaces)
        let term = termRaw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://itunes.apple.com/search?term=\(term)&entity=album&limit=15"),
              let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        let wantAlbum = TrackProposal.typoFold(album).lowercased()
        let wantArtist = TrackProposal.typoFold(artist).lowercased()
        let ranked = results.compactMap { r -> (Int, [String: Any])? in
            let cn = TrackProposal.typoFold((r["collectionName"] as? String ?? "")).lowercased()
            let an = TrackProposal.typoFold((r["artistName"] as? String ?? "")).lowercased()
            let albumScore = cn == wantAlbum ? 2 : ((cn.contains(wantAlbum) || wantAlbum.contains(cn)) ? 1 : 0)
            // the ARTIST must match too — titles like "Greatest Hits" / "The Singles
            // Collection" are shared by dozens of artists, so a title-only match
            // pulled the wrong artist's cover (Creedence for The Special AKA).
            let artistOK = !wantArtist.isEmpty && (an == wantArtist || an.contains(wantArtist) || wantArtist.contains(an))
            return (albumScore > 0 && artistOK) ? (albumScore, r) : nil
        }.sorted { $0.0 > $1.0 }
        return ranked.prefix(limit).compactMap { (_, r) in
            guard let art = r["artworkUrl100"] as? String else { return nil }
            return URL(string: art.replacingOccurrences(of: "100x100bb", with: "1200x1200bb"))
        }
    }

    /// The top matching iTunes album covers (not just the single best one), for the picker.
    func itunesCovers(artist: String, album: String, limit: Int = 6) async -> [Data] {
        var out: [Data] = []
        for u in await itunesArtworkURLs(artist: artist, album: album, limit: limit) {
            if let (d, ir) = try? await session.data(from: u),
               (ir as? HTTPURLResponse)?.statusCode == 200, !d.isEmpty { out.append(d) }
        }
        return out
    }

    /// Stream candidate covers to `onEach` IN ORDER as each finishes downloading —
    /// Cover Art Archive (by MBID) first, then matching iTunes — so the picker
    /// fills progressively instead of appearing all at once after a long wait.
    func streamCandidates(releaseMBIDs: [String], artist: String, album: String,
                          onEach: @escaping (Data) async -> Void) async {
        for mbid in releaseMBIDs {
            if let d = await frontCover(releaseMBID: mbid) { await onEach(d) }
        }
        for u in await itunesArtworkURLs(artist: artist, album: album) {
            if let (d, ir) = try? await session.data(from: u),
               (ir as? HTTPURLResponse)?.statusCode == 200, !d.isEmpty { await onEach(d) }
        }
        for d in await deezerCovers(artist: artist, album: album) { await onEach(d) }
        for d in await discogsCovers(artist: artist, album: album) { await onEach(d) }
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
            let wantArtist = TrackProposal.typoFold(artist).lowercased()
            // Album title AND artist must match — otherwise iTunes hands back another
            // artist's same-titled album and we'd embed a confidently-wrong cover.
            let ranked = results.compactMap { r -> (Int, [String: Any])? in
                let cn = TrackProposal.typoFold((r["collectionName"] as? String ?? "")).lowercased()
                let an = TrackProposal.typoFold((r["artistName"] as? String ?? "")).lowercased()
                let albumScore = cn == wantAlbum ? 2 : (cn.contains(wantAlbum) || wantAlbum.contains(cn) ? 1 : 0)
                let artistOK = !wantArtist.isEmpty && (an == wantArtist || an.contains(wantArtist) || wantArtist.contains(an))
                return (albumScore > 0 && artistOK) ? (albumScore, r) : nil
            }.sorted { $0.0 > $1.0 }
            for (_, r) in ranked {
                guard let art = r["artworkUrl100"] as? String else { continue }
                let big = art.replacingOccurrences(of: "100x100bb", with: "1200x1200bb")
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
