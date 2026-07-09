# Using Music Deduper

A walkthrough of the whole workflow, from first scan to a clean library.

One piece of advice before anything else: **have a backup of your library before you
delete anything.** The app is careful — keepers are never touched, deletes default to
the Trash and are confirmed twice — but it's your music. Belt and braces.

And the formal bit: this software is provided free, **as is, with no warranty of any
kind, express or implied** — use it at your own risk. No liability is accepted for
data loss or any other damage arising from its use. Full terms in the LICENSE file (MIT).

## 1. Scan your library

Click **Pick source folder** and choose the top of your music library. The app walks
the whole tree, reading the real tags and durations from each file (via AVFoundation),
and then works out which tracks are copies of each other. The status bar at the bottom
shows progress; big libraries take a few minutes on the first pass because the app also
fingerprints file contents.

**Rescan** repeats the scan on the same folder — use it after you've made changes.

## 2. Understand what it matched

Every duplicate group shows a reason:

- **"identical bytes"** — the files have the same content fingerprint (a checksum of
  the head and tail of the file plus its size). These are true copies, whatever their
  filenames say.
- **"same title/artist/length"** — the tags match and the durations are within the
  tolerance. This catches the same recording in different formats — an MP3 next to
  its FLAC replacement, for example.

Three controls in the toolbar tune the matching:

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

If you change any of these, hit **Rescan** to regroup.

## 3. Review the groups

The **Duplicates** tab lists each group: artist and title, how many copies, why they
matched, and how much space deleting the extras saves.

Inside a group, every file shows its format, duration, size and full path. One row is
marked **KEEP** — the app's pick for the best copy. The choice is a quality ranking:

1. **Lossless beats lossy**, always (FLAC/ALAC/PCM over MP3/AAC).
2. Then **higher bitrate**.
3. Then completeness of tags (album artist, album, track number present) as a
   tie-breaker.

**Click any other row to make it the keeper instead.** Do this wherever you know
better than the ranking — say the "worse" file is the properly tagged one.

The **Library** tab is a plain browser of everything the scan found — artist → album →
track listing — useful for sanity-checking what's actually in the folder.

## 4. Delete the duplicates

Click **Delete duplicates…** and pick:

- **Move to Trash (recoverable)** — the sane default. You can pull anything back out.
- **Permanently delete** — no recycle bin, gone. Use once you trust the results.

Either way you confirm twice, and the dialog tells you exactly how many files will go
and how much space comes back. Keepers are never deleted — the operation only ever
removes the non-KEEP rows of each group.

A progress sheet shows ✓ done, • skipped and ✗ failed counts as it runs.

## 5. Copy keepers to a clean tree (optional)

**Copy keepers to…** takes the best copy of every track and writes a tidy
`Artist/Album/track` folder structure at whatever destination you choose. Your source
library isn't touched — this builds a clean copy alongside it.

This is the step I built for feeding a Roon server: point it at the mounted network
share and let it run.

**If you're copying to a Roon ROCK server, stop the Roon Server first — from inside
Roon's web UI (the ROCK admin page) — before starting the copy.** Roon watches its
music folder live, and a large copy landing while the server is running can cause it
to stop or hang. Stop the server, run the copy, then start it again and let it import
the new files in one go.

Two other behaviours worth knowing:

- **Already-copied files are skipped** (matched by size), so you can re-run the copy
  any time to top up a destination — it only transfers what's missing.
- **Network drops don't kill the run.** Long copies to a network share are exactly
  where connections wobble; the app retries each file until it succeeds rather than
  skipping, and can re-mount the share itself — see below.

### Setting up "Reconnect target" for network copies

If your destination is an SMB share (a Roon ROCK server, a NAS), set up the
**Reconnect target (SMB guest)** row below the toolbar *before* starting a big copy:

1. Click **Connect…** — a browse dialog opens.
2. Navigate to the share under **Network** (e.g. Network → your server → **Data** for
   a ROCK) and select it.
3. The app reads the share's `smb://` remount address automatically and fills the
   field — you don't need to type it (though you can, e.g. `smb://rock/Data`).

The address is remembered between launches. With it set, if the share disconnects
mid-copy — sleep, a network blip, the server restarting — the app re-mounts it as
guest and carries on from where it was. Without it, a drop would leave the copy
stuck retrying against a vanished folder.

Connects as **guest**, so the share needs guest access enabled (ROCK's Data share
has this out of the box).

## Suggested first run

1. Back up (or at least know you have last night's backup).
2. Scan in **Balanced** mode, leave *across albums* off.
3. Review the groups — spot-check that KEEP is landing on the copies you'd choose.
4. Delete to **Trash**, not permanently.
5. Play a few of the survivors, empty the Trash when you're satisfied.
6. Then, if you want more aggressive cleanup, try **Aggressive** mode and review with
   more care.
