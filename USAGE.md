# Using Music Deduper

A walkthrough of the whole workflow, from first scan to a clean library. The app is
a four-step wizard — **Source → Review → Clean up → Copy** — with the step bar across
the top. Steps unlock once a scan has run, and you can hop back to any completed step.

One piece of advice before anything else: **have a backup of your library before you
delete anything.** The app is careful — keepers are never touched, deletes default to
the Trash and are confirmed twice — but it's your music. Belt and braces.

And the formal bit: this software is provided free, **as is, with no warranty of any
kind, express or implied** — use it at your own risk. No liability is accepted for
data loss or any other damage arising from its use. Full terms in the LICENSE file (MIT).

## 1. Source — scan your library

Drop your music folder onto the window (or **Browse…**). Recent folders are remembered
as one-click links. The app walks the whole tree, reading the real tags and durations
from each file (via AVFoundation), then works out which tracks are copies of each
other. Big libraries take a few minutes on the first pass because the app also
fingerprints file contents.

The **Matching options** disclosure (match mode, duration tolerance, across-albums)
lives on this screen — change them and **Rescan** (top-right of the Review step).

When the scan finishes you land on the right screen automatically: **Duplicates** if
any were found, otherwise straight to the **Library** — an album-artwork grid of
everything it found (covers come from your files' own tags; click an album for its
track list).

## 2. Understand what it matched

Every duplicate group shows a reason:

- **"identical bytes"** — the files have the same content fingerprint (a checksum of
  the head and tail of the file plus its size). These are true copies, whatever their
  filenames say.
- **"same title/artist/length"** — the tags match and the durations are within the
  tolerance. This catches the same recording in different formats — an MP3 next to
  its FLAC replacement, for example.

Three controls under **Matching options** (on the Source step) tune the matching:

- **Match mode**
  - **Strict** — content fingerprints only. Every file is fingerprinted and only
    byte-identical copies are grouped. Zero false positives; misses re-encodes.
  - **Balanced** (default) — fingerprint matches plus tag/duration matches within
    the same album (or same filename). The sensible middle ground.
  - **Aggressive** — looser text matching (punctuation and case ignored), matches
    across albums, and tolerates missing durations. Finds the most, worth a more
    careful review.
- **± seconds** — how close two durations must be to count as the same recording.
- **across albums** — allow tag matches to pair tracks from different albums (e.g.
  an album track vs the same song on a compilation). Off by default; think before
  turning it on — a studio track and a best-of version may genuinely both be wanted.

If you change any of these, hit **Rescan** (top-right of the Review step) to regroup.

## 3. Review the groups

The **Duplicates** tab lists each group with its album artwork: artist and title, how
many copies, why they matched, and how much space deleting the extras saves.

Inside a group, every file shows its format, duration, size and full path. One row is
marked **KEEP** — the app's pick for the best copy. The choice is a quality ranking:

1. **Lossless beats lossy**, always (FLAC/ALAC/PCM over MP3/AAC).
2. Then **higher bitrate**.
3. Then completeness of tags (album artist, album, track number present) as a
   tie-breaker.

**Click any other row to make it the keeper instead.** Do this wherever you know
better than the ranking — say the "worse" file is the properly tagged one.

The **Library** tab is an album-artwork grid of everything the scan found — click any
album for its track listing. Useful for sanity-checking what's actually in the folder.

## 4. Clean up — delete the duplicates

The Clean up step shows the totals (groups, files to remove, space reclaimed).
Click **Delete duplicates…** and pick:

- **Move to Trash (recoverable)** — the sane default. You can pull anything back out.
- **Permanently delete** — no recycle bin, gone. Use once you trust the results.

Either way you confirm twice, and the dialog tells you exactly how many files will go
and how much space comes back. Keepers are never deleted — the operation only ever
removes the non-KEEP rows of each group.

A progress sheet shows ✓ done, • skipped and ✗ failed counts as it runs.

## 5. Copy keepers to a clean tree (optional)

The Copy step takes the best copy of every track and writes a tidy
`Artist/Album/track` folder structure at a destination of your choice. Your source
library isn't touched — this builds a clean copy alongside it. It's an explicit
three-part sequence on one screen:

1. **Where is your Roon server (or NAS)?** — browse to the share (Network → your
   server → its music share). Picking it also captures the share's `smb://` address
   for automatic reconnects (see below).
2. **Which folder inside it?** — where the Artist/Album tree gets created.
3. **Copy.**

This is the step I built for feeding a Roon server: point it at the share and let
it run.

**If you're copying to a Roon ROCK server, Roon Server must be stopped first.** Roon
watches its music folder live, and a large copy landing while the server is running
can cause it to stop or hang.

From v1.1 the app enforces this itself: when you pick a copy destination it checks
whether that machine is a ROCK with Roon Server running (using the same local API as
the ROCK's own settings page). If it is, the copy will not start — you'll be offered
**Stop Roon Server, then copy** (the app stops it, waits for confirmation, then runs
the copy) or **Cancel**. There is deliberately no "copy anyway". When the copy
finishes, the app offers to **start Roon Server again** so it imports all the new
files in one clean pass.

**Copying a big library over several runs?** Say **No** to that restart offer
until the *last* run is done. Every restart sends Roon off to import the fresh
files immediately, and on a small NUC that can peg the CPU so hard the machine
drops off the network — which then wrecks your next copy run and looks exactly
like a network fault. Details and the Roon settings that prevent it are in
[HELP.md](HELP.md).

Two other behaviours worth knowing:

- **Files that already exist ask first.** If a file is already at the destination —
  identical or different — the copy pauses and shows a conflict panel:
  **Overwrite / Overwrite All / Skip / Skip All**. Step file-by-file, or hit an
  "All" button once and the rest runs unattended. (Topping up a destination =
  first prompt → **Skip All**; refreshing everything = **Overwrite All**.)
  Nothing is skipped or overwritten silently.
- **Network drops don't kill the run.** Long copies to a network share are exactly
  where connections wobble; the app retries each file until it succeeds rather than
  skipping, and re-mounts the share itself using the address captured in part 1
  (as **guest** — ROCK's Data share allows that out of the box). The address is
  remembered between launches.

## Suggested first run

1. Back up (or at least know you have last night's backup).
2. Scan in **Balanced** mode, leave *across albums* off.
3. Review the groups — spot-check that KEEP is landing on the copies you'd choose.
4. Delete to **Trash**, not permanently.
5. Play a few of the survivors, empty the Trash when you're satisfied.
6. Then, if you want more aggressive cleanup, try **Aggressive** mode and review with
   more care.
