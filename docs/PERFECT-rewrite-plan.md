# Re-architecting "Perfect": Phase-1 pre-pass + per-album loop

*Revision 2 — updated after a 46-agent plan review against `feat/perfect-qa` HEAD
(dd2de19). Work happens on `feat/perfect-v2`, stacked on `feat/perfect-qa`,
behind a `perfectV2` flag, as its own PR — revertible as a unit at any time.*

## Context

Batch "Perfect" mangles albums that per-album "Perfect this album" handles
cleanly. A 5-agent forensic investigation traced this to structural flaws in the
batch pipeline; a follow-up review of this plan against HEAD found one of them
already fixed on the branch. The case for the rewrite now rests on:

1. **Albums drop out** *(confirmed at HEAD)*. Every stage after Identify
   (Details / Artwork / Review) keys off `proposals` — which only exist for
   tracks AcoustID **matched** — plus an `isActionable` filter. Already-correct
   or unidentifiable albums produce zero proposals and vanish from the wizard.
   Worse, the proposals-gated *apply* steps skip them while disk-driven
   organise/dedup still reorganise them — an album you never reviewed still gets
   moved/renumbered.
2. **Ordering hazard** *(residual)*. The original flaw — "names files before
   correcting disc/track, correction silently swallowed, tag/filename desync" —
   is **already fixed on this branch**: commits 7e6ebd7 + 6babedf (+ 93cb50f,
   e842bfd, hardened in dd2de19) give both modes one-run disc/track correction
   with the matching rename. What survives is narrower: batch ORGANISE (commit
   step 3) still runs before the step-5 disc-fix and can quarantine
   number-colliding distinct tracks first.
3. **Edition-blind dedup** — `buildClusters`' title-based gate compares
   `normText` albums (`Engine.swift:314`), so edition twins with different
   suffixes never cluster there. (Note: the pre-existing pass 2.5 already
   clusters edition twins via `canonicalAlbumKey` **when their (disc,track) keys
   match**; the residual gap is twins whose numbering differs or is missing.)
4. **Duplicated logic.** The batch `commit()` contains a per-folder loop
   duplicating the per-album engine's checks — the source of past parity bugs.

The per-album engine `AlbumPerfect.analyze` (`LibraryWindows.swift`) reads
folders directly (no `proposals` gate) and corrects disc/track in memory before
naming — one ordered pass, applied as one reversible run, reusing every shared
"brain" the batch does.

**Outcome:** replace the batch pipeline with a thin driver that runs the proven
per-album engine over every folder, preceded by a cross-folder normalizer and
followed by a final-tags pass. Net: retire ~2,300–2,700 lines of duplicated
batch/wizard code. Nothing can silently drop or mis-number albums again.

## The batch-function decision

**Keep `PerfectStore`; delete `commit()` and the 8-step wizard chrome.**
`PerfectStore` owns `root`, `runs`, the reversible-apply/undo machinery and the
static tag helpers — it becomes a thin **driver**. Deleted: the ~673-line
`commit()`, the stage methods (`identify()`/`enrich()`/`organise()`/`dedup()`/
`planArtworkStage()`), the stage-gating `@Published` flags, `albumChanges`,
`nameKindEnabled`, and most of `PerfectView.swift`'s 8-step UI. Kept and reused:
`applyLibraryRun`/`performLibraryOps`/`undo`/`loadRuns`/`RunRecord` + static
helpers. **`WizardUI.swift` stays** — it is the Transfer/import wizard + shared
`ArtworkView`, not Perfect. *(Verified at HEAD: every deleted symbol's callers
are inside the deleted set; Engine.swift, Transfer, ContentView, and the Runs
window touch only kept members.)*

