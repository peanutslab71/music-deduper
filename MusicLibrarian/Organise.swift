//
//  Organise.swift
//  MusicLibrarian
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
    var isCompilation: Bool = false   // TCMP/cpil flag set → file under Various Artists
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
    static func plan(_ inputs: [OrganiseInput], composerFirstForClassical: Bool = false,
                     renumber: Bool = false, compilations: Set<String> = []) -> [OrganisePlan] {
        // A track belongs to a compilation if it carries the compilation flag OR its
        // album was confirmed as one. Compilations group GLOBALLY by album (all the
        // various-artist tracks scattered under different artist folders come back
        // together under "Various Artists / <Album>").
        func isCompilation(_ t: OrganiseInput) -> Bool {
            t.isCompilation || compilations.contains(fold(stripDiscSuffix(t.album).clean))
        }
        // Group by the ARTIST FOLDER + the disc-stripped album, so the two discs of a
        // set (which live in separate "[Disc 1]"/"[Disc 2]" folders) land in ONE group
        // — while different albums (even same-named, different artist) stay apart.
        var groups: [String: [OrganiseInput]] = [:]
        for t in inputs {
            let album = fold(stripDiscSuffix(t.album).clean)
            let key: String
            if isCompilation(t) && !albumOrEmpty(t.album).isEmpty {
                key = "\u{0}VA\u{0}" + album            // one group per compilation album, across folders
            } else {
                let parent = ((t.rel as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
                key = parent + "\u{0}" + album
            }
            groups[key, default: []].append(t)
        }

        var plans: [OrganisePlan] = []
        for (key, tracks) in groups {
            let isCompGroup = key.hasPrefix("\u{0}VA\u{0}")
            // Album Artist for the whole group: a compilation is "Various Artists";
            // else an explicit album-artist tag wins; else the dominant/only artist.
            let groupAlbumArtist = isCompGroup ? "Various Artists" : deriveAlbumArtist(tracks)
            // Canonical album name for the whole group (most common disc-stripped title)
            // so every disc/track of one album shares a folder even if casing differs.
            let albumNames = tracks.map { albumOrEmpty($0.album) }.filter { !$0.isEmpty }
            let groupAlbum = Dictionary(grouping: albumNames, by: { fold($0) })
                .max(by: { $0.value.count < $1.value.count })?.value.first ?? (albumNames.first ?? "")
            // Multi-disc if any track carries a disc number ≥ 2 (tag or album-name).
            let multiDisc = tracks.contains { t in
                if t.discNo >= 2 { return true }
                if let d = Organiser.stripDiscSuffix(t.album).disc, d >= 2 { return true }
                return false
            }

            // Renumber: within each disc, assign a clean sequential 1…N by the tracks'
            // current order (existing number → leading filename number → name). Preview
            // shows the result before it's applied, and it's reversible.
            var forced: [String: Int] = [:]
            if renumber {
                var byDisc: [Int: [OrganiseInput]] = [:]
                for t in tracks { byDisc[effectiveDisc(t), default: []].append(t) }
                for (_, discTracks) in byDisc {
                    let sorted = discTracks.sorted { orderKey($0) < orderKey($1) }
                    for (i, t) in sorted.enumerated() { forced[t.rel] = i + 1 }
                }
            }

            for t in tracks {
                plans.append(planOne(t, groupAlbumArtist: groupAlbumArtist, groupAlbum: groupAlbum,
                                     multiDisc: multiDisc,
                                     composerFirst: composerFirstForClassical,
                                     forcedTrackNo: forced[t.rel]))
            }
        }
        return plans.sorted { $0.rel < $1.rel }
    }

    /// The primary artist of a possibly-collaborative credit ("Queen & David Bowie"
    /// → "Queen"), so a comp of mostly one artist isn't fooled by a few guest tracks.
    static func primaryArtist(_ s: String) -> String {
        var t = s
        for sep in [" & ", " feat. ", " feat ", " featuring ", " with ", " / ", " vs ", " vs. ", " x "] {
            if let r = t.range(of: sep, options: .caseInsensitive) { t = String(t[..<r.lowerBound]); break }
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Placeholder album tags that must NOT become a real folder ("Unknown Album",
    /// "various", "track 03", blank). Treated as no-album so the file is flagged and
    /// left where it is, rather than moved into a literal "Unknown Album" folder.
    static func isPlaceholderAlbum(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { return true }
        if t == "unknown" || t.hasPrefix("unknown ") || t.contains("unknown album")
            || t == "various" || t == "various artists" { return true }
        if t.range(of: "^track ?0*\\d+$", options: .regularExpression) != nil { return true }
        return false
    }
    /// The disc-stripped album to place under, or "" if it's a placeholder.
    static func albumOrEmpty(_ raw: String) -> String {
        let cleaned = stripDiscSuffix(raw).clean
        return isPlaceholderAlbum(cleaned) ? "" : cleaned
    }

    /// Album artist for a group: a single consistent (non-"Various Artists") tag wins;
    /// else if one artist clearly dominates the track credits use them (so a Bowie
    /// best-of with a stray "Various Artists" tag files under David Bowie); else a
    /// present tag; else Various when the artists are genuinely mixed.
    static func deriveAlbumArtist(_ tracks: [OrganiseInput]) -> String {
        let aaTags = tracks.compactMap { $0.albumArtist.isEmpty ? nil : $0.albumArtist }
        let aaFolded = Set(aaTags.map { fold($0) })
        if aaFolded.count == 1, let aa = aaTags.first, fold(aa) != "various artists" { return aa }

        let primaries = tracks.map { primaryArtist($0.artist) }.filter { !$0.isEmpty }
        let counts = Dictionary(grouping: primaries, by: { fold($0) }).mapValues { $0.count }
        if let dom = counts.max(by: { $0.value < $1.value }),
           Double(dom.value) / Double(max(1, primaries.count)) >= 0.6,
           let name = primaries.first(where: { fold($0) == dom.key }) {
            return name
        }
        if let aa = aaTags.first { return aa }
        let distinct = Set(tracks.map { fold($0.artist) }.filter { !$0.isEmpty })
        return distinct.count >= 2 ? "Various Artists" : (tracks.first(where: { !$0.artist.isEmpty })?.artist ?? "")
    }

    /// The disc a track belongs to (tag → album-name suffix → 1).
    private static func effectiveDisc(_ t: OrganiseInput) -> Int {
        if t.discNo > 0 { return t.discNo }
        if let d = stripDiscSuffix(t.album).disc { return d }
        return 1
    }
    /// Sort key for renumbering: numbered tracks first in number order, then by name.
    private static func orderKey(_ t: OrganiseInput) -> (Int, String) {
        let n = t.trackNo > 0 ? t.trackNo : (leadingNumber(t.rel) ?? Int.max)
        return (n, (t.rel as NSString).lastPathComponent.lowercased())
    }

    private static func planOne(_ t: OrganiseInput, groupAlbumArtist: String, groupAlbum: String,
                                multiDisc: Bool, composerFirst: Bool,
                                forcedTrackNo: Int? = nil) -> OrganisePlan {
        var writes: [(String, String)] = []

        // Use the GROUP's album artist + album name for every track, so all discs/tracks
        // of one album agree (a stray "Various Artists" on one disc no longer splits it).
        let albumArtist = groupAlbumArtist.isEmpty ? t.albumArtist : groupAlbumArtist
        let cleanAlbum = groupAlbum.isEmpty ? Organiser.albumOrEmpty(t.album) : groupAlbum
        // Can't place a file with no album or no artist of any kind — flag, leave put.
        if cleanAlbum.isEmpty || (albumArtist.isEmpty && t.artist.isEmpty) {
            return OrganisePlan(rel: t.rel, targetRel: nil,
                                flag: "missing \(cleanAlbum.isEmpty ? "album" : "artist") tag",
                                tagWrites: [])
        }
        // Write the album-artist / album tags where the file's differ from the group's.
        if !albumArtist.isEmpty && albumArtist != t.albumArtist { writes.append(("albumartist", albumArtist)) }
        if cleanAlbum != t.album { writes.append(("album", cleanAlbum)) }

        // Multi-disc: fill the disc-number tag if it was only in the album name.
        let discFromName = Organiser.stripDiscSuffix(t.album).disc
        let discNo = t.discNo > 0 ? t.discNo : (discFromName ?? 0)
        if t.discNo == 0, let d = discFromName { writes.append(("disc", String(d))) }

        // Track number: a forced (renumber) value wins; else the tag; else the leading
        // number in the filename. Write the tag whenever the final number differs from
        // what's on the file (guarantees the tag AND applies a renumber).
        var trackNo = t.trackNo
        if trackNo == 0, let n = leadingNumber(t.rel) { trackNo = n }
        if let forced = forcedTrackNo { trackNo = forced }
        if trackNo > 0 && trackNo != t.trackNo { writes.append(("track", String(trackNo))) }

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
        // Edition/format markers — strip them but they carry NO disc number for the
        // track (the SET size, e.g. "[2-CD]", is not "this is disc 2").
        let editionPatterns = [
            #"\s*[\[(]\s*\d+\s*[- ]?\s*cd(?:\s+set)?\s*[\])]\s*$"#,   // [2-CD]  (2 CD Set)
        ]
        for p in editionPatterns {
            if let m = album.range(of: p, options: [.regularExpression, .caseInsensitive]) {
                let clean = String(album[..<m.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !clean.isEmpty { return (clean, nil) }
            }
        }
        let patterns = [
            #"\s*[\[(]\s*(?:disc|cd)\s*\d+\s*[\])]\s*$"#,        // [Disc 2] (CD 2)
            #"\s*[-,]\s*(?:disc|cd)\s*\d+\s*$"#,                 // , Disc 2  - CD 2
            #"\s+(?:disc|cd)\s*\d+(?:\s+of\s+\d+)?\s*$"#         // Disc 2   |   Disc 6 of 8
        ]
        for p in patterns {
            if let m = album.range(of: p, options: [.regularExpression, .caseInsensitive]) {
                let clean = String(album[..<m.lowerBound]).trimmingCharacters(in: .whitespaces)
                // the FIRST number in the match is the disc number ("Disc 6 of 8" → 6)
                let matchStr = String(album[m])
                let disc = matchStr.range(of: #"\d+"#, options: .regularExpression).flatMap { Int(matchStr[$0]) }
                if !clean.isEmpty { return (clean, disc) }
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
