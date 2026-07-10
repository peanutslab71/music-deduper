# Perfect — Library Restoration for Music Deduper

*Design plan. Research complete; not yet implemented.*

Perfect is a planned capability of Music Deduper that takes a disorganised music
library and turns it into a clean, consistently-tagged library any modern music
server can ingest correctly — with a before/after review the user approves
before anything is written, and full undo.

---

## 0. Guiding principle: general-purpose, discovered at runtime

Perfect must work on any library. Every problem it fixes is **discovered at
runtime** by scanning and analysing the actual files — never from a baked-in
list of specific artists, albums, or fixes.

- No hardcoded artist/album/track names. Examples in this document (e.g. "AC/DC",
  "The" prefixes) are *illustrations of general classes of problem*, not entries
  in any table.
- Rules are **configurable and adaptive**: the user selects the target
  conventions (how to handle a leading "The", `&` vs `and`, folder layout, which
  server they feed), and Perfect applies them consistently.
- It must cope with libraries of any size, genre mix (rock, classical, jazz,
  electronic, spoken word), source (ripped CDs, store downloads, mixed
  provenance), prior-tagger quirks, and any character set or language in tags.
- It targets **any modern music server that reads embedded tags** — Roon, Plex,
  Jellyfin, Navidrome, Emby, Airsonic. Roon is simply the strictest consumer,
  which makes it the toughest test.

If a design choice only makes sense for one specific library, it is wrong.

---

## 1. What Perfect is

- **Local-first**: runs on the user's machine against the *local* library
  *before* it is copied to a server. Faster (local disk, not SMB), safer, and it
  means the server only ever receives clean files — fix problems at source. It
  is the front of a pipeline whose back end already exists:
  **scan → dedupe → Perfect → copy clean to the server.**
- **Review-gated and non-destructive**: nothing is written until the user
  approves; every change is reversible.
- Part of the existing open-source app; not a separate product.

---

## 2. Core insight

Music servers organise by the **embedded tags inside each file** (artist, album,
albumartist, title, track/disc number, etc.), *not* by folder and file names.

- The real fix for split/duplicate artists and inconsistent naming is therefore
  **writing corrected tags** — renaming folders alone changes nothing the server
  sees. The app today only *reads* tags (via AVFoundation); **writing** tags
  (ID3v2 for MP3, MP4 atoms for M4A/AAC/ALAC, Vorbis comments for FLAC/OGG) is
  the central new capability Perfect requires.
- Servers such as Roon do not write user files — they overlay their own
  database. Clean files on disk are therefore complementary to such servers
  (they raise identification hit-rate). File/folder hygiene is work those servers
  leave to the user, and the app's existing File Commander engine already
  performs the moving/renaming/deleting.

Two layers, both in scope, kept distinct in the UI:
1. **Storage hygiene** — folders, empties, junk, illegal-char names, duplicate
   folders. (Engine exists.)
2. **Tag correctness** — what the server actually reads. (New: tag writing +
   identification.)

---

## 3. Problem taxonomy (general classes, discovered at runtime)

Perfect detects and offers to fix these *classes* of problem. Parenthetical
items are illustrative, not a fixed list.

**A. Junk / cruft**
- OS metadata litter: `.DS_Store`, AppleDouble `._*`, `Thumbs.db`, `desktop.ini`.
- Orphaned temp files from interrupted operations: editor swap files,
  `.smbdelete*` markers, partial/zero-byte files.
- Stray non-music files misfiled among music (loose images, video, text).

**B. Structural**
- Empty folders (no audio anywhere inside).
- Illegal / sanitised filesystem characters, where a real character was replaced
  by `_` or stripped (`/ ? : * " < > |`). These are unavoidable at the
  filesystem level, so Perfect proposes a legible substitution (e.g. `AC-DC`)
  and, more importantly, corrects the *tag* to the true value (`AC/DC`).
- Inconsistent depth / not one-album-per-folder; disc-number vs subfolder
  mismatch; "Unknown Album" / "Unknown Artist" buckets of untagged files.

**C. Naming inconsistency (the "duplicate artist" problem)**
- Leading "The" variance (present vs absent vs "Name, The").
- `&` vs `and`, and other join-phrase variance.
- Multi-artist separator variance (`;` `/` `,` `feat.` `ft` `featuring`).
- Duplicated strings, casing/whitespace/diacritic variance, mojibake
  (U+FFFD replacement chars), trailing punctuation.
- Surfaced as **groups of variants** the user reviews and merges to one canonical
  form — driven by a chosen policy plus an authority (§5), never by silent regex.

**D. Tag correctness / completeness**
- Missing/blank artist, album, albumartist, title, track/disc number, year,
  genre; wrong or swapped fields; inconsistent album vs albumartist; compilation
  / Various Artists handling.
- Missing or low-resolution embedded cover art.

**E. Duplicates**
- Same recording present more than once (the app's existing clustering
  competence; Perfect extends it). Must **not** remove legitimate repeat
  appearances (a track on both its album and a compilation): move aside for
  review, never auto-delete.

