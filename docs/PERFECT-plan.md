# Perfect — Library Restoration for Music Deduper

*Plan / design document. Discussion-and-research complete; nothing built yet.*
*Written 2026-07-10. Come back to this before starting to build.*

---

## 0. Guiding principle: general-purpose, not "fix Neil's library"

**Perfect must work on anyone's library.** Every problem it fixes is *discovered
at runtime* by scanning and analysing the actual files — never from a baked-in
list of specific artists, albums, or fixes. The author's own library (surveyed
below) is a **test case and a source of realistic examples**, not the design
target. Concretely:

- No hardcoded artist/album/track names anywhere. "The Buzzcocks", "AC/DC" etc.
  are *illustrations* of general classes of problem, not entries in a table.
- Rules are **configurable and adaptive**: the user picks the target
  conventions (how to handle "The", `&` vs `and`, folder layout, which server
  they feed), and Perfect applies them consistently.
- It must cope with libraries far messier — or far cleaner — than the author's:
  huge/tiny, any genre mix (rock, classical, jazz, electronic, spoken word),
  any source (ripped CDs, store downloads, mixed provenance), any prior tagging
  tool's quirks, and any character set / language in tags.
- It targets **any modern music server** that reads embedded tags — Roon, Plex,
  Jellyfin, Navidrome, Emby, Airsonic — not Roon specifically. Roon is just the
  fussiest consumer, which makes it the strictest test.

If a design choice only makes sense for one specific library, it's wrong.

---

## 1. What Perfect is

A **free, open-source, local-first** capability of the existing app that takes a
messy music library and turns it into a clean, consistently-tagged library any
modern music server ingests perfectly — with a **before/after review the user
approves before anything is written**, and full undo.

- **Free and open**, like the rest of the app. Not a paid tier, not an unlock,
  not a separate product. Staying free also removes every commercial-licensing
  complication (see §7).
- **Local-first**: runs on the user's machine against the *local* library
  *before* it's copied to a server. Faster (local disk, not SMB), safer, and it
  means the server only ever receives clean files — "fix it at source". It
  becomes the front of a pipeline whose back end already exists:
  **scan → dedupe → Perfect → copy clean to the server.**
