# Repository organization migration ledger

> **Temporary execution state — active.** This ledger implements the accepted
> [`repository organization proposal`](repository-organization-proposal.md).
> It is not a second repository contract. Normative rules remain in
> [`CONTRIBUTING.md`](../CONTRIBUTING.md) until the MPP pilot proves the target
> interface and the accepted rules are moved there. Remove this file after every
> slice is closed and all lasting rules or risks have an owner.

## How to use this ledger

Each slice has one stable `ORG-##` ID. A row is only **closed** after its exact
inbound routes, mutable assertions, promoted observations, checker changes,
security-boundary review, validation, and unresolved items have been recorded.
Before removing any maintained text, name the new owner here and classify the
old copy as **keep**, **link**, **promote**, or **remove**. A broad row must be
split before implementation when it would otherwise mix independent owners.

Statuses are `PLANNED`, `MAPPED`, `ACTIVE`, and `CLOSED`. `CLOSED` means the
slice has passed `bash scripts/check-repo.sh`; it does not mean a later slice
may silently reopen its ownership decision.

## Phase 0 baseline

Baseline commit: `a6f9d05ff389b1f11b0c28efb2e7f1f3ddbb5831` on 2026-08-05.

The structural baseline is reproducible from that commit with:

```bash
git ls-files '*.md' | wc -l
git ls-files '*README.md' | wc -l
git ls-files 'findings/20??-??-??-*.md' | wc -l
wc -l status.md docs/source-trees.md packaging/ppa/README.md
```

It contains 430 Markdown files, 78 `README.md` front doors including the root,
188 tracked top-level findings, a 903-line dashboard/watchlist, an 851-line
source map, and a 622-line PPA front door. These counts are diagnostic only;
line-count reduction is not a migration result.

The repeatable informational owner/duplication baseline is:

```bash
python3 scripts/report-doc-duplication.py --summary .
```

At the baseline it reports 10,863 prose blocks, 13 identical long-sentence
groups, 4 highly similar normalized-paragraph pairs, 675 version/SHA literals
present in more than one file, and 1,034 `current`/`currently`/`as of`
occurrences outside designated dated-state owners in 172 files. These are
review candidates, not defects and not a score to minimize. The detail report
already demonstrates both kinds of result: repeated kernel-package text that
may be intentional, and front-door state/version prose that likely competes
with a maintained owner. Use `--json` for machine-readable classification and
`--max-items N` for a bounded human review.

Two ignored in-repository generated roots were present at inventory time:
`.codex-scratch/` (including `mpp-3381-source/build/`) and
`packaging/ppa/out/`. They are not owned migration content. Do not move or
delete them under this proposal; any cleanup is a separate operator-approved
workspace task. New build state remains under `../rock-5b/build/`.

## Compatibility, evidence, and security policy

- Preserve externally visible headings during a slice, or leave a useful
  successor anchor. A retired watchlist ID always retains `#watch-wNN` with a
  dated disposition or successor.
- Repoint every maintained inbound link before removing a finding. Promote its
  useful identity, method, signal, trust classification, boundary, and
  reconstruction route into an existing durable owner; do not keep work
  chronology or a tombstone.
- Keep curated orientation first and the complete nearest-README file index at
  the bottom. Add a nested README only at a real ownership boundary.
- Prefer Debian `.dsc`, `.buildinfo`, `.changes`, source checksums, output
  hashes, and Launchpad identities for package provenance. Add package-owned
  provenance only after a concrete unanswered identity question is shown; do
  not create a universal manifest.
- Public fix inventories may own affected behavior, patch identity/provenance,
  dependencies, and validation state. Upstream destinations, submission order,
  send/withhold choices, disclosure coordination, and memory-corruption
  reproducers remain in the private `rock-5b-security` repository.
- Any slice touching kernel safety, fuzzing, reproducers, or upstream work must
  record a fresh public/private review below. Passing repository checks is not
  that review.

## Artifact-identity classes and reader journeys

Do not collapse these identities merely because their version strings match.