**F. Unplayable / DRM**
- FairPlay-protected `.m4p` and other unplayable/corrupt files. Detect and flag;
  never decrypt (§7).

---

## 4. Pipeline

1. **Scan & diagnose** — walk the (local) library; read tags and structure;
   produce a deterministic, complete diagnosis of every problem class in §3 with
   counts and locations.
2. **Identify** (Phase 2+) — identify the actual recording by **acoustic
   fingerprint** (works with zero/garbage tags), layered: cluster by existing
   album tags first (fast, keeps albums intact), then fingerprint only the
   leftovers.
3. **Resolve** — map identified tracks to a canonical authority (§5) for true
   artist/album/title, applying the user's chosen naming policy consistently.
4. **Propose** — build the "after": corrected tags, embedded art, tidy folder
   tree, junk removed, empties gone, DRM flagged — each change carrying a
   **confidence level**.
5. **Review** — before → proposed → user override, grouped by album/artist,
   coloured by confidence. High-confidence changes may be bulk-accepted; anything
   uncertain shows the top 2–3 candidates and **never auto-applies**. Nothing is
   written yet.
6. **Commit** — write tags, rename/move/delete via the existing engine, with a
   **snapshot + one-click undo** (per run and per album).

**Safety rules (mandatory):**
- Nothing touches disk until the user approves.
- Every change is reversible; originals are snapshotted before any write.
- Low-confidence matches are never auto-applied.
- No "one-click fix everything" that writes before review.

---

## 5. Metadata & identification stack

- **Identification — dual on-device fingerprinting:**
  - **AcoustID + Chromaprint** — fingerprint computed locally (audio never leaves
    the machine; only a hash is sent for lookup), returns a MusicBrainz ID.
    Chromaprint is LGPL → link dynamically or shell out to `fpcalc`.
  - **ShazamKit** — Apple's native macOS fingerprinter: on-device, matches a
    large commercial catalogue, returns Apple/ISRC IDs. A second, independent
    engine; agreement between the two indicates high confidence.
- **Canonical naming — MusicBrainz** — open authority; data is **CC0**, so it may
  be cached, shipped, and mirrored. Its alias + sort-name + artist-credit model
  resolves "The" handling and `&`/`and` by authority rather than guesswork. For
  large libraries, a local mirror avoids the public API's 1 req/s limit.
- **Cover art — Cover Art Archive** (keyed by the same MusicBrainz ID), with
  Apple high-resolution artwork as an optional upgrade.
- **Enrichment (optional, long tail) — Discogs** for vinyl/electronic/pressings.
  Its data licence is restrictive: query and display, do not redistribute/cache
  as data.
- **Not used:** Spotify (its terms prohibit building a metadata database from it,
  and it offers no fingerprinting) and Gracenote (enterprise licensing only).

**Matching quality:** combine fingerprint agreement, duration delta, string
similarity of existing tags, and release-context sanity into confidence bands
(auto-apply / suggest / needs-review). Cache CC0 MusicBrainz results locally so
re-runs are instant. Be a good API citizen — descriptive User-Agent, respect
rate limits, keep fingerprinting on-device.

---

## 6. Related tools and the safety model

Existing tools each cover part of this problem with a different trade-off:

- **MusicBrainz Picard** — manual GUI, AcoustID fingerprinting, per-track visual
  matching; tedious at scale, weak deduplication.
- **beets** — highly scriptable, fingerprinting via a plugin; CLI only.
- **SongKong / Jaikoz** — strong multi-source matching (AcoustID + MusicBrainz +
  Discogs). SongKong is automatic with a preview mode and persistent undo; Jaikoz
  offers a check-before-save spreadsheet grid.
- **bliss** — rule-based, continuous library maintenance rather than one-shot.
- **Yate / Metadatics / Mp3tag / TagScanner** — manual taggers; only some
  fingerprint.
- **Roon** and similar servers — non-destructive metadata overlay; do not write
  files or fix folder structure.

Design rationale drawn from these: automatic identification is only trustworthy
when paired with a visual before/after review the user approves, and with
guaranteed non-destructive undo. Silent destructive rewrites are the most-cited
failure mode of automatic tools; Perfect's review gate exists specifically to
avoid that. Perfect does not attempt to replicate server-side presentation
(biographies, reviews, credit browsing); it produces clean files on disk.

---

## 7. DRM / `.m4p` — detect and route, never decrypt

- **Detect** by parsing the MP4 atom tree: a FairPlay track carries the `drms`
  codec tag in `stsd` (authoritative); the `ftyp` brand `M4P` is a fast
  pre-filter. Read-only inspection.
- **Never circumvent.** Removing FairPlay is prohibited under US DMCA §1201, the
  EU Copyright Directive, and UK law, with no personal-use/format-shifting
  exemption in any of them. The only historically lossless tool (Requiem) is
  defunct.
