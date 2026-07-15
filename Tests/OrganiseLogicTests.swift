// Pure-logic regression tests for Organise.swift.
//
// Organise.swift imports only Foundation, so these run WITHOUT the full Xcode
// build (no MDTagShim / ChromaSwift / SwiftUI). Run them with Tests/run.sh, which
// compiles the app's real Organise.swift together with this file — so the tests
// exercise the shipping code, not a copy.
//
// Coverage: leadingNumber (the filename→track-number parse + the year guard that
// stops "1999 - Song.mp3" becoming track 1999), stripDiscSuffix, isPlaceholderAlbum,
// and canonicalAlbumKey (edition/disc markers folding to one key).

import Foundation

@main
enum OrganiseLogicTests {
    static var pass = 0, fail = 0
    static func check(_ label: String, _ got: String, _ want: String) {
        if got == want { pass += 1 } else { fail += 1; print("  FAIL \(label): got \(got)  want \(want)") }
    }
    static func checkI(_ label: String, _ got: Int?, _ want: Int?) {
        if got == want { pass += 1 } else { fail += 1; print("  FAIL \(label): got \(String(describing: got))  want \(String(describing: want))") }
    }
    static func b(_ x: Bool) -> String { x ? "true" : "false" }

    static func main() {
        // ---- leadingNumber: filename→track-number, with the year/catalogue guard ----
        checkI("track 05",                 Organiser.leadingNumber("05 Title.mp3"), 5)
        checkI("track 12. ",               Organiser.leadingNumber("12. Title.mp3"), 12)
        checkI("1-05 (disc prefix)",       Organiser.leadingNumber("1-05 Title.mp3"), 5)
        checkI("track 100",                Organiser.leadingNumber("100 Title.mp3"), 100)
        checkI("YEAR 1999 rejected",       Organiser.leadingNumber("1999 - Song.mp3"), nil)
        checkI("YEAR 2001 rejected",       Organiser.leadingNumber("2001 A Space Odyssey.mp3"), nil)
        checkI("no separator rejected",    Organiser.leadingNumber("05Title.mp3"), nil)
        checkI("no leading number",        Organiser.leadingNumber("Title.mp3"), nil)
        checkI("zero rejected",            Organiser.leadingNumber("00 Intro.mp3"), nil)
        checkI("3-digit >199 rejected",    Organiser.leadingNumber("500 Track.mp3"), nil)

        // ---- stripDiscSuffix ----
        check ("strip (Disc 2)",           Organiser.stripDiscSuffix("Legends (Disc 2)").clean, "Legends")
        checkI("disc number from suffix",  Organiser.stripDiscSuffix("Legends (Disc 2)").disc, 2)
        check ("keep (Live)",              Organiser.stripDiscSuffix("Album (Live)").clean, "Album (Live)")
        checkI("no disc suffix",           Organiser.stripDiscSuffix("Plain Album").disc, nil)

        // ---- isPlaceholderAlbum ----
        check("Unknown Album placeholder", b(Organiser.isPlaceholderAlbum("Unknown Album")), "true")
        check("empty placeholder",         b(Organiser.isPlaceholderAlbum("")), "true")
        check("real album not placeholder",b(Organiser.isPlaceholderAlbum("Paranoid")), "false")

        // ---- canonicalAlbumKey: edition/disc markers fold to one key ----
        check("edition markers fold equal",
              b(Organiser.canonicalAlbumKey("The Very Best of Curtis Mayfield [Castle]")
                == Organiser.canonicalAlbumKey("The Very Best of Curtis Mayfield")), "true")

        // ---- editDistanceAtMost1 (fuzzy-title core; inputs are pre-folded) ----
        check("identical",                 b(Organiser.editDistanceAtMost1("future shock", "future shock")), "true")
        check("one deletion (space)",      b(Organiser.editDistanceAtMost1("future shock", "futureshock")), "true")
        check("one substitution",          b(Organiser.editDistanceAtMost1("fingel", "finger")), "true")
        check("one insertion",             b(Organiser.editDistanceAtMost1("colour", "color")), "true")
        check("two edits rejected",        b(Organiser.editDistanceAtMost1("future shock", "futureshok")), "false")
        check("different titles rejected", b(Organiser.editDistanceAtMost1("paranoid", "iron man")), "false")
        check("length gap >1 rejected",    b(Organiser.editDistanceAtMost1("intro", "intromission")), "false")

        // ---- Normalizer (Phase 1): artist unification, junk, merges, idempotency ----
        func mk(_ rel: String, ar: String, aa: String = "", al: String, ti: String, tr: Int) -> OrganiseInput {
            OrganiseInput(rel: rel, ext: (rel as NSString).pathExtension.lowercased(),
                          artist: ar, albumArtist: aa, album: al, title: ti, trackNo: tr, discNo: 0)
        }
        let lib = Normalizer.Input(
            tracks: [
                mk("The Buzzcocks/Singles/01 Boredom.mp3",  ar: "The Buzzcocks", al: "Singles", ti: "Boredom", tr: 1),
                mk("The Buzzcocks/Singles/02 Fiction.mp3",  ar: "The Buzzcocks", al: "Singles", ti: "Fiction", tr: 2),
                mk("Buzzcocks/Another Bite/01 Promises.mp3", ar: "Buzzcocks",    al: "Another Bite", ti: "Promises", tr: 1),
            ],
            junkRels: ["The Buzzcocks/Singles/.DS_Store"],
            emptyDirRels: ["Old Empty Folder"])
        let nplan = Normalizer.plan(lib)
        checkI("one artist to unify", nplan.unifications.count, 1)
        check ("canonical = most-backed spelling", nplan.unifications.first?.canonical ?? "", "The Buzzcocks")
        check ("split spelling retagged",
               b(nplan.tagWrites.contains { $0.rel == "Buzzcocks/Another Bite/01 Promises.mp3"
                                            && $0.field == "artist" && $0.value == "The Buzzcocks" }), "true")
        check ("junk quarantined",
               b(nplan.moves.contains { $0.from == "The Buzzcocks/Singles/.DS_Store" && $0.to.isEmpty }), "true")
        check ("empty folder quarantined",
               b(nplan.moves.contains { $0.from == "Old Empty Folder" && $0.to.isEmpty }), "true")
        check ("split folder folds into canonical",
               b(nplan.moves.contains { $0.from == "Buzzcocks/Another Bite/01 Promises.mp3"
                                        && $0.to.hasPrefix("The Buzzcocks/") }), "true")
        // idempotency: applying the plan and planning again proposes nothing
        let after = Normalizer.simulate(lib, applying: nplan)
        checkI("no track dropped", after.tracks.count, 3)
        let nplan2 = Normalizer.plan(after)
        checkI("second pass: no moves", nplan2.moves.count, 0)
        checkI("second pass: no tag writes", nplan2.tagWrites.count, 0)

        // edition split is detected as a merge group, and a decline is honored
        let editions = Normalizer.Input(tracks: [
            mk("Curtis/Best Of/01 Move On Up.mp3",          ar: "Curtis", al: "Best Of", ti: "Move On Up", tr: 1),
            mk("Curtis/Best Of [Castle]/02 Superfly.mp3",   ar: "Curtis", al: "Best Of [Castle]", ti: "Superfly", tr: 2),
        ])
        let eplan = Normalizer.plan(editions)
        checkI("edition merge detected", eplan.mergeGroups.count, 1)
        let declined = Normalizer.plan(editions, declinedMerges: Set(eplan.mergeGroups.map { $0.key }))
        checkI("declined merge honored", declined.mergeGroups.count, 0)

        // ---- compilationCandidates: dominated albums and duets are NOT compilations ----
        func ct(_ n: Int, ar: String, al: String) -> OrganiseInput {
            OrganiseInput(rel: "X/\(al)/\(String(format: "%02d", n)) T\(n).mp3", ext: "mp3",
                          artist: ar, albumArtist: "", album: al, title: "T\(n)", trackNo: n, discNo: 0)
        }
        // 22 Bowie tracks + 1 duet credited "Queen & David Bowie" — a guest, not a comp
        let bowie = (1...22).map { ct($0, ar: "David Bowie", al: "Best Of Bowie") }
                  + [ct(23, ar: "Queen & David Bowie", al: "Best Of Bowie")]
        checkI("dominated album not a compilation", Normalizer.compilationCandidates(bowie).count, 0)
        // 4 genuinely different artists, one each — a real compilation
        let xmas = [ct(1, ar: "Al Green", al: "Merry Xmas!"), ct(2, ar: "Elvis Presley", al: "Merry Xmas!"),
                    ct(3, ar: "Billie Holiday", al: "Merry Xmas!"), ct(4, ar: "Dusty Springfield", al: "Merry Xmas!")]
        checkI("real compilation still flagged", Normalizer.compilationCandidates(xmas).count, 1)

        // a folder named with the SAFE rendering of the tag ("AC-DC" for "AC/DC")
        // is not a spelling variance — nothing to unify
        let acdc = Normalizer.Input(tracks: (1...4).map { n in
            OrganiseInput(rel: "AC-DC/High Voltage/0\(n) T\(n).mp3", ext: "mp3",
                          artist: "AC/DC", albumArtist: "AC/DC", album: "High Voltage",
                          title: "T\(n)", trackNo: n, discNo: 0)
        })
        checkI("safe-rendered folder not a variant", Normalizer.plan(acdc).unifications.count, 0)
        // an album already grouped under Various Artists offers nothing to confirm
        let grouped = xmas.map { t -> OrganiseInput in
            var c = t; c.albumArtist = "Various Artists"
            return c
        }
        checkI("already-VA album not re-offered", Normalizer.compilationCandidates(grouped).count, 0)

        // ---- planOne blank-title fallback: filename minus extension + number ----
        let blank = OrganiseInput(rel: "Black Sabbath/Greatest Hits/01 Paranoid.m4p", ext: "m4p",
                                  artist: "Black Sabbath", albumArtist: "Black Sabbath",
                                  album: "Greatest Hits", title: "", trackNo: 1, discNo: 0)
        let bp = Organiser.plan([blank])
        check("blank-title fallback name",
              ((bp.first?.targetRel ?? "") as NSString).lastPathComponent, "01 Paranoid.m4p")
        let yearName = OrganiseInput(rel: "Prince/B-Sides/1999 - Single Mix.mp3", ext: "mp3",
                                     artist: "Prince", albumArtist: "Prince",
                                     album: "B-Sides", title: "", trackNo: 7, discNo: 0)
        let yp = Organiser.plan([yearName])
        check("4-digit year kept in fallback",
              ((yp.first?.targetRel ?? "") as NSString).lastPathComponent, "07 1999 - Single Mix.mp3")

        // ---- looksDuplicatedMess: editions-mixed folder vs healthy shapes ----
        // Legends shape: 3 editions of the same compilation flattened together.
        let legends = (1...17).flatMap { n in ["song \(n)", "song \(n)", "song \(n)"] }
        check("mixed editions flagged",    b(Organiser.looksDuplicatedMess(foldedTitles: legends)), "true")
        // Healthy flattened 2-CD rip: dup (disc,track) KEYS but unique titles.
        let flattened = (1...20).map { "track title \($0)" }
        check("flattened rip not flagged", b(Organiser.looksDuplicatedMess(foldedTitles: flattened)), "false")
        // A reprise or two is normal, not a mess.
        let reprise = (1...10).map { "song \($0)" } + ["song 1", "song 2"]
        check("reprises not flagged",      b(Organiser.looksDuplicatedMess(foldedTitles: reprise)), "false")
        // Tiny folders never gate.
        check("small folder not flagged",  b(Organiser.looksDuplicatedMess(foldedTitles: ["a","a","a","a"])), "false")

        print("\nOrganise pure-logic tests: \(pass) passed, \(fail) failed")
        exit(fail == 0 ? 0 : 1)
    }
}