| Identity question | Maintained authority | Pilot lookup |
|-------------------|----------------------|--------------|
| What MPP input should a new source build use? | `packaging/ppa/build-source-packages.sh` default `MPP_COMMIT` and `MPP_UPSTREAM_VERSION` | Inspect the two assignments and the `build_mpp` export call. |
| What source produced a particular package artifact? | The artifact's Debian source/build metadata and checksums; a package-specific record only if those prove insufficient | Reconstruct the MPP upload from `.dsc`, `.buildinfo`, `.changes`, source/output hashes, and Launchpad source/build identities. |
| What does the external archive report? | Launchpad itself; W05 is only a dated cache | Run W05's exact API recheck and apply its freshness rule. |
| What is installed and runtime-qualified? | Fresh finding during intake, then the existing MPP/package validation owner that absorbs its useful evidence | Trace package identity, board/kernel, official and focused workloads, pass signals, logs, trust, and boundary from the MPP closure evidence. |
| What can users rely on? | Compact `status.md` track 9 rollup, with direct evidence and W05 routes | Read the capability/boundary without decoding build IDs, then follow the package/evidence link. |
| Does version equality prove artifact identity? | No; actual package metadata does | Replay the VA-API local-versus-PPA same-version case as the negative control. |

Representative handoff journeys to replay after the pilot are:

1. newcomer: root task router → PPA support guide → recovery boundary → first
   device and FFmpeg verification;
2. returning maintainer: status track 9 → one next proof → maintained evidence
   owner;
3. package maintainer: intended MPP input → actual source artifact → Launchpad
   observation → installed/runtime result; and
4. developer: MPP project front door → maintained model → canonical test or
   package operation.

## Existing blocking owner checks

These checks remain green until their owning slice replaces their assumptions
atomically. Removing a duplicate literal first is not permitted.

| Check | Present assumption | Replacement slice |
|-------|--------------------|-------------------|
| `check_status_ledger_tracks` and status-table contiguity tests | Every dashboard row has a same-number/same-name ledger row. | `ORG-10`; make ledger rows optional only while preserving parse coverage and name consistency for rows that remain. |
| `check_watchlist_pairing` and its tests | Every live W-ID has matching index/detail names and dates. | `ORG-11`; retain pairing for live items and add retired-anchor/authority-kind reporting with the watchlist cleanup. |
| `check_ppa_ffmpeg_install_pin` and its tests | Installer, changelog, PPA README, and build-script FFmpeg literals agree. | `ORG-21`/`ORG-34`; move the owner to the build input and actual artifact metadata in the same change that removes duplicate documentation literals. |
| `check_ppa_grd_source_pin` and its tests | GRD build defaults, changelog, PPA/source-delta/source-map/external-workspace prose all repeat the source pin. | `ORG-21`/`ORG-35`; replace the prose-literal fan-out with a structured build-owner check atomically. |
| Findings index/topic checks | Every finding, including old promotion tombstones, remains in the generated chronology; topic groups exclude tombstones. | `ORG-41`; teach indexes to represent the live inbox while each promotion removes its finding and maintained inbound links in one change. |
| Nearest-README ownership/navigation | Every maintained document/tool is named by its nearest README and every nested README is linked upward. | All slices; preserve this rule, with curated entry points before a compact file index. |
| Kernel helper synchronization and packaging pins | Copied helpers and high-risk package inputs cannot drift. | `ORG-21`/`ORG-22`; retain or replace only with an equally explicit owner check. |

## Slice index

The routes/checks column names the compatibility surface known before mapping;
each row gains exact file and anchor references before it becomes `ACTIVE`.