- **Behaviour:** flag DRM tracks as a distinct category ("Protected — most
  players including Roon cannot play these"), show the manifest, and describe
  each track's legitimate route: re-download from Apple purchase history
  (iTunes Plus); match via an Apple Music / iTunes Match subscription; re-rip
  from an owned CD; or none available. The user performs the sanctioned action
  in Apple's own software; the Apple Music API can help identify which owned
  tracks are re-acquirable. The app never decrypts.
- FairPlay applied only to iTunes Store purchases from 2003–2009, so this is a
  bounded, shrinking case, but a real one for manually-carried-forward libraries.

---

## 8. Phasing (each phase usable on its own)

**Phase 1 — Tidy** *(local, no network, low risk; reuses the File Commander
engine)*
- Detect + review + fix: junk removal (class A), empty-folder cleanup and
  illegal-char renames (class B), duplicate-*folder* merges (class C at the
  folder level), duplicate-recording handling (class E), and DRM detection +
  manifest (class F).
- Ships the **before/after review + commit + undo** workflow with zero network
  risk, establishing the safety model everything later depends on.

**Phase 2 — Identify & Tag**
- Acoustic identification (AcoustID + ShazamKit), MusicBrainz resolution,
  confidence banding.
- **Tag writing** (ID3 / MP4 / Vorbis) — the new capability.
- Naming-policy normalisation (class C at the tag level) and tag
  correctness/completeness (class D), through the same review gate.

**Phase 3 — Enrich**
- Embedded cover art (multi-source, minimum-resolution rules).
- A configurable **server-ready output profile** (consistent
  ALBUMARTIST / primary-artist, Various-Artists handling, multi-disc tags,
  MBID/UPC stamping), targetable at any server.
- Optional **classical-aware tagging** (COMPOSER / WORK / MOVEMENT / ENSEMBLE /
  SOLOIST).

---

## 9. Phase 1 detail (recommended starting point)

1. **Diagnosis pass** — extend the existing scanner to detect classes A, B, E, F
   and folder-level C, producing a structured, per-item diagnosis (path, problem
   class, proposed fix, confidence, reversible yes/no).
2. **Review UI** — a new screen: grouped, colour-coded before/after; per-item and
   bulk accept/reject; user overrides; clear separation of safe cleanups (junk,
   empties) from judgement calls (merges, renames, deletes).
3. **Commit engine** — reuse the File Commander transfer/rename/delete machinery;
   add a snapshot + undo log built on the existing run-log infrastructure.
4. **Config** — user-selectable conventions (target folder layout, "The" policy,
   `&`/`and` policy, delete vs quarantine, server profile) so it adapts to any
   library and target (per §0).
5. **DRM manifest** — detection plus the legitimate-route list, exportable.

Everything runs against the local copy first; the existing copy-to-server step
delivers the cleaned result.

---

## 10. Settled decisions

- **Usage model:** support **both** a full restore pass over the whole library
  and an incremental "new/changed files only" re-run. The model tracks what it
  has already processed so later runs surface only what is new or has drifted.
- **Removal behaviour:** removed items (junk, empty folders, duplicate tracks)
  are **quarantined** to a recoverable holding area by default, not deleted;
  nothing is permanently gone until the user empties the quarantine.
- **Naming:** the metadata authority determines the *identity* (which artist /
  album a track really is); where the authority's canonical *form* differs from
  the user's chosen convention (e.g. "The" handling, `&`/`and`), the difference
  is **flagged in the review for a manual choice** rather than auto-applied.
- **Where it works:** **hybrid, stream-as-needed** — Perfect operates against the
  library wherever it lives (local or server) and pulls each file's audio locally
  only when it needs to fingerprint/read it, caching temporarily; no full upfront
  copy.
- **UI placement:** Perfect is the **first item** on the main window's top bar,
  ahead of the dedupe wizard (Perfect › Source › Review › Clean up › Copy |
  Browse). Restoring/cleaning the library is the start of the process; dedupe and
  copy follow. Perfect has a self-contained diagnose → review → commit flow.
- **Classical:** the **full classical tag model** (composer / work / movement /
  ensemble / soloist) is in scope for Phase 3.

### Still open
- Exact quarantine location and retention (in-library folder vs system Trash vs
  app-managed store).
- Duplicate-artist merge granularity in the review (per-artist vs per-album).

---

## 11. Sources (research)

- Identification/metadata: AcoustID/Chromaprint (acoustid.org), MusicBrainz API +
  CC0 data licence (musicbrainz.org/doc), ShazamKit
  (developer.apple.com/shazamkit), Cover Art Archive (coverartarchive.org),
  Discogs API terms, Apple Music API / MusicKit. Spotify and Gracenote assessed
  and excluded.
- DRM: FairPlay `drms`/`M4P` detection (FFmpeg), Apple iTunes Plus re-download /
  iTunes Match / Apple Music matching, DMCA §1201 / EU Directive 2001/29 / UK
  CDPA (no format-shift exemption), Requiem (defunct).
- Related tools: MusicBrainz Picard, beets, SongKong / Jaikoz, bliss, Yate,
  Metadatics, Mp3tag, TagScanner; Roon documentation (non-destructive overlay).
