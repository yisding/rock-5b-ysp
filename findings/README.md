# findings/ — raw capture inbox

Low-ceremony landing zone for a technical fact you or an agent just learned while
reading code in one of the `../` source trees. **Drop first, sort later.** The bar
to add a file here is deliberately low: one fact, dated, with where it came from.

This is the write path that the polished per-project `docs/` do **not** offer —
depositing into a package doc means editing an index table and matching house
style, so hard-won detail gets re-derived instead of written down. Here you just
add a file.

## How to deposit

1. Copy [`TEMPLATE.md`](TEMPLATE.md) to `YYYY-MM-DD-<short-slug>.md`.
2. Fill the header (scope, source anchor, date, trust tag) and write the fact.
3. Add one line to the index below. That's it — no other file needs editing.

Trust tags (state how sure you are): **MEASURED** (observed on hardware / in a
run), **HYPOTHESIS** (reasoned but unverified), **UNVERIFIED** (copied from a
comment/commit, not checked).

## Lifecycle

A finding is raw by default. When it matures into durable reference, **graduate**
it: move the content into the owning project's `docs/`, and replace the file here
with a one-line tombstone (`promoted → <path> (YYYY-MM-DD)`) so the trail survives.
Findings that turn out wrong get deleted with a one-line note in the index.

**Boundary vs [`status.md`](../status.md) watchlist:** the watchlist tracks
*facts that go stale silently* (external PRs, distro versions, dev-box SPOFs).
`findings/` holds *newly-learned technical detail*. A finding with a follow-up
action belongs here; a stale-risk to re-check on every maintenance pass belongs
in the watchlist.

## Index (newest first)

Each row: `` `YYYY-MM-DD-slug.md` `` — one-line summary — trust tag.

- `` `2026-07-04-librga-consumer-survey.md` `` — public `librga` users outside the current conformance set mostly reinforce RKNN/RKNPU RGB/NV12/NV21 preprocessing and simple fd/virtual legacy blit paths; no current Linux-media signal promotes RFBC64x4/AFBC32x8, per-channel rotation, tile alpha/pattern/color-key, or broad RGA2-Pro modes into the required RK3588 profile — UNVERIFIED public-source survey.
- `` `2026-07-04-rga3-im2d-error-irq.md` `` — RGA3 core0 `INTR[0x2]` on direct upstream librga virtual-buffer samples was root-caused to a two-part forward-port DMA/IOMMU contract gap: missing BSP large-segment setup (`13afe70c8271`) plus RGA IOVAs being allocated too close to 4 GiB and wrapping in 32-bit registers (`6b9dba7abcd0`); runtime validation pending after rebuild — MEASURED / ROOT-CAUSED / FIX COMMITTED.
