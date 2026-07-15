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
