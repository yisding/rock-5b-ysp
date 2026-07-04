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

- `` `2026-07-04-rga3-im2d-error-irq.md` `` — RGA3 core0 raises the RGA MMU interrupt (`INTR[0x2]`, soft-reset recovers) on some direct upstream librga copy/resize samples on the av1-fwport kernel; no material RGA3 driver delta was found, but the forward-port mainline Rockchip IOMMU glue remains a plausible gap until BSP parity and fault-IOVA logs decide it — MEASURED (symptom) / ANALYZED (source comparison) / HYPOTHESIS (cause).