- **Why build it (honest reason):** it completes the tool and fixes real
  libraries (including the author's). It is *not* built for a market — see §2.

---

## 2. Market reality (deliberately honest)

There is **no market large enough to justify charging**, and Perfect should not
try to serve one. Recorded here so we don't drift back into monetising it:

- **Old messy libraries**: real but shrinking and passive. Most owners don't
  care enough to fix it; the obsessives who do already use Picard/SongKong/beets.
  A one-time need, not recurring demand.
- **Modern hi-res buyers (Qobuz/Tidal/HDtracks/Bandcamp)**: their downloads
  arrive already cleanly tagged, so Perfect's core value is mostly moot. The
  only residual value is normalising a library assembled from *multiple* stores
  (which reintroduces "The Beatles" vs "Beatles, The" style drift). Weak.
- **Roon/audiophile obsessives**: the one genuinely motivated niche — but small.

**Conclusion:** build it free because it's useful and completes the product; if
some Roon/audiophile users adopt it, good; don't scope or price it as a business.

---

## 3. The core insight

Music servers organise by the **embedded tags inside each file** (artist, album,
albumartist, title, track/disc number, etc.), *not* by folder and file names.

- Therefore the real fix for "duplicate/split artists" and inconsistent naming
  is **writing corrected tags** — renaming folders alone changes nothing in the
  server. The app today only *reads* tags (via AVFoundation); **writing** tags
  (ID3v2 for MP3, MP4 atoms for M4A/AAC/ALAC, Vorbis comments for FLAC/OGG) is
  the central new capability Perfect needs.
- Servers like Roon **never write your files** — they overlay their own
  database. So clean files on disk are *complementary* to Roon (they raise its
  identification hit-rate), not competitive. File/folder hygiene is work Roon
  explicitly says is the user's job — and the app's existing File Commander
  engine already does the moving/renaming/deleting.

Two layers, both in scope, kept distinct in the UI:
1. **Storage hygiene** — folders, empties, junk, illegal-char names, duplicate
   folders. (Engine exists.)
2. **Tag correctness** — what the server actually reads. (New: tag writing +
   identification.)

---

## 4. Problem taxonomy (general classes, discovered at runtime)

Perfect detects and offers to fix these *classes* of problem. The parenthetical
items are illustrative examples from a real library, not a fixed list.

**A. Junk / cruft**
- OS metadata litter: `.DS_Store`, AppleDouble `._*`, `Thumbs.db`, `desktop.ini`.
- Orphaned temp files from interrupted operations: `*.crswap`, `.smbdelete*`,
  partial/zero-byte files, editor swap files.
- Stray non-music files misfiled among music (loose images, videos, text).

**B. Structural**
- Empty folders (no audio anywhere inside).
- Illegal / sanitised filesystem characters in names, where a real character was
  replaced by `_` or stripped (e.g. `/ ? : * " < > |`). These are *unavoidable*
  at the filesystem level, so Perfect proposes a legible substitution (e.g.
  `AC-DC`) and, more importantly, fixes the *tag* to the true value (`AC/DC`).
- Inconsistent depth / not one-album-per-folder; disc-number vs subfolder
  mismatches; "Unknown Album" / "Unknown Artist" buckets of untagged files.

**C. Naming inconsistency (the headline "duplicate artist" problem)**
- "The" prefix variance (present vs absent vs "Name, The").
- `&` vs `and`, and other join-phrase variance.
- Multi-artist separator variance (`;` `/` `,` `feat.` `ft` `featuring`).
- Duplicated strings, casing/whitespace/diacritic variance, mojibake
  (U+FFFD replacement chars), trailing punctuation.
- These surface as **groups of variants** the user reviews and merges to one
  canonical form — driven by a chosen policy + an authority (§6), never by
  silent regex.

**D. Tag correctness / completeness**
- Missing/blank artist, album, albumartist, title, track/disc number, year,
  genre; wrong or swapped fields; inconsistent album vs albumartist; compilation
  handling (Various Artists).
- Missing or low-resolution embedded cover art.

**E. Duplicates**
- Same recording present more than once (already the app's core competence via
  clustering; Perfect extends it) — but must **not** nuke legitimate repeat
  appearances (a track on both its album and a compilation). Move-aside for
  review, never auto-delete.

**F. Unplayable / DRM**
- FairPlay-protected `.m4p` and any other unplayable/corrupt files. Detect and
  flag; never decrypt (§8).

---

## 5. How Perfect works — the pipeline

1. **Scan & diagnose** — walk the (local) library; read tags and file structure;
   produce a diagnosis of every problem class in §4 with counts and locations.
   Deterministic and complete (no partial results).
2. **Identify** (Phase 2+) — for tracks needing it, identify the actual recording
   by **acoustic fingerprint** (works even with zero/garbage tags), layered:
   cluster by existing album tags first (fast, keeps albums intact), then
   fingerprint only the leftovers.
3. **Resolve** — map identified tracks to a canonical authority (§6) to get true
   artist/album/title, applying the user's chosen naming policy consistently.
4. **Propose** — build the "after": corrected tags, embedded art, tidy folder
   tree, junk removed, empties gone, DRM flagged — each change carrying a
   **confidence level**.
5. **Review** — the whole point. Before → Proposed → user override, grouped by
   album/artist, coloured by confidence. High-confidence changes can be
   bulk-accepted; anything uncertain shows the top 2–3 candidates and **never
   auto-applies**. Nothing is written yet.
6. **Commit** — apply approved changes: write tags, rename/move/delete via the
   existing engine, with a **snapshot + one-click undo** (per run and per album).

**Non-negotiable safety rules** (this is the market differentiator — see §9):
- Nothing touches disk until the user approves.
- Every change is reversible; originals are snapshotted before any write.
- Low-confidence matches are *never* auto-applied.
- No "one-click fix everything" that writes before review (the SongKong trap).

---

## 6. Metadata & identification stack (research-backed)

All chosen so a **free/non-commercial** app can use them cleanly.

- **Identification — dual on-device fingerprinting:**
  - **AcoustID + Chromaprint** — computes the fingerprint locally (audio never
    leaves the machine; only a hash is sent for lookup), returns a MusicBrainz
    ID. Chromaprint is LGPL → link dynamically or shell out to `fpcalc`. Free
    tier is non-commercial (fine, we're free).
  - **ShazamKit** — Apple's *native macOS* fingerprinter: free, on-device,
    matches a huge commercial catalogue, returns Apple/ISRC IDs. A second,
    independent engine; when the two agree → high confidence. A Mac-only
    advantage a cross-platform rival can't cheaply match.
- **Canonical naming — MusicBrainz** — the open authority; data is **CC0**
  (the only major source we may cache/ship/mirror). Its alias + sort-name +
  artist-credit model is exactly what resolves "The" handling and `&`/`and`
  **by authority**, not guesswork. For large libraries, optionally run a local
  mirror to avoid the 1 req/s public limit (only if needed).
- **Cover art — Cover Art Archive** (free, keyed by the same MusicBrainz ID),
  with Apple hi-res artwork as an optional upgrade.
- **Enrichment (optional, long tail) — Discogs** for vinyl/electronic/pressings.
  Restrictive data licence: query and display, don't redistribute/cache as data.
- **Explicitly excluded:** Spotify (terms forbid building a metadata DB, no
  fingerprinting, access gated) and Gracenote (enterprise-only, opaque pricing).

**Matching quality:** combine fingerprint agreement + duration delta + string
similarity of existing tags + release-context sanity into confidence bands
(auto-apply / suggest / needs-review). Cache CC0 MusicBrainz results locally so
re-runs are instant.

---

## 7. Why staying free simplifies everything

The research's hard parts were all *commercial* problems. Because Perfect is
free/open:

- AcoustID's free/non-commercial tier applies — no commercial contract.
- MusicBrainz's free tier + CC0 data applies — no MetaBrainz commercial deal.
- ShazamKit is free regardless.
- The two grey areas that only mattered for a *paid* product (ShazamKit terms
  for commercial re-tagging; embedding Apple/CAA artwork commercially) relax to
  ordinary personal/non-commercial use.

Being free is not a sacrifice here; it removes the legal and licensing overhead
entirely. (Still: be a good API citizen — proper User-Agent, respect rate
limits, cache CC0 data, on-device fingerprinting.)

---

## 8. DRM / `.m4p` — detect and route, never decrypt

- **Detect** reliably by parsing the MP4 atom tree: a FairPlay track carries the
  `drms` codec tag in `stsd` (authoritative); the `ftyp` brand `M4P` is a fast
  pre-filter. Read-only inspection — legal everywhere.
- **Never circumvent.** Stripping FairPlay is illegal under US DMCA §1201, the
  EU Copyright Directive, and UK law, with no personal-use/format-shifting
  exemption in any of them. The only ever-lossless tool (Requiem) is long dead.
- **What Perfect does:** flag DRM tracks as a distinct category ("Protected —
  most players including Roon can't play these"), show the manifest, and triage
  each track's **legal** route: re-downloadable free from Apple purchase history
  (iTunes Plus); match-eligible via an Apple Music / iTunes Match subscription;
  re-rip from an owned CD; or orphan (no path — say so honestly). The user
  performs the sanctioned action in Apple's own software. Apple Music API can
  help *identify* which owned tracks are re-acquirable — never decrypt.
- Niche and shrinking (DRM only existed 2003–2009; Match users already
  upgraded), but real for exactly the "manually-carried-forward old library"
  user Perfect targets. Handle it first-class but framed as detect-and-route.

---

## 9. Competitive landscape & our differentiator (research-backed)

No existing tool combines **automatic fingerprint-grade matching + a trustworthy
visual before/after review gate + guaranteed undo** in one modern, fast GUI.
The field forces a choice:

- **Power without safety:** SongKong (best coverage, but fire-and-forget with a
  confirmed history of silent destructive rewrites — the #1 horror story);
  Picard/Mp3tag/beets (powerful but manual, or CLI-only).
- **Safety without power:** Jaikoz (best review model — a check-before-save
  grid — trapped in slow, dated Java); bliss (rules-based background
  maintenance, not a one-shot reviewed restore).

**Our unclaimed centre:** review-gated, deterministic, non-destructive — which is
already the author's design philosophy — applied to a market whose single
biggest pain is silent destructive rewrites. The review gate *is* the product.

**Do NOT build:** Roon-style presentation (bios, reviews, credits browsing) —
Roon does that well. Compete on clean files on disk, not presentation.

---

## 10. Phasing (each phase shippable on its own)

**Phase 1 — Tidy** *(local, no network, no risk; mostly reuses the existing
File Commander engine)*
- Detect + review + fix: junk removal (class A), empty-folder cleanup and
  illegal-char renames (class B structural), duplicate-*folder* merges (class C
  at the folder level), duplicate-recording handling (class E), and DRM
  detection + manifest + legal-route triage (class F).
- Ships the **before/after review + commit + undo UX** — proving the safety
  model that everything later depends on, with zero network risk.
- Delivers immediate, visible value and de-risks Phase 2.

**Phase 2 — Identify & Tag** *(the heart)*
- Acoustic identification (AcoustID + ShazamKit), MusicBrainz resolution,
  confidence banding.
- **Tag writing** (ID3 / MP4 / Vorbis) — the new capability.
- Naming-policy normalisation (class C at the tag level) and tag
  correctness/completeness (class D), all through the same review gate.

**Phase 3 — Enrich & Perfect** *(widen the moat)*
- Embedded cover art (multi-source, min-resolution rules).
- A configurable **"server-ready" output profile** (consistent ALBUMARTIST /
  primary-artist, Various-Artists handling, multi-disc tags, MBID/UPC stamping)
  — targetable at Roon or any other server; attacks Roon's real grievances.
- Optional **classical-aware tagging** (COMPOSER / WORK / MOVEMENT / ENSEMBLE /
  SOLOIST) — the universally-cited hard problem nobody solves well; a genuine
  audiophile wedge. In scope only if worth the effort.

---

## 11. Phase 1 detail (the recommended starting point)

Because it's local, low-risk, engine-reuse, and fixes real libraries:

1. **Diagnosis pass** — extend the existing scanner to also detect classes A, B,
   E, F and folder-level C, producing a structured, per-item diagnosis (path,
   problem class, proposed fix, confidence, reversible-yes/no).
2. **Review UI** — a new step/screen: grouped, colour-coded before/after; per-item
   and bulk accept/reject; user overrides; clear separation of "safe cleanups"
   (junk, empties) from "judgement calls" (merges, renames, deletes).
3. **Commit engine** — reuse the File Commander transfer/rename/delete machinery;
   add a **snapshot + undo log** so any run is fully reversible (build on the
   existing run-log infrastructure).
4. **Config** — user-selectable conventions (target folder layout, "The" policy,
   `&`/`and` policy, whether to delete vs quarantine, which server profile) so
   it adapts to any library and any target, per §0.
5. **DRM manifest** — detection + the legal-route triage list, exportable.

Everything runs against the local copy first; the existing copy-to-server step
delivers the cleaned result.

---

## 12. Open decisions (revisit when starting)

- **One-shot vs ongoing:** is Perfect a one-time "revive this library" batch, or
  a tool you re-run as you add music? Affects whether the UX optimises for a big
  reviewable diff or incremental touch-ups. (Lean: support both — a full pass
  and a "just the new/changed files" pass.)
- **Delete vs quarantine:** default to moving junk/empties/dupes to a review
  quarantine (recoverable) rather than deleting outright, at least until trust
  is established.
- **Naming authority vs user policy:** when MusicBrainz's canonical form
  disagrees with the user's chosen convention, which wins? (Lean: user policy
  is applied *on top of* the resolved canonical identity.)
- **Name of the app:** if Perfect becomes central, "Music Deduper" undersells a
  library restorer — reconsider later; low-stakes, not a blocker.
- **Classical scope:** include Phase 3 classical tagging or defer.

---

## 13. Sources (research, 2026-07-10)

- Identification/fingerprint & metadata: AcoustID/Chromaprint (acoustid.org),
  MusicBrainz API + CC0 data licence (musicbrainz.org/doc), ShazamKit
  (developer.apple.com/shazamkit), Cover Art Archive (coverartarchive.org),
  Discogs API terms, Apple Music API/MusicKit. Spotify & Gracenote assessed and
  excluded.
- DRM: FairPlay `drms`/`M4P` detection (FFmpeg), Apple iTunes Plus re-download /
  iTunes Match / Apple Music matching, DMCA §1201 / EU 2001/29 / UK CDPA
  (no format-shift exemption), Requiem (defunct).
- Competitors: MusicBrainz Picard, beets, SongKong/Jaikoz (JThink), bliss, Yate,
  Metadatics, Mp3tag, TagScanner; Roon KB (non-destructive, "not a tagger").

Full per-claim source URLs are in the session research; reproduce with a fresh
research pass if needed before building the networked phases.