| ID | Area and current role | Mutable assertion owner; observation disposition | Routes, checks, and security review | Status / unresolved |
|----|-----------------------|-----------------------------------------------|-------------------------------------|---------------------|
| ORG-00 | Phase 0 ledger and informational baseline | This ledger temporarily owns migration state; `report-doc-duplication.py` owns the reproducible signal definitions. No repository assertion moves. | `docs/README.md`, `scripts/README.md`; nearest-README, script-mode, regression tests. Security: not applicable; inventory only. | CLOSED 2026-08-05 — focused tests and full handoff gate pass. |
| ORG-01 | MPP vertical pilot across build input, artifact, publication, runtime, and status | Build script owns intended pin; standard metadata owns actual artifact; Launchpad/W05 own live/datestamped publication; existing MPP/package owner absorbs closure evidence; status track 9 owns public rollup. Promote the useful closure evidence and remove its intake finding only after all inbound links move. | Track 9, W05, W25, MPP package/source docs, PPA docs/history, `findings/README.md`, direct finding links, ledger row 9; status-ledger/findings checks. Security: required because MPP/kernel logs and private reproducer boundary are adjacent; no reproducer or disclosure plan may move. | CLOSED 2026-08-05 — owners, reconstruction, negative control, link migration, intake removal, checker changes, and full handoff gate pass. |
| ORG-02 | Adopt the pilot-tested contract and add small templates | `CONTRIBUTING.md` becomes normative owner; templates illustrate README, explanation, runbook, live-plan, and audit interfaces. Proposal/ledger do not remain contracts. | Root/docs routes, nearest-README rule, all pilot compatibility findings. Security fields stay mandatory in ledger workflow. | CLOSED 2026-08-05 — normative contract and five shared interfaces are linked, complete, and handoff-gated. |
| ORG-10 | Dashboard and optional cross-project ledger | `status.md` owns compact verdict/next proof; only irreducible synthesis remains in `status-ledger.md`; project/finding owners receive exact identity and evidence. | Every numbered dashboard/next-gate/ledger row and inbound ledger link; replace mandatory-pair checker atomically. Security review per kernel/upstream row. | PLANNED; split by track before activation. |
| ORG-11 | Watchlist cache | Remote/service/host/board is authoritative; live W-item owns dated cache/recheck/freshness only. Promote stable knowledge/internal work and retain retired anchors. | Every W01–W25 index/detail anchor and inbound W-link; pairing checker plus authority/retired-anchor report. Security review required for W19 and any memory-safety item. | PLANNED; classify every W-ID before activation. |
| ORG-20 | `source-trees.md` source map | Immutable documentation/comparison pins and reconstruction only; scripts/manifests own intended inputs, project docs own mechanism/results. | All source-tree section links and file/line citations; FFmpeg/GRD checks migrate only with owning package slices. Security review for kernel source/fix material. | PLANNED; split by source family. |
| ORG-21 | PPA topology, package provenance, publication, and history | Package scripts own intended inputs; standard metadata owns artifacts; Launchpad/W05 own service state; runbooks own upload/sign/recovery; retain only incident/otherwise-unavailable history. | PPA/newcomer/package READMEs, installer, changelogs, W05, history links; FFmpeg/GRD pin tests and package helper checks. Security: public fix versus private submission/disclosure boundary. | PLANNED; activate one source package at a time after pilot. |
| ORG-22 | Userspace patch and public technical-fix inventories | Project catalogs own behavior, public patch identity/provenance, dependencies, validation; scripts own pins. Promote useful public maintenance facts and remove publication/upstream-submission copies. | `packaging/userspace-patches.md`, package/source-delta catalogs, project READMEs. Security review mandatory; private destinations/order/send-withhold/disclosure remain private. | PLANNED; split by package. |
| ORG-30 | Rewrite validation workstream | `rewrite-validation-plan.md` owns the plan; `tests/rewrite-conformance.md` owns operations and delegates; existing project docs own accumulated result; validation index routes only. Freeze or remove audits after promotion. | Rewrite status/finding/plan/audit/index/runbook links and private-harness references; findings and nearest-README checks. Security review mandatory for fuzzing, destructive PoCs, and memory safety. | PLANNED. |
| ORG-31 | Forward-port validation and state | Patch README owns order; patch catalog owns provenance/backport; project evidence owner owns capability; status owns public boundary; findings are intake. | `forward-port-status.md`, patch docs, status tracks 1/2, W16, runbooks/findings. Security review mandatory. | PLANNED. |
| ORG-32 | VA-API validation and application route | VA-API README owns capability policy; architecture owns mechanism; app map owns consumer compatibility; status owns browser/package verdict. Promote fresh evidence, preserve superseded-plan anchors. | VA-API/app READMEs, status track 14/W18, findings, closure plans, package docs. Security: not expected; recheck if kernel safety enters. | PLANNED after ORG-01 negative control. |
| ORG-33 | Mesa validation and MR state | Remote service is MR authority; W06 is dated cache; validation/review docs own conclusions; README routes. | Mesa README/docs, W06, status track 8, findings; preserve MR links. Security: upstream destination is public fact, but submission planning remains private. | PLANNED. |
| ORG-34 | FFmpeg validation and branch state | Remote owns moving tip; build script owns intended package input; immutable comparison pins stay in source map; project docs own measured conclusions; status/W05 own verdict/publication. | FFmpeg README/docs/findings, W04/W05/W07/W21, status track 5, PPA installer/build/checker. Security: review public fix inventory versus private submission plan. | PLANNED. |
| ORG-35 | GNOME Remote Desktop validation and branch state | Remote owns branch tip; build script owns package input; project docs own design/test conclusions; status/W05 own verdict/publication. | GRD README/docs/findings, status track 7, W05/W10, PPA and GRD pin checker. Security: review public fix inventory versus private submission plan. | PLANNED. |
| ORG-40 | Project front doors, runbooks, plans, audits, and coverage | Each project README routes stable scope/boundary/model/operation; deep docs own mechanism; runbooks own commands; plans own future ladder; coverage owns scope/first missing evidence. | Activate one project/README at a time; preserve all headings/inbound links and nearest-README completeness. Security review when the project scope requires it. | PLANNED after owner consolidation. |
| ORG-41 | Findings inbox promotion | Existing project/runbook/test/catalog/package owners absorb useful evidence; findings index retains deposit guidance and views of live intake only. No tombstones or permanent `findings/evidence/` archive. | Exact inbound links, generated chronology, curated topic row/count, status citations; update findings checks atomically. Security review for every kernel safety/upstream finding. | PLANNED; promote in small owner-based batches. |
| ORG-50 | Root and work-package navigation | Root README owns short task router; `work-packages.md` owns taxonomy/reading paths; project READMEs own local routes. | Root/category/project links and representative journeys; Markdown link/anchor and nearest-README checks. Security: not applicable unless content moves. | PLANNED after canonical owners stabilize. |
| ORG-60 | Tune reporting and add targeted enforcement | Informational report owns broad candidates; structured checks own only proven high-risk assertions and retired-ID/finding-evidence invariants. | `check-repo.sh` remains sole gate; reporter/tests/check-doc-consistency/CI docs updated together. Security: reporting must not expose ignored/private material. | PLANNED; baseline false positives need classification. |
| ORG-99 | Remove temporary migration state | Lasting rules/risks/exceptions live in `CONTRIBUTING.md` or owning docs; proposal may be frozen/retired as decided. Remove this ledger only after all prior rows close. | All inbound ledger/proposal links and full completion audit; full handoff gate. Security review of final diff/history references. | PLANNED. |

