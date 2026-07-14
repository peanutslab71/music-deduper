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
                     renumber: Bool = false, compilations: Set<String> = [],
                     mergeAlbums: Set<String> = []) -> [OrganisePlan] {
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
                let canon = canonicalAlbumKey(t.album)
                // A confirmed edition-merge folds "X", "X [Sony]", "X (Remastered)" into one
                // group so their tracks share a folder and gaps get filled from each other.
                if mergeAlbums.contains(canon) {
                    key = parent + "\u{0}#M#\u{0}" + canon
                } else {
                    key = parent + "\u{0}" + album
                }
            }
            groups[key, default: []].append(t)
        }

        // Album-artist consensus: tally the album-artist across every track of each
        // album (edition-folded), library-wide, so a track whose album-artist is a
        // collaboration/superset of the album's dominant one ("Benny Goodman & Martha
        // Tilton" on an otherwise "Benny Goodman" album) can be filed under — and
        // retagged to — the dominant, instead of splitting into its own folder.
        var aaByAlbum: [String: [String: Int]] = [:]
        for t in inputs {
            guard !albumOrEmpty(t.album).isEmpty, !t.albumArtist.isEmpty else { continue }
            aaByAlbum[canonicalAlbumKey(t.album), default: [:]][t.albumArtist, default: 0] += 1
        }
        func dominantAA(_ canon: String) -> String? {
            aaByAlbum[canon]?.max(by: { ($0.value, $1.key.count) < ($1.value, $0.key.count) })?.key
        }
        // two album-artists are the "same core artist" when their primary name matches
        // ("Benny Goodman & Martha Tilton" → "Benny Goodman") or one prefixes the other.
        func relatedAA(_ a: String, _ b: String) -> Bool {
            let pa = fold(primaryArtist(a)), pb = fold(primaryArtist(b))
            guard !pa.isEmpty, !pb.isEmpty else { return false }
            return pa == pb || fold(a).hasPrefix(pb) || fold(b).hasPrefix(pa)
        }

        var plans: [OrganisePlan] = []
        for (key, tracks) in groups {
            let isCompGroup = key.hasPrefix("\u{0}VA\u{0}")
            let isMergeGroup = key.contains("\u{0}#M#\u{0}")
            // Album Artist for the whole group: a compilation is "Various Artists";
            // else the group's own dominant — unless the album has a library-wide
            // dominant album-artist this group is merely a collaboration of, in which
            // case adopt that (keeps a guest-credited track with the rest of the album).
            let derivedAA = deriveAlbumArtist(tracks)
            let canonAA = canonicalAlbumKey(tracks.first?.album ?? "")
            var groupAlbumArtist = isCompGroup ? "Various Artists" : derivedAA
            if !isCompGroup, let dom = dominantAA(canonAA), dom != derivedAA, relatedAA(derivedAA, dom) {
                groupAlbumArtist = dom
            }
            // Canonical album name for the whole group. A merge group uses the cleanest
            // edition-stripped name ("The Very Best Of Curtis Mayfield", not "…[Castle]");
            // otherwise the most common disc-stripped title (so casing/format agree).
            let albumNames = tracks.map { albumOrEmpty($0.album) }.filter { !$0.isEmpty }
            let groupAlbum = isMergeGroup
                ? canonicalAlbumDisplay(albumNames)
                : (Dictionary(grouping: albumNames, by: { fold($0) })
                    .max(by: { $0.value.count < $1.value.count })?.value.first ?? (albumNames.first ?? ""))
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

    /// Remove edition/label/format markers from an album name so different pressings
    /// of the SAME album collapse together: "Legends [Sony]" → "Legends",
    /// "The Very Best of Curtis Mayfield [Castle]" → "The Very Best of Curtis Mayfield",
    /// "Rumours (Remastered 2013)" → "Rumours". Song qualifiers in parens that are NOT
    /// edition words (e.g. "(Live)", "(Acoustic)") are LEFT ALONE — they mark a genuinely
    /// different album. Square-bracket groups are always metadata and always stripped.
    static func stripEditionMarkers(_ s: String) -> String {
        var t = s
        // [Castle] [Sony] [Remastered] [Disc 2] … — square brackets are never part of a title
        t = t.replacingOccurrences(of: #"\s*\[[^\]]*\]"#, with: "", options: .regularExpression)
        // (Remastered 2013) (Deluxe Edition) (Mono) … — parens ONLY when an edition word is inside
        let kw = "remaster(?:ed)?|deluxe|expanded|anniversary|mono|stereo|bonus|reissue|collector'?s?|" +
                 "special edition|digital remaster|original recording|explicit|clean version"
        t = t.replacingOccurrences(of: "\\s*\\([^)]*\\b(?:\(kw))\\b[^)]*\\)", with: "",
                                   options: [.regularExpression, .caseInsensitive])
        // trailing " - Remastered 2009" / " – Deluxe" with no brackets
        t = t.replacingOccurrences(of: "\\s*[-–—]\\s*(?:\\d{4}\\s+)?(?:\(kw))(?:\\s+\\d{4})?\\s*$", with: "",
                                   options: [.regularExpression, .caseInsensitive])
        return t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
    }

    /// The canonical identity of an album for merging/deduping: album name with disc
    /// suffix + edition markers removed, then punctuation/case/leading-article folded.
    /// Two folders with the same key are the same album, wherever their files live.
    static func canonicalAlbumKey(_ album: String) -> String {
        let core = stripEditionMarkers(stripDiscSuffix(album).clean)
        var k = core.lowercased()
        k = k.replacingOccurrences(of: #"[’‘`]"#, with: "'", options: .regularExpression)
        k = k.replacingOccurrences(of: "&", with: "and")
        k = k.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        k = k.replacingOccurrences(of: #"\b(the|a|an)\b"#, with: " ", options: .regularExpression)
        return k.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
    }

    /// Detected album-merge groups: one canonical album whose files carry ≥2 genuinely
    /// different raw names (an edition suffix or a stray copy), under one artist folder.
    /// These are surfaced in Organise for the user to confirm before folding together.
    struct MergeGroup: Identifiable { let key: String; let display: String; let rawNames: [String]; let artist: String; let count: Int
        var id: String { artist + "\u{0}" + key } }
    static func albumMergeCandidates(_ inputs: [OrganiseInput]) -> [MergeGroup] {
        struct Acc { var origNames: [String] = []; var foldedDistinct = Set<String>(); var artist = ""; var count = 0 }
        var by: [String: Acc] = [:]
        for t in inputs {
            let a = albumOrEmpty(t.album)
            guard !a.isEmpty else { continue }
            let parent = ((t.rel as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            let key = parent + "\u{0}" + canonicalAlbumKey(t.album)
            var acc = by[key] ?? Acc()
            // count distinct names only after the disc suffix is removed, so multi-disc
            // "[Disc 1]"/"[Disc 2]" folders don't look like different albums.
            acc.foldedDistinct.insert(fold(stripDiscSuffix(a).clean))
            acc.origNames.append(a)
            acc.count += 1
            if acc.artist.isEmpty { acc.artist = deriveAlbumArtist([t]) }
            by[key] = acc
        }
        return by.compactMap { (key, acc) -> MergeGroup? in
            guard acc.foldedDistinct.count >= 2 else { return nil }
            let canon = String(key.split(separator: "\u{0}").last ?? "")
            let names = Array(Set(acc.origNames)).sorted()
            return MergeGroup(key: canon, display: canonicalAlbumDisplay(acc.origNames),
                              rawNames: names, artist: acc.artist, count: acc.count)
        }.sorted { $0.display < $1.display }
    }

    /// The cleanest display name to give a merged album: the disc/edition-stripped form
    /// of its most common raw name (ties → the shortest, which usually has least junk).
    static func canonicalAlbumDisplay(_ names: [String]) -> String {
        let cleaned = names.map { stripEditionMarkers(stripDiscSuffix($0).clean) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return names.first ?? "" }
        let counts = Dictionary(grouping: cleaned, by: { $0 }).mapValues { $0.count }
        return counts.max(by: { ($0.value, $1.key.count) < ($1.value, $0.key.count) })?.key ?? cleaned[0]
    }

    /// Leading track number from a filename like "02 Keep The Faith" or "1-05 …".
    static func leadingNumber(_ rel: String) -> Int? {
        let name = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
        // strip a leading "disc-" so "1-05" yields 5, not 1
        let afterDisc = name.range(of: #"^\d+-(\d+)"#, options: .regularExpression) != nil
            ? name.replacingOccurrences(of: #"^\d+-"#, with: "", options: .regularExpression)
            : name
        let digits = afterDisc.prefix(while: { $0.isNumber })
        // A track number is 1–3 digits. A 4+-digit leading run is a year or catalogue
        // number ("1999 - Song", "2001 A Space Odyssey"), NOT a track — don't invent a
        // track tag from it. Also require a separator after it so "1999Song" isn't split.
        guard digits.count <= 3, let n = Int(digits), n > 0, n <= 199 else { return nil }
        let after = afterDisc.dropFirst(digits.count).first
        guard after == nil || after == " " || after == "." || after == "-" || after == "_" || after == ")" else { return nil }
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