**Also disposed of explicitly (review findings):**
- **`PerfectPlan` persistence** (`savePlan`/`loadPlan`/`clearPlan`/
  `resumableLibrary` + ContentView's launch auto-resume): **deleted** — it is
  built on deleted state (`proposals`, `wizardStep`, stage flags) and its save
  is gated on `!proposals.isEmpty`. The two user-choice sets it persists,
  `declinedAlbumMerges` and `confirmedCompilations`, move to a small dedicated
  store (same pattern as `AlbumReconcileStore`) so Phase 1 can still seed from
  them across launches.
- **Tier-2 review needs real `TrackProposal`s, not strings.** The reused A/B
  card (`reviewQueueSection`) is data-bound to `store.proposals`
  (score, enrichment, A/B preview). `AlbumPerfect.analyze` must **retain the
  per-track `TrackProposal`** returned by `ident.resolve` and attach it to the
  Tier-2 item; "split the identify emission into line-items" is not enough.

## Recommended approach

### Phase 1 — headless, reversible cross-folder normalizer
New `Normalize.swift` producing a strict one-folder-per-album tree. **Reuses
existing brains, invents no new logic:**
- Artist-folder merge — extract the `ArtistIssue.folderSources` detection +
  `commit` step-1 merge mechanics.
- **Artist tag-spelling unification** *(was lost)* — carry forward the tag side
  of `ArtistIssue` too (`checkTags`/`TagGroup`: one artist under several
  spellings, user picks the canonical name, every differing artist tag is
  rewritten). Folder merges alone leave "Buzzcocks" vs "The Buzzcocks" tags
  split forever. The canonical-name picker moves to the Phase-1 confirm surface.
- Edition/disc-split merge — `Organiser.albumMergeCandidates` + the
  `MergeAlbumsSheet.merge()` tag/move computation generalized to
  `mergePlan(groups:) -> (tagWrites, moves)`. **Spec:** `mergePlan` takes
  pre-read disc tags as *input data* (no `PerfectStore.readField` calls inside)
  so it stays Foundation-only and swiftc-testable.
- VA grouping + loose-folder split/re-file — one `Organiser.plan(inputs,
  composerFirstForClassical:, renumber:, compilations:, mergeAlbums:)` call —
  **passing through the user's persisted `composerFirstClassical` and
  `renumberTracks` settings** *(was omitted)*.
- **Junk/empty cleanup** *(was lost)* — fold `diagnose()`'s junk findings
  (`.DS_Store`, AppleDouble, `Thumbs.db`, empty folders) into the Phase-1
  reversible run, and add **emptied-source-folder pruning** to
  `performLibraryOps` as a post-move sweep so merges never strand folder shells.

Order (idempotent): artist merge (folders + tags) → edition merge → junk/empties
→ one `Organiser.plan` pass. Applied as **one reversible, sessionID-stamped
run**. Edition merges + compilation grouping are previewed for confirm using the
existing `MergeAlbumsSheet` rows + compilation checklist, seeded from the new
declined/confirmed store; artist-folder merges auto-apply (high-confidence,
undoable).

### Phase 2 — the driver (`PerfectStore.perfect()`)
1. Enumerate album folders (reuse the `LibraryBrowserView` walk — note
   `buildAlbums`/`listDir` are private to the View; extract them to a shared
   helper) → `[LibAlbum]`.
2. Phase 1 preview → confirm → apply one run; re-enumerate (tree changed).
3. For each folder: `(fixes, art, reconcile) = await AlbumPerfect.analyze(...)`;
   tier the fixes (below); apply Tier-1 via `applyLibraryRun` (one run per
   album, `sessionID`-stamped); accumulate Tier-2 items + missing/damaged
   reports *(their producers move out of the deleted `commit()` into the
   driver)*; progress "Album N of M", cancel between albums.
4. **Final-tags pass** *(was lost)*: after the loop, re-run
   `Organiser.plan` + `albumMergeCandidates` + a library-wide dedup
   (`buildClusters` with the `canonicalAlbumKey` gate fix) **on the corrected
   tags** — this is what today catches an "Unknown Album" folder that identify
   revealed to be *Check Your Head*, merges editions whose tags only now agree,
   and re-files folders whose album-artist changed. Without it, folders never
   move to match their corrected tags.
5. Present the review roll-up; on confirm, apply queued Tier-2 items — **after
   remapping every queued rel through the moves the session actually applied**
   (Tier-1 renames + step-4 moves change paths; `performLibraryOps` silently
   no-ops writes to vanished paths).

**Apply granularity — per-album runs stamped with a `sessionID`**, and **the
Phase-1 run, the step-4 pass, and the roll-up run are sessionID-stamped too**
(the original plan omitted them, making "undo whole session" unsound). "Undo
whole session" requires an **awaitable, strictly sequential newest-first
revert**: the existing `undo()` is fire-and-forget (`Task.detached`), so looping
it launches concurrent reverts that race each other across shared paths — add an
async variant and chain it.

### Review roll-up — two-tier apply

**Blocker fix — identify entanglement.** `analyze` writes the identified names
into its in-memory tracks *first*, and every downstream fix (dedup clustering,
album consensus, reconcile matching, disc/track slots, filename tidy) is
computed from those names. Deferring substantive identify changes while
auto-applying the rest would rename files to titles never written to tags and
remove duplicates on the strength of an unaccepted identification. Therefore:

- **Albums whose identify emission contains a substantive change**
  (`Identifier.classifyChange == .substantive`) get **no Tier-1 auto-apply of
  dependent fixes**. The whole album is queued to Tier 2; after the user
  accepts/rejects the names, the driver **re-runs `analyze`** with the verdict
  applied (accepted names written first, or rejected proposals excluded) and
  then auto-applies the now-clean fix set.
- Albums with only cosmetic/additive identify changes (or none) flow through
  Tier 1 unchanged.
- **Album-name resolution joins the identify emission** *(was lost)*: `analyze`
  currently ignores `p.chosenAlbum`/album candidates, so an "Unknown
  Album"-tagged folder could never get its real album name. Consume the album
  side too (folder consensus + `Identifier.searchAlbum` fallback, as batch
  `reconcileAlbums` does) and route substantive album changes through Tier 2
  like titles/artists.

**Tier 1 (auto, silent, per album):** album/album-artist consensus, *confident*
artist split, disc-order + disc/track correction, credits, filename tidy, dedup
— **subject to:**
- The driver **honors `AlbumFix.enabled` defaults**: an `applyable` fix emitted
  with `enabled: false` (the ambiguous spaced-list artist split — "CHECK it's
  not a band name") is **never auto-applied**; it queues as a third Tier-2
  section, matching the batch's log-for-review behaviour.
- **Compilation flagging moves out of Tier 1** *(was a silent VA-retagging
  hazard for duet/collab albums)*: `looksCompilation` results join the Phase-1
  compilation confirm checklist (which already exists) rather than auto-writing
  `Various Artists` + `compilation=1`.
- **Dedup ports the merge-of-best backfill** *(was lost)*: before emitting the
  losers' quarantine moves, copy the keeper's blank tag fields (11 fields) and
  missing cover art from the losers, as both batch paths do today.
- **Front-cover promotion** *(was lost)*: add an `artPromotions` parameter to
  `performLibraryOps` (the undo side already exists) and emit promotions from
  the engine's art context.
- **Cosmetic name fixes** *(decision)*: `analyze`'s `nameChanged` gate
  (normText equality) currently *drops* pure case/punctuation corrections — they
  are never proposed, so "cosmetic auto-applies" was wrong. **Relax the gate to
  emit cosmetic changes into Tier 1** so the old `applyCosmeticNames` capability
  survives; this is also what justifies dropping the per-kind toggles.

**Tier 2 (queued for one review surface):** (a) substantive identify changes
(title/artist/album) — per-track A/B items carrying their `TrackProposal`,
whole-album deferral semantics; (b) cover picks — albums with missing/mixed
covers or a differing online candidate; (c) ambiguous artist splits (opt-in).

**UI (reuse, don't rebuild):** one scroll, collapsible sections — *Names to
confirm* reuses the `reviewQueueSection` A/B card + `changeKindTags`; *Cover art
to choose* reuses `PerfectAlbumSheet`'s `coverPanel`/`CoverThumb` +
`ArtworkReviewCard`; *Artist splits to confirm*. Missing/damaged stay info-only
(reuse `missingTracksSummary`/`damagedTracksSummary`). **DRM findings surface
here too** *(was lost with the step-1 findings panel)* as an info-only section.

**Roll-up UX decisions (from verification on the test library, 2026-07-15):**
- **Verdicts are PER TRACK, transactions per album.** Some of an album's
  proposed names will be right and others wrong; the user ticks each track's
  A/B individually. One "Apply decisions" per album then writes the accepted
  subset, re-analyzes, and applies the dependent fixes — decision granularity
  track-level, apply atomicity album-level (the identify-entanglement fix is
  unchanged).
- **Every album-scoped row anywhere leads with the artist** ("Al Green — Love
  & Happiness…"), in the roll-up, the Normalize window, and any future list.
  Album names alone are ambiguous; this was reported three separate times.
- **Decide in batch, apply in batch.** Verdicts are instant, offline ticks
  across the whole queue; nothing applies until one "Apply all decisions"
  runs the batch (per album: write accepted names → re-analyze → apply
  dependent fixes, one undoable run each, "Album N of M" progress). Never
  block the user on a network re-analyze between judgments; partial passes
  are fine — undecided albums stay queued.
- **Cover search: precision over volume, with a manual escape hatch** (user
  observation, 2026-07-16): v2's tag-driven cover search finds FEWER but
  better-matched covers than the old batch/per-album flows — keep the
  tag-driven query as primary, and add a fuzzy/manual search option (editable
  artist/album query) for when it misses, both in the roll-up's cover section
  and in per-album "Perfect this album" — which today offers no way to edit
  the album/track names used for lookup, unlike the old wizard's manual
  search.
- **Per-track verdicts are confirmed as the top rebuild priority** (reported
  again 2026-07-16): the interim whole-album Accept/Keep forces batch
  authorisation of name changes; users need to approve each track's change
  individually.
- **Design mockup BEFORE building the v2 wizard/roll-up UI**: ✅ produced and
  APPROVED (2026-07-16) — interactive mockup at
  https://claude.ai/code/artifact/f6044fc3-64d6-4803-9f4c-2247b176c4c8 .
  Key agreed elements: per-track Accept/Keep segmented verdicts with
  confidence-flipped defaults (low-confidence pre-selects Keep, amber score
  chip), Accept-all/Keep-all per album, artist-first accent-colored
  attribution, sticky batch-apply bar with live decision count, duplicates
  as pick-cards with play buttons and first-class "Keep both", covers with
  the editable search query, DRM/reports collapsed info sections.
- **A "Duplicates to decide by ear" section joins the roll-up**: same-slot
  twins whose durations differ (auto-dedup rightly refuses) and
  different-track move collisions (the Elvis 2-22 case) become first-class
  review items with play-A/B buttons and keep-A / keep-B / keep-both-renumbered
  verdicts — one surface for every listen-and-decide judgment in the session,
  instead of orange text in Normalize and silent co-location.

### `performLibraryOps` additions (shared, small)
- **Same-recording collision → quarantine** *(was lost — also required for
  Phase-1 idempotency)*: port `commit()` step 3's size/duration check; today's
  bare "SKIP (target exists)" strands duplicates outside the tree where the
  per-album loop never sees them. Keep the landed case-only-rename guard.
- **Emptied-source-folder pruning** after moves (deepest-first, genuinely-empty
  only), as `commit()` step 4 does.
- `sessionID` in the `run.json` record (additive; `loadRunRecord` is tolerant).
- `artPromotions` parameter (see Tier 1).

### Shared bug-fixes (ship first on `feat/perfect-qa`, valuable independently)
- **Edition-blind dedup** — `buildClusters` album gate `a.al == b.al`
  (`Engine.swift:314`) → compare `Organiser.canonicalAlbumKey`. (Pass 2.5
  already covers same-(disc,track) twins; this closes the rest.)
- **Fuzzy title matching** — exact-`typoFold` equality in `discSections` and
  `analyze` missing-detection strands near-dups. Add
  `Identifier.fuzzyTitleMatch` = length-gated Levenshtein ≤1 built on
  `hardFold` — **which is NOT unused: `classifyChange` (the Tier-2 filter)
  calls it; do not change `hardFold`'s semantics**, and add a test that the
  cosmetic/additive/substantive boundaries are unchanged.
- **Reconcile denominator** — title-based matching already landed (bf0486f);
  the remaining work is the totals: count release slots only, render on-disk
  extras in a separate "Not on this release" section.
- **Folder-health gate — rescoped** *(original spec contradicted landed work)*:
  dup (disc,track) keys with unique titles is the healthy-flattened case the
  landed one-run correction already fixes — do **not** refuse on it. Gate only
  on the signals that distinguish a genuine mess: duplicate *titles* /
  cross-edition content overlap (the Legends shape), or a dup-key folder with
  **no confident release match** (where correction cannot run). Surface "needs
  manual attention" instead of guessing.

### Settings dispositions (one line each, per review)
- `checkMissingTracks` — **kept**, as the driver-level gate on the engine's
  reconcile step (an offline/fast whole-library run must stay possible; today
  `analyze` reconciles every 4+-track album unconditionally).
- Thoroughness (Light/Standard/Thorough) — **kept** at the driver level:
  Light skips Phase-1 auto-merges (preview-only) and Tier-1 renames.
- `renumberTracks`, `composerFirstClassical` — **kept**, passed through
  Normalize's `Organiser.plan` call.
- Per-kind cosmetic/additive name toggles and the applyNames/applyArtwork/
  applyCredits category toggles — **dropped** (subsumed by the two-tier split
  once the cosmetic `nameChanged` gate is relaxed; Tier 2 covers substantive).

## Delete / keep map (updated)
- **Delete** (`Perfect.swift`): `commit()` (~673), `identify()`/`enrich()`/
  `organise()`/`dedup()`/`planArtworkStage()`/`albumChanges` + stage flags +
  `nameKindEnabled`/cosmetic-additive toggles, `PerfectPlan` +
  `savePlan`/`loadPlan`/`clearPlan`/`resumableLibrary` + the ContentView
  auto-resume hook (~1,300+ total). **`PerfectView.swift`:** 8-step chrome +
  per-step panels (~1,000–1,400).
- **Keep** (small edits): `AlbumPerfect.analyze`/`AlbumFix`/`PerfectAlbumSheet`/
  `MergeAlbumsSheet`/`AlbumReconcileStore`/`LibAlbum`; `applyLibraryRun`/
  `performLibraryOps` (+`sessionID`, +collision-quarantine, +prune,
  +artPromotions)/`undo` (+awaitable sequential variant)/`loadRuns`/`RunRecord`
  + static helpers; `diagnose()` slimmed to a pre-scan **with its junk/DRM
  findings rewired to Phase 1 / the roll-up**; the missing/damaged report
  builders moved from `commit()` into the driver; `organiseInputsFromDisk` and
  the other input-builder statics Normalize reuses (explicitly protected from
  the deletion sweep). Reuse `reviewQueueSection`/`changeKindTags`/cover
  chooser/report summaries. **Keep `WizardUI.swift`.**

## Sequencing (each increment builds green; old path intact until the last)
1. **Shared bug-fixes** (edition-blind dedup, `fuzzyTitleMatch`, denominator
   fix, **rescoped** health gate) — land on `feat/perfect-qa`, testable via the
   inspector + `Tests/run.sh`.
2. **`performLibraryOps` additions** (`sessionID` + "Undo session" awaitable
   sequential revert in Runs; collision-quarantine; prune; artPromotions) —
   additive.
3. **`Normalize.swift`** (Phase 1) headless + unit tests; hidden entry point via
   the Library CommandMenu; verify idempotency + no-album-dropped on a copy.
4. **Phase 1 confirm surface** (MergeAlbumsSheet rows + compilation checklist +
   canonical-artist picker), seeded from the new declined/confirmed store.
5. **`PerfectStore.perfect()` driver** behind `perfectV2` (insertion point:
   `ContentView.swift:50`): enumerate → Phase 1 → per-album loop →
   final-tags pass → auto-apply; progress/cancel. (Tier-2 auto-keep for now.)
6. **Review roll-up UI** (A/B card + cover chooser + splits + reports); wire the
   two-tier split with whole-album deferral + re-analyze, and Tier-2 rel
   remapping.
7. **Flip `perfectV2` on** — ✅ DONE (2026-07-16): the library-first carousel
   is now the main window's Perfect step and the flag defaults to ON; the old
   wizard is the legacy escape hatch
   (`defaults write com.local.musiclibrarian perfectV2 -bool NO`). The
   standalone "Perfect v2" window/menu item was retired (one live driver).
   Visual polish pass to follow — styling reference is the per-album Perfect
   dialog's look.
8. **Delete** `commit()` + stage methods/flags + chrome + `PerfectPlan`;
   confirm Transfer untouched; final green build.

**Sequencing revision (2026-07-16, after the verification pass):** steps 7–8
are GATED on capability parity, not just the checklist. The old wizard still
uniquely provides capabilities v2 lacks; it stays as the shipping path until
v2 has:
- **6a. Album-name resolution** — ✅ DONE (2026-07-16): a folder with no real
  album tag rescues its name from the identify pass's release placements
  (fingerprint-backed, ≥60% agreement → fills like a consensus) or, failing
  that, a MusicBrainz text search over up to three tracks (≥2 agree →
  SPECULATIVE: an AlbumFix marked `speculative`, never auto-applied — the v2
  driver defers the album for an Accept/Keep verdict).
- **6b. Cover art surface** — ✅ first slice DONE (2026-07-16): the v2 window's
  "Covers to fill" section queues albums with artwork gaps (no cover anywhere,
  or blank tracks); each row offers the album's own covers plus an on-demand
  Cover Art Archive search, and the pick fills BLANK tracks only, as one
  undoable session run. Still to come with the roll-up rebuild:
  choose/replace/unify on albums that already have art, low-res upgrades, and
  wiring front-cover promotion in.
- **6c. DRM manifest surface** — ✅ DONE (2026-07-16): the v2 window lists
  FairPlay-protected tracks (info-only, never touched) with the legitimate
  re-acquisition guidance and a CSV export.
- **6d. Driver settings** — ✅ DONE (2026-07-16): the persisted
  missing-tracks toggle gates the release reconcile (offline-fast runs), and
  thoroughness scopes the run — Light/Standard skip edition merges
  (Thorough-only, matching the wizard), Light also keeps file names as-is.
- **LIBRARY-FIRST CAROUSEL — ✅ BUILT (2026-07-16, mockup v3 approved).** The
  library IS the carousel: choosing a library loads EVERY album as a card
  immediately (cover thumb, facts line with genre/year, read-only track
  table); Run is a visible pipeline — Phase 1 refreshes the strip once, then
  each card pulses while analyzed and turns ✓ clean or gains decision blocks
  live; the user can decide finished albums while the loop runs. Filter is
  All/Needs-decisions over one list; every analyzed album offers the cover
  chooser (replace is backed-up + undoable — the Hunky Dory ask); pending
  frames are dimmed, the analyzing frame pulses and auto-scrolls into view.
- **Earlier redesign rationale (superseded UI, kept for the record):** User verdict on the sectioned layout: grouping by issue type
  makes the same album appear in Names, Duplicates and Covers — duplicated
  effort and context switches; the per-album Perfect dialog's album-as-unit
  model is preferred. New direction (mockup v2 'carousel-redesign' at the
  same artifact URL, awaiting approval): one album per card with EVERYTHING
  it needs (names, its own duplicate calls rolled up to album-level verdicts,
  cover chooser with instant in-place preview on the big artwork, info),
  prev/next + arrow keys + a badged filmstrip for jumping, "Needs decisions"
  filter (All-albums filter exposes cover replacement on clean albums —
  the Hunky Dory ask). Batch semantics unchanged underneath.
  Also from this session's use: manage GENRE (currently unwritten anywhere);
  by-ear info lines must fall back to the folder name when the album tag is
  blank (DRM m4p showed '?'); and the stale-rel remap for queued covers/
  credits is now REQUIRED (Some Old Bullshit's cover and credits silently
  missed moved files).
- Sectioned roll-up build (superseded by the carousel, engine reused) — was
  DONE to the first mockup (2026-07-16): per-track
  Accept/Keep verdicts with confidence-flipped defaults and ▶A/▶B audition,
  artist-first cards with Accept-all/Keep-all, decide-in-batch → one "Apply
  all decisions" (per album: write accepted names → re-analyze with identify
  pinned → dependent fixes), kept-proposal persistence (never re-queues,
  never auto-applies), duplicates-to-decide-by-ear (cross-album pairs as
  Keep A/B/both cards, keep-both persisted), covers manual search with the
  VA-artist blank-out, and the global sequential Revert-library. Remaining
  polish for later: same-slot differing-duration twins and move collisions
  joining the by-ear section; choose/replace/unify covers on albums that
  already have art.

## Verification (always on a COPY of `~/Documents/iTunes Testing Small`)
- **Pure-logic tests** — all new pure logic **must live in Foundation-only,
  swiftc-compilable files** added to `Tests/run.sh`'s compile line
  (`Organise.swift`, `Normalize.swift`, or a new shared file — NOT
  `Identify.swift`/`LibraryWindows.swift`, which import ChromaSwift/SwiftUI):
  `canonicalAlbumKey` edition-blindness; `Normalize` idempotency (plan twice →
  second empty); `fuzzyTitleMatch` boundaries + `classifyChange` boundaries
  unchanged; health scoring on the Legends shape (dup titles) vs a healthy
  flattened rip (dup keys, unique titles — must NOT gate).
- **End-to-end on the copy:**
  1. **No album dropped — identity ledger, not a count**: from the session's
     `run.json` ops + the driver's per-folder log, every input folder is
     accounted for as kept / renamed / merged-into / analyze-failed; any
     `analyze-failed > 0` fails the checklist (flaw #1 was precisely silent
     drops, and legitimate merges break count-equality).
  2. **Genuine mess handled** — a Legends-shaped folder (duplicate titles across
     editions) is refused by the rescoped gate and surfaced for manual
     attention; dup titles/keys collapse after Phase 1 + dedup.
  3. **Flattened rip corrected** — a healthy flattened multi-disc set (dup keys,
     unique titles) ends with tags AND filenames agreeing in ONE run; a re-run
     proposes nothing.
  4. **Content duplicates removed with backfill** — 320k/92k twin → one keeper,
     which inherits any tags/art only the loser had.
  5. **Undo works** — per-album Undo reverts one album; "Undo session" restores
     the library to pre-run (sequential revert incl. Phase-1, final-tags, and
     roll-up runs).
  6. **Tier-2 after Tier-1** — a queued name change on a tidy-renamed file still
     applies (rel remapping), and rejecting a Tier-2 name leaves that album's
     files/tags exactly as analyze found them (whole-album deferral).
- Delete the old wizard + `commit()` only after this checklist passes.