## Active records

### ORG-00 — ledger and baseline

- **Keep/link/promote/remove:** keep the reporter as an informational tool;
  link it from `scripts/README.md`; keep this ledger only until ORG-99. Nothing
  is promoted or removed.
- **Inbound compatibility:** `docs/README.md` must name this ledger;
  `scripts/README.md` must name the reporter; the script must be tracked as mode
  `0755` and keep `#!/usr/bin/env python3`.
- **Validation:** focused reporter tests prove all four signal types and the
  dated-owner exemption. `bash scripts/check-repo.sh` passed on 2026-08-05: 431
  Markdown files, 3,838 local links, 388 anchors, 58 regression tests,
  ShellCheck, documentation consistency, and whitespace all passed.
- **Unresolved:** baseline candidates remain unclassified by design; ORG-60
  owns tuning after real slices expose useful and noisy signals.

### ORG-01 — MPP vertical pilot

- **Owner map implemented:**
  `packaging/ppa/build-source-packages.sh` owns intended input
  `a8b19653`; Debian/Launchpad metadata and the PPA reconstruction section own
  the actual source artifact; W05 owns the dated external publication state;
  the MPP architecture owns mechanism, evidence, trust, and boundary; status
  track 9 owns only the public rollup. W25 is retired behind its stable anchor,
  and ledger row 9 was removed because it reduced to direct owner links.
