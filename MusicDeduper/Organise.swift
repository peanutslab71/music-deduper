//
//  Organise.swift
//  MusicDeduper
//
//  The Organise stage's brain: turn each track's TAGS into the gold-standard
//  clean tree — Album Artist / Album / ## Title.ext — deriving Album Artist,
//  guaranteeing the track/disc-number tags exist, normalising filenames, and
//  flagging anything it can't place. Pure and dependency-free so it's testable.
//

import Foundation

/// One track's facts, read from its tags (+ its current path/filename).
struct OrganiseInput {
    let rel: String            // current root-relative path
    let ext: String            // lowercased, no dot
    var artist: String
    var albumArtist: String
    var album: String
    var title: String
    var trackNo: Int           // 0 = missing
    var discNo: Int            // 0 = missing/none
    var isClassical: Bool = false
    var composer: String = ""
}

/// What Organise proposes for one track.
struct OrganisePlan: Identifiable {
    let rel: String                                   // source (also the id)
    var targetRel: String?                            // proposed destination, nil = not moved
    var flag: String?                                 // reason it wasn't placed
    var tagWrites: [(field: String, value: String)]   // tags to write so the file is self-describing
    var id: String { rel }
}

enum Organiser {

    /// Build a placement plan for a whole library. `composerFirstForClassical`
    /// switches classical tracks to a Composer-first top folder.
    static func plan(_ inputs: [OrganiseInput], composerFirstForClassical: Bool = false) -> [OrganisePlan] {
        // Group by the ARTIST FOLDER + the disc-stripped album, so the two discs of a
        // set (which live in separate "[Disc 1]"/"[Disc 2]" folders) land in ONE group
        // — that's what lets multi-disc numbering and one shared cover work — while
        // different albums (even same-named, different artist) stay apart.
        var groups: [String: [OrganiseInput]] = [:]
        for t in inputs {
            let dir = (t.rel as NSString).deletingLastPathComponent
            let parent = (dir as NSString).deletingLastPathComponent
            let key = parent + "\u{0}" + fold(stripDiscSuffix(t.album).clean)
            groups[key, default: []].append(t)
        }

        var plans: [OrganisePlan] = []
        for (_, tracks) in groups {
            // Album Artist for the whole group: an explicit album-artist tag wins;
            // else if the folder holds several different track artists it's a
            // compilation → "Various Artists"; else the single track artist.
            let taggedAA = tracks.compactMap { $0.albumArtist.isEmpty ? nil : $0.albumArtist }.first
            let distinctArtists = Set(tracks.map { fold($0.artist) }.filter { !$0.isEmpty })
            let groupAlbumArtist = taggedAA
                ?? (distinctArtists.count >= 2 ? "Various Artists"
                    : tracks.first(where: { !$0.artist.isEmpty })?.artist ?? "")
            // Multi-disc if any track carries a disc number ≥ 2 (tag or album-name).
            let multiDisc = tracks.contains { t in
                if t.discNo >= 2 { return true }
                if let d = Organiser.stripDiscSuffix(t.album).disc, d >= 2 { return true }
                return false
            }

            for t in tracks {
                plans.append(planOne(t, groupAlbumArtist: groupAlbumArtist,
                                     multiDisc: multiDisc,
                                     composerFirst: composerFirstForClassical))
            }
        }
        return plans.sorted { $0.rel < $1.rel }
    }

