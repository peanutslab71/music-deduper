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
                  curArtist: String, curTitle: String, curAlbum: String) async throws -> TrackProposal? {
        guard !apiKey.isEmpty else { throw IdentifyError.noKey }

        let fp: AudioFingerprint
        do { fp = try AudioFingerprint(from: url) }
        catch { throw IdentifyError.fingerprint(error) }

        let (score, rec) = try await lookup(fingerprint: fp.base64, duration: Int(fp.duration.rounded()))
        guard let rec else { return nil }

        let artist = (rec.artists ?? []).compactMap { $0.name }.joined(separator: ", ")
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
            accepted: true)
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