- **Artifact reconstruction:** source publication `18657949`, upload
  `38936532`, and arm64 build `33468629` retain the standard source/build
  records. The signed `.dsc` identifies orig SHA-256 `67d1921f...a59356c` and
  Debian-tar SHA-256 `82fa7843...ca94a6e8`. Rebuilding with the maintained
  default reproduced the published orig byte-for-byte; Git history explains
  the sole current Debian-tar difference, a later SPDX comment.
- **Promotion and inbound compatibility:** exact-path search identified two
  findings-index routes plus status W25, source-tree inventory, status-ledger
  row 9, the MPP project front door, two related findings, and this temporary
  ledger. All maintained links now route to the architecture/package owners;
  entries in both findings views and the superseded intake file are removed
  together.
- **Reader replay:** a maintainer finds the default in the build script, an
  auditor finds exact payload hashes in the PPA reconstruction section, an
  operator finds live state at W05, a developer finds the queue contract in the
  MPP architecture, a dashboard reader finds the public verdict in track 9,
  and a package consumer reaches all four without reading chronology. The
  VA-API negative control remains explicit: the same-version local build is
  installed/validated while the PPA-built binary is not installed or replayed,
  so version equality is not artifact identity.
- **Fan-out:** this slice changes the durable architecture, package owner,
  source inventory, project route, dashboard/watchlist, two related findings,
  optional ledger, generated/curated findings routes, contribution contract,
  checker/docs/tests, and this ledger. Most edits retire old ownership rather
  than duplicate the new fact; a future MPP runtime update should normally
  touch the architecture, W05, and track 9, plus package metadata only when its
  artifact changes.
- **Public/private review:** the promoted public content states a userspace
  event-ownership defect, fix, test shape, and bounded results. It adds no
  working memory-corruption reproducer, CVE/severity claim, disclosure
  coordination, or upstream-submission plan; private harness names and raw logs
  were not imported.
- **Checker disposition:** FFmpeg/GRD pin checks are unchanged. Ledger rows are
  now optional but must map to same-number/same-name dashboard owners when they
  exist; live watchlist pairs remain exact while retired IDs require a dated
  disposition. Findings checks see only the live inbox after promotion.
- **Validation:** all 59 repository-check regression tests pass, including the
  new optional-ledger and retired-watchlist cases. The full
  `bash scripts/check-repo.sh` handoff gate passed on 2026-08-05 with 430
  Markdown files, 3,839 local links, 398 anchors, ShellCheck, documentation
  consistency, and whitespace all green.

### ORG-02 — tested contract and shared interfaces

- **Normative owner:** `CONTRIBUTING.md` now owns the pilot-tested promotion,
  optional-ledger, retired-watchlist, evidence, security, and handoff rules.
  The proposal remains rationale during migration, not an operational contract.
- **Templates:** `docs/templates/` provides one small illustrative interface
  each for a project README, technical explanation, runbook, live plan, and
  dated audit. The templates share ownership/evidence/boundary vocabulary but
  explicitly permit project-specific omission and depth.
- **Routes:** `CONTRIBUTING.md` links the template hub; `docs/README.md` links
  the nested front door; the hub owns the exhaustive five-file index. Existing
  `findings/TEMPLATE.md` remains the distinct fresh-intake template.
- **Public/private review:** the plan and audit templates make the existing
  private submission, disclosure/CVE, and memory-corruption-reproducer boundary
  explicit without linking or importing private material.
- **Validation:** the full `bash scripts/check-repo.sh` handoff gate passed on
  2026-08-05 with all template routes, nearest-README ownership, 59 regression
  tests, ShellCheck, documentation consistency, and whitespace green.