    private static func planOne(_ t: OrganiseInput, groupAlbumArtist: String,
                                multiDisc: Bool, composerFirst: Bool) -> OrganisePlan {
        var writes: [(String, String)] = []

        // Can't place a file with no album or no artist of any kind — flag, leave put.
        let albumArtist = t.albumArtist.isEmpty ? groupAlbumArtist : t.albumArtist
        if t.album.isEmpty || (albumArtist.isEmpty && t.artist.isEmpty) {
            return OrganisePlan(rel: t.rel, targetRel: nil,
                                flag: "missing \(t.album.isEmpty ? "album" : "artist") tag",
                                tagWrites: [])
        }
        // Write the album-artist tag if we derived one the file didn't carry.
        if t.albumArtist.isEmpty && !albumArtist.isEmpty {
            writes.append(("albumartist", albumArtist))
        }

        // Collapse a multi-disc set into ONE album: strip a "[Disc 2]" suffix from
        // the album name (the disc belongs in the disc tag, which we also fill). So
        // both discs share a folder and the same cover, per the standard.
        let (cleanAlbum, discFromName) = Organiser.stripDiscSuffix(t.album)
        if cleanAlbum != t.album { writes.append(("album", cleanAlbum)) }
        let discNo = t.discNo > 0 ? t.discNo : (discFromName ?? 0)
        if t.discNo == 0, let d = discFromName { writes.append(("disc", String(d))) }

        // Track number: prefer the tag, else the leading number in the filename.
        var trackNo = t.trackNo
        if trackNo == 0, let n = leadingNumber(t.rel) { trackNo = n }
        if t.trackNo == 0 && trackNo > 0 { writes.append(("track", String(trackNo))) }   // guarantee the tag

        // Top folder: Composer-first only for classical when the toggle is on.
        let top = (composerFirst && t.isClassical && !t.composer.isEmpty) ? t.composer : albumArtist
        let folder = safe(top) + "/" + safe(cleanAlbum)

        // Filename: gold-standard "## Title" (multi-disc "1-02 Title"); no prefix
        // only if we genuinely couldn't find a number.
        let prefix: String
        if trackNo > 0 {
            prefix = (multiDisc && discNo > 0) ? "\(discNo)-\(pad2(trackNo))" : pad2(trackNo)
        } else {
            prefix = ""
        }
        let titleSafe = safe(t.title.isEmpty ? (t.rel as NSString).lastPathComponent : t.title)
        let filename = prefix.isEmpty ? "\(titleSafe).\(t.ext)" : "\(prefix) \(titleSafe).\(t.ext)"

        return OrganisePlan(rel: t.rel, targetRel: folder + "/" + filename, flag: nil, tagWrites: writes)
    }

    // MARK: helpers

    static func pad2(_ n: Int) -> String { n < 100 ? String(format: "%02d", n) : String(n) }

    /// Strip a trailing disc marker from an album title — "[Disc 2]", "(CD 2)",
    /// ", Disc 2", " - Disc 2", "Disc 2" — returning the clean title and the disc
    /// number if one was embedded. Multi-disc sets then collapse to one album.
    static func stripDiscSuffix(_ album: String) -> (clean: String, disc: Int?) {
        let patterns = [
            #"\s*[\[(]\s*(?:disc|cd)\s*(\d+)\s*[\])]\s*$"#,   // [Disc 2] (CD 2)
            #"\s*[-,]\s*(?:disc|cd)\s*(\d+)\s*$"#,            // , Disc 2  - CD 2
            #"\s+(?:disc|cd)\s*(\d+)\s*$"#                    // Disc 2
        ]
        for p in patterns {
            if let m = album.range(of: p, options: [.regularExpression, .caseInsensitive]) {
                let clean = String(album[..<m.lowerBound]).trimmingCharacters(in: .whitespaces)
                let digits = album[m].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                if !clean.isEmpty { return (clean, Int(digits)) }
            }
        }
        return (album, nil)
    }

    static func fold(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// Leading track number from a filename like "02 Keep The Faith" or "1-05 …".
    static func leadingNumber(_ rel: String) -> Int? {
        let name = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
        // strip a leading "disc-" so "1-05" yields 5, not 1
        let afterDisc = name.range(of: #"^\d+-(\d+)"#, options: .regularExpression) != nil
            ? name.replacingOccurrences(of: #"^\d+-"#, with: "", options: .regularExpression)
            : name
        let digits = afterDisc.prefix(while: { $0.isNumber })
        guard let n = Int(digits), n > 0 else { return nil }
        return n
    }

    /// Filesystem-safe path component: replace the characters that are illegal or
    /// confusing on macOS/SMB, collapse whitespace, trim trailing dots/spaces.
    static func safe(_ s: String) -> String {
        var out = s
        for (bad, good) in [("/", "-"), (":", "-"), ("\\", "-"), ("\n", " "), ("\r", " "), ("\t", " ")] {
            out = out.replacingOccurrences(of: bad, with: good)
        }
        // control chars
        out = out.components(separatedBy: CharacterSet.controlCharacters).joined()
        // collapse runs of whitespace
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        out = out.trimmingCharacters(in: .whitespaces)
        // no trailing dots/spaces (Windows/SMB choke) and never empty
        while out.hasSuffix(".") || out.hasSuffix(" ") { out.removeLast() }
        return out.isEmpty ? "Unknown" : out
    }
}
