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
| ORG-10 | Dashboard and optional cross-project ledger | `status.md` owns compact verdict/next proof; only irreducible synthesis remains in `status-ledger.md`; project/finding owners receive exact identity and evidence. | Every numbered dashboard/next-gate/ledger row and inbound ledger link; replace mandatory-pair checker atomically. Security review per kernel/upstream row. | CLOSED 2026-08-05 — all rows route directly to existing owners; ledger retired, routes/checker valid, full gate green. |
| ORG-11 | Watchlist cache | Remote/service/host/board is authoritative; live W-item owns dated cache/recheck/freshness only. Promote stable knowledge/internal work and retain retired anchors. | Every W01–W25 index/detail anchor and inbound W-link; pairing checker plus authority/retired-anchor report. Security review required for W19 and any memory-safety item. | CLOSED 2026-08-05 — all IDs classified, successor routes/checker valid, full handoff gate green. |
| ORG-20 | `source-trees.md` source map | Immutable documentation/comparison pins and reconstruction only; scripts/manifests own intended inputs, project docs own mechanism/results. | All source-tree section links and file/line citations; FFmpeg/GRD checks migrate only with owning package slices. Security review for kernel source/fix material. | CLOSED 2026-08-05 — all 14 sections preserve immutable pins/reconstruction and route mutable assertions to their owners; full handoff gate passes. |
| ORG-21 | PPA topology, package provenance, publication, and history | Package scripts own intended inputs; standard metadata owns artifacts; Launchpad/W05 own service state; runbooks own upload/sign/recovery; retain only incident/otherwise-unavailable history. | PPA/newcomer/package READMEs, installer, changelogs, W05, history links; FFmpeg/GRD pin tests and package helper checks. Security: public fix versus private submission/disclosure boundary. | CLOSED 2026-08-05 — topology, identity boundaries, mechanics, reconstruction, recovery, and incident ownership handoff-gated. |
| ORG-22 | Userspace patch and public technical-fix inventories | Project catalogs own behavior, public patch identity/provenance, dependencies, validation; scripts own pins. Promote useful public maintenance facts and remove publication/upstream-submission copies. | `packaging/userspace-patches.md`, package/source-delta catalogs, project READMEs. Security review mandatory; private destinations/order/send-withhold/disclosure remain private. | CLOSED 2026-08-05 — delta policy, project catalogs, input owner, maintenance traps, and public/private boundary handoff-gated. |
| ORG-30 | Rewrite validation workstream | `rewrite-validation-plan.md` owns the plan; `tests/rewrite-conformance.md` owns operations and delegates; existing project docs own accumulated result; validation index routes only. Freeze or remove audits after promotion. | Rewrite status/finding/plan/audit/index/runbook links and private-harness references; findings and nearest-README checks. Security review mandatory for fuzzing, destructive PoCs, and memory safety. | CLOSED 2026-08-05 — canonical plan/operation/evidence/verdict owners, router-only index, frozen audit, and state-free teaching guide handoff-gated. |
| ORG-31 | Forward-port validation and state | Patch README owns order; patch catalog owns provenance/backport; project evidence owner owns capability; status owns public boundary; findings are intake. | `forward-port-status.md`, patch docs, status tracks 1/2, W16, runbooks/findings. Security review mandatory. | CLOSED 2026-08-05 — compact capability scorecard, mechanical series index, provenance/backport catalog, and status/W16 live owners handoff-gated. |
| ORG-32 | VA-API validation and application route | VA-API README owns capability policy; architecture owns mechanism; app map owns consumer compatibility; status owns browser/package verdict. Promote fresh evidence, preserve superseded-plan anchors. | VA-API/app READMEs, status track 14/W18, findings, closure plans, package docs. Security: not expected; recheck if kernel safety enters. | CLOSED 2026-08-05 — policy/mechanism/consumer/live-state owners separated, closure-plan anchors preserved, and full handoff gate passed. |
| ORG-33 | Mesa validation and MR state | Remote service is MR authority; W06 is dated cache; validation/review docs own conclusions; README routes. | Mesa README/docs, W06, status track 8, findings; preserve MR links. Security: upstream destination is public fact, but submission planning remains private. | CLOSED 2026-08-05 — router, accumulated validation, tip-pinned review, W06/status ownership, and full handoff gate complete. |
| ORG-34 | FFmpeg validation and branch state | Remote owns moving tip; build script owns intended package input; immutable comparison pins stay in source map; project docs own measured conclusions; status/W05 own verdict/publication. | FFmpeg README/docs/findings, W04/W05/W07/W21, status track 5, PPA installer/build/checker. Security: review public fix inventory versus private submission plan. | CLOSED 2026-08-05 — evidence scorecard, frozen audits/replays, mutable-state routing, and full handoff gate complete. |
| ORG-35 | GNOME Remote Desktop validation and branch state | Remote owns branch tip; build script owns package input; project docs own design/test conclusions; status/W05 own verdict/publication. | GRD README/docs/findings, status track 7, W05/W10, PPA and GRD pin checker. Security: review public fix inventory versus private submission plan. | CLOSED 2026-08-05 — application scorecard, compact front door, frozen replay, mutable-state routes, and full handoff gate complete. |
| ORG-40 | Project front doors, runbooks, plans, audits, and coverage | Each project README routes stable scope/boundary/model/operation; deep docs own mechanism; runbooks own commands; plans own future ladder; coverage owns scope/first missing evidence. | Activate one project/README at a time; preserve all headings/inbound links and nearest-README completeness. Security review when the project scope requires it. | CLOSED 2026-08-06 — taxonomy-defined project interfaces, packaging hub, operations, evidence routes, and compatibility headings handoff-gated. |
| ORG-41 | Findings inbox promotion | Existing project/runbook/test/catalog/package owners absorb useful evidence; findings index retains deposit guidance and views of live intake only. No tombstones or permanent `findings/evidence/` archive. | Exact inbound links, generated chronology, curated topic row/count, status citations; update findings checks atomically. Security review for every kernel safety/upstream finding. | ACTIVE 2026-08-05 — all 22 legacy promotion tombstones removed; owner-based live-intake review remains. |
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

### ORG-10 — dashboard and optional ledger

- **Row dispositions:** tracks 1/2 route to forward-port production, audit, and
  patch owners; 3 to DKMS; 4 to rewrite architecture/current findings; 5 to
  FFmpeg; 7 to GRD; 8 to Mesa; 10 to packaging/license; 11 to Kodi; 12 to boot
  firmware; 13 to maxline package/audit; 14 to VA-API/browser evidence; and 15
  to the PVTM plan and measured findings. No row contributes synthesis that
  cannot be expressed by those direct links.
- **Compatibility:** every maintained link to `docs/status-ledger.md` was
  repointed in the root router/owner table, status, work-package routes,
  findings trail, kernel runbooks/plans, RGA reconciliation, and VA-API plan.
  The stable `status.md#status-ledger` heading remains as a disposition and
  points to the normative optional-ledger rule.
- **Checker disposition:** the pilot already changed the track check so a
  missing ledger is valid, while any future ledger row must map to the same
  dashboard number/name and a present-but-unparseable ledger still fails.
- **Public/private review:** rows 1, 2, and 4 include kernel safety evidence,
  but this slice only changes routes. It imports no reproducer, disclosure/CVE
  material, submission destination/order, or private harness detail.
- **Validation:** exact-link search finds no maintained link to the retired
  file. The full `bash scripts/check-repo.sh` handoff gate passed on 2026-08-05
  across 435 Markdown files, 3,793 local links, 398 anchors, all 59 regression
  tests, ShellCheck, documentation consistency, and whitespace.

### ORG-11 — watchlist cache

- **Classification:** W01/W02/W06/W07/W10/W17/W18/W22/W24 survive as remote
  caches, W04/W05 survive as service caches, and W16/W20/W23 survive as board
  caches. No current item needs a host authority. W03/W08/W09/W11/W12/W13/
  W14/W15/W19/W21/W25 are retired because their contents are resolved or
  stable knowledge, repository-controlled work, or a package/project verdict
  already owned elsewhere.
- **Successor ownership:** W03 routes codec-udev policy to its package README;
  W08 routes FFmpeg results to track 5 and its evidence; W09 routes Kodi work
  to track 11 and the project runbook; W11 routes policy to `LICENSE.md` and
  track 10; W12 routes workspace state to `packaging/external-workspaces.md`
  and the contribution contract; W13 routes the paired RGA ABI to the librga
  P010/P210 contract and KASAN finding; W14 routes the builder boundary to the
  kernel-build owner and builder finding; W15 routes regeneration debt to the
  patch catalog, resync guide, and session-close finding; W19 routes the fixed
  MPP behavior to the public patch catalog and root-cause finding; W21 routes
  the FFmpeg backpressure fix to the fix catalog and validation finding; W25
  remains owned by the MPP architecture from ORG-01.
- **Live interface and compatibility:** every live index/detail pair keeps the
  same ID, name, and date and now declares `Authority`, `Recheck`, and
  `Freshness`. Retired details keep their stable `#watch-wNN` anchors and a
  dated disposition. Active front doors route directly to W13/W14 successor
  owners; dated findings may retain the retired anchors as useful historical
  compatibility routes.
- **Public/private review:** W19's public stub names only the affected behavior,
  guard, public patch/evidence owners, and validation boundary. The working
  memory-corruption reproducer remains private and is neither linked nor
  reproduced. W13/W15/W16/W21/W25 add no private harness, disclosure/CVE,
  upstream destination/order, or send/withhold material.
- **Checker disposition:** pairing remains strict for live items; live details
  additionally require a recognized remote/service/host/board authority plus
  non-empty recheck and freshness fields. Retired IDs continue to require a
  dated disposition without being reintroduced into the live index.
- **Validation:** exact-anchor search leaves only intentional dated-finding
  links to retired W13/W14/W19. The full `bash scripts/check-repo.sh` handoff
  gate passed on 2026-08-05 across 435 Markdown files, 3,781 local links, 387
  anchors, all 60 regression tests, ShellCheck, documentation consistency, and
  whitespace.

### ORG-20 / ORG-21 / ORG-34 — FFmpeg source and package slice

- **Owner map:** `packaging/ppa/build-source-packages.sh` is the sole owner of
  the intended `FFMPEG_REPO`/`FFMPEG_COMMIT`/`FFMPEG_UPSTREAM_VERSION` tuple;
  the leading Debian changelog entry identifies the packaging revision; W05
  owns the dated Launchpad result; `clean-install-system-stack.sh` consumes
  W05's exact Published version; the FFmpeg project owns mechanism/results;
  and status track 5 owns the next integration proof.
- **Actual artifact reconstruction:** Launchpad source publication `18658504`
  exposes signed `.dsc` SHA-256 `9c1288fb...cb04`, which authenticates orig
  SHA-256 `a5a7dfc4...24bd` and Debian-tar SHA-256 `a4009951...9561`.
  Successful arm64 build `33469512` retains `.buildinfo`, `.changes`,
  toolchain/dependency identities, and output hashes; binary publications
  `247812235`–`247812263` and the live index identify the Published result.
  Standard metadata answers the demonstrated identity question, so no custom
  manifest or committed payload was added.
- **Publication recheck:** the authoritative API reports source `18658504`
  Published, build `33469512` successful, and all 29 binaries Published. The
  Resolute arm64 `Packages.gz` selects the exact FFmpeg version and records deb
  SHA-256 `5b576200...72af3`. W05 and the installer were updated together;
  the package remains uninstalled and the GRD integration gate remains open.
- **Source-map and route disposition:** moving `main`, `ffmpeg-80`,
  `ffmpeg-81`, and normal-package rows were removed from `source-trees.md`.
  W07 owns remote heads, `rebase-notes.md` owns topology, the build script owns
  intended package input, the package record owns artifact reconstruction, and
  the dated lifetime finding owns focused evidence. Immutable NyanMisaka,
  Jellyfin, FFmpeg-tag, and publication-base comparison snapshots remain.
- **Checker migration:** the prior literal fan-out through the PPA README and
  newcomer guide is removed. The checker now independently verifies build
  commit↔upstream-version↔changelog identity and W05 published-version↔installer
  identity. A regression case rejects a build commit not encoded by its source
  version.
- **Public/private review:** the public project continues to expose affected
  behavior, patch identity, and bounded validation only. The provoking
  double-release harness, submission destination/order, send/withhold choices,
  and disclosure planning remain private; no private material was imported.
- **Validation:** the full `bash scripts/check-repo.sh` handoff gate passed on
  2026-08-05 across 435 Markdown files, 3,779 local links, 393 anchors, all 61
  regression tests, ShellCheck, documentation consistency, and whitespace.
  ORG-20/21/34 remain active only because their non-FFmpeg families and
  validation/history consolidation are separate later slices.

### ORG-20 / ORG-21 / ORG-22 / ORG-35 — GRD source and package slice

- **Owner map:** `packaging/ppa/build-source-packages.sh` solely owns the
  intended `GRD_REPO`/`GRD_COMMIT`/`GRD_UPSTREAM_VERSION` tuple; the leading
  changelog entry identifies the packaging revision; W10 owns moving release
  and recovery heads; W05 owns the dated Launchpad result;
  `clean-install-system-stack.sh` consumes W05's exact Published version; the
  GRD project owns release behavior/testing; and status track 7 owns the
  installed verdict and next proof.
- **Actual artifact reconstruction:** source publication `18654077` exposes
  signed `.dsc` SHA-256 `30caa255...ab25`, authenticating orig SHA-256
  `99b48a2f...cacc` and Debian-tar SHA-256 `710a3a3e...0f9f`. Successful arm64
  build `33461880` retains `.buildinfo`, `.changes`, toolchain/dependency
  identities, and output hashes; binary publication `247717203` and the live
  index identify the exact installed artifact. Standard metadata is sufficient,
  so no custom manifest or payload was added.
- **Routes and compatibility:** the exact intended pin was removed from the
  PPA source-input table, source map, external-workspace inventory,
  source-delta front door, GRD project front door, and superseded 50.1 patch
  front door. The build script now owns intent, W10 owns remote state, the PPA
  record owns artifact reconstruction, and the source-delta/patch documents
  retain only their historical reconstruction scopes. Stable paths and 50.1
  replay anchors remain unchanged.
- **Checker migration:** the four-document GRD commit fan-out is removed. The
  checker now verifies build commit/upstream version against the leading
  changelog independently from W05 Published version against the installer.
  Regression coverage rejects both source-pin drift and published-install-pin
  drift.
- **Technical-fix inventory:** `packaging/userspace-patches.md` no longer owns
  FFmpeg or GRD intended pins/package publication prose. It links the build,
  remote, artifact, and service owners while retaining the stable fork-versus-
  quilt maintenance policy and historical reconstruction warnings.
- **Public/private review:** public docs retain affected behavior, patch form,
  package dependencies, and validation boundaries. They add no submission
  destination/order, send/withhold choice, disclosure/CVE plan, private harness,
  or reproducer material.
- **Validation:** the full `bash scripts/check-repo.sh` handoff gate passed on
  2026-08-05 across 435 Markdown files, 3,802 local links, 407 anchors, all 62
  regression tests, ShellCheck, documentation consistency, and whitespace.
  ORG-20/21/22/35 remain active only for their other source/package families
  and the later GRD validation/history consolidation.

### ORG-20 — primary, userspace, and GRD source-map slice

- **Classification:** source-map sections 1–5 now retain only immutable
  documentation anchors, comparison snapshots, historical lineage required to
  interpret those pins, and replay recipes. All numbered section headings and
  stable paths remain in place.
- **Owner routing:** the root README owns current workspace layout; package
  scripts own DKMS and PPA intended inputs; the forward-port patch/package
  catalogs, W16, and status tracks 1–2 own moving kernel state; vendor-delta
  owns measured conclusions; PPA artifact records own exact MPP/GRD exports;
  VA-API and Firefox owners keep package/runtime state; W07/W10 own moving
  FFmpeg/GRD heads; the GRD patch archive owns unpinned experiment history.
- **Keep/link/promote/remove:** retained the two-patch primary reconstruction,
  audit parent, exact vendor comparison pair, immutable userspace study/design
  snapshots, GRD 50.1/reconnect/recorded experiment pins, and dirty-snapshot
  delta. Removed publication/build IDs, installed-runtime narratives, current
  branch/package claims, validation results, and the unpinned exp8–exp10
  chronology from the source map; those assertions remain available through
  the linked owners and findings.
- **Inbound compatibility:** sections 1–5 and their headings remain unchanged;
  the source map continues to resolve documentation line anchors. The first
  full-gate run identified one nonexistent inferred workspace link, which was
  corrected to the root README before handoff.
- **Public/private review:** kernel content remains limited to already-public
  source/fix identities and bounded reconstruction. No private reproducer,
  disclosure/CVE planning, submission destination/order, or send/withhold
  material moved into the public repository.
- **Validation:** the full `bash scripts/check-repo.sh` handoff gate passed on
  2026-08-05, covering Markdown links/anchors, all 62 regression tests,
  ShellCheck, documentation consistency, and whitespace. At this checkpoint,
  ORG-20 remained active for sections 6–14.

### ORG-20 — rewrite, conformance, and audit source-map slice

- **Classification:** sections 6–14 retain exact register/TRM identities,
  canonical uAPI locations, dated rewrite/base/backup/package-composite pins,
  the five-source conformance manifest, immutable AV1/Mesa/codec/maxline audit
  snapshots, and the commands or tracked patches needed to reconstruct them.
  Every numbered heading remains stable.
- **Owner routing:** the rewrite project owns feature and commit history,
  branch parity, source audits, packages, and runtime verdicts; status track 4
  owns its public boundary. The conformance manifest/bootstrap script owns
  third-party source intent, while the conformance runbook owns suites/results.
  The AV1, Mesa, driver-quality, maxline package, public-series manifest, and
  dated refresh finding retain their existing design, operation, artifact, and
  result responsibilities.
- **Keep/link/promote/remove:** replaced hundreds of lines of duplicated rewrite
  feature/KUnit chronology and conformance test inventory with compact dated
  pin tables and owner links. Removed moving-head wording, installed/package
  results, future priorities, and subsystem-acceptance narrative. Kept the
  historical Armbian composites because they are otherwise-needed package
  reconstruction inputs, explicitly labeled as non-current evidence.
- **Inbound compatibility:** the source map's stable path and all 14 numbered
  headings survive. The repository link/anchor checker resolves every inbound
  route; line-number documentation continues to reconstruct through the exact
  primary/audit pins rather than through moving branch claims.
- **Public/private review:** the compact map retains public commit and patch
  identities only. It drops the old mention of the private security-runner
  migration and adds no private harness, hostile reproducer, disclosure/CVE
  coordination, submission destination/order, or send/withhold material.
- **Validation:** the full `bash scripts/check-repo.sh` handoff gate passed on
  2026-08-05, covering Markdown links/anchors, all 62 regression tests,
  ShellCheck, documentation consistency, and whitespace. ORG-20 is closed.

### ORG-30 — rewrite validation router and frozen-audit slice

- **Owner map:** `rewrite-validation-plan.md` is the single strategic plan and
  definition-of-done entry; `tests/rewrite-conformance.md` is the rewrite
  operational entry and delegates generic kernel work to
  `kernel-validation-runbook.md`; `rewrite-drivers.md` owns accumulated
  qualification evidence; status track 4 owns the public verdict/next proof;
  findings remain fresh-run intake. `validation-index.md` now routes among
  those owners without copying their state.
- **Audit disposition:** `rewrite-conformance-gap-audit.md` is explicitly
  frozen as the 2026-07-17 inspection plus its bounded 2026-07-22/23
  dispositions. Moving 2026-08-04 source-tip/build prose was removed; its
  still-useful proof-gap reasoning and gate origins remain, with current
  disposition routed to the plan, operational entry, project evidence, and
  status.
- **Plan disposition:** the validation index's non-qualification cleanup list
  was reduced to three still-useful maintenance items and moved under a scoped
  §8 child backlog in the canonical plan. Already-completed documentation and
  stale-reference tasks were not preserved as work chronology. The child scope
  explicitly cannot reorder or satisfy production gates.
- **Inbound compatibility:** the stable index/audit paths and every existing H2
  heading remain. The kernel-driver front door now describes the index as a
  router and the audit as frozen; `CONTRIBUTING.md` routes the private-security
  prerequisite by evidence class rather than a removed matrix row.
- **Public/private review:** the public router names only the sibling private
  repository and the scope controlled by `CONTRIBUTING.md`. No working hostile
  trigger, destructive PoC, severity/disclosure framing, destination/order,
  or send/withhold material moved into this repository.
- **Validation:** the full `bash scripts/check-repo.sh` handoff gate passed on
  2026-08-05, covering Markdown links/anchors, all 62 regression tests,
  ShellCheck, documentation consistency, and whitespace. ORG-30 remains active
  for removal of dated state and duplicated qualification chronology from the
  teaching architecture guide.

### ORG-30 — rewrite architecture teaching-boundary slice

- **Classification:** the chaptered rewrite architecture guide owns stable
  object, ABI, source-reading, observability, evidence-level, and target-design
  explanation. It no longer owns source/package identity, KUnit counts, dated
  build/boot results, the immediate next gate, or the production verdict.
- **Owner routing:** status track 4 owns the public boundary and next proof;
  `rewrite-drivers.md` §6 owns accumulated exact evidence; `source-trees.md`
  §8 owns immutable citation snapshots; `rewrite-kunit-manifest.tsv` owns the
  exact ordered case contract; the validation plan and conformance entry own
  strategy and operations. The architecture front door names each route near
  the top.
- **Keep/link/promote/remove:** retained the practical driver scope, as-built
  versus target object model, source paths/order, counter semantics, evidence
  ladder, and the warning that KUnit cannot prove hardware behavior. Removed
  moving branch tips, package/build history, copied case/signal counts,
  predecessor runtime narrative, and the dated successor-package milestone.
  Converted date-labeled implementation prose to stable ownership rules.
- **Inbound compatibility:** the forwarding path, chapter directory, all H2/H3
  headings, chapter sequence, glossary route, and source-reading anchors remain
  intact. The front door and forwarding stub now describe maintained status
  routes rather than promising an embedded current-status ledger.
- **Public/private review:** architecture safety content remains invariant-level
  and links public validation roles. No private trigger, hostile reproducer,
  disclosure/CVE plan, submission destination/order, or send/withhold material
  was added.
- **Validation:** the full `bash scripts/check-repo.sh` handoff gate passed on
  2026-08-05, covering Markdown links/anchors, all 62 regression tests,
  ShellCheck, documentation consistency, and whitespace. ORG-30 is closed.

### ORG-31 — forward-port state and evidence slice

- **Owner map:** `patches/forward-port-rk3588/README.md` owns mechanical order
  and immutable checked-in export identity; `patch-catalog.md` owns public fix
  provenance, BSP presence, backport disposition, and bounded per-fix gate
  classification; `forward-port-status.md` owns accumulated capability
  evidence; status tracks 1–2 own the live public boundary/next proofs; W16
  owns moving branch/package observation; findings remain fresh run detail.
- **Scorecard disposition:** replaced the 491-line mixed current-status/run
  diary with a 153-line capability scorecard, one frozen 2026-08-04 release
  boundary, a compact milestone table, durable done/deferred/limitation
  classifications, and an evidence-completeness contract. Every prior H2
  heading remains as either maintained content or an explicit dated
  compatibility anchor.
- **Patch-front-door disposition:** removed source publication, installed boot,
  runtime matrix, and open-gate rollups from both patch front doors. The top
  patch README now routes deliverable/order, provenance, evidence, and live
  state separately. The series README retains patch mechanics and immutable
  export/renumber history while linking dated validation owners.
- **Catalog disposition:** removed the competing publication/install rollup and
  correction diary. Retained exact public affected behavior, patch identity,
  BSP evidence, backport classification, and bounded validation only when it
  changes backport readiness. The dated `Current 0072–0092` heading remains as
  a compatibility anchor and explicitly disclaims moving-tip ownership.
- **Inbound compatibility:** stable paths and all scorecard/series/catalog
  headings remain. Kernel, packaging, install, status, and validation front
  doors now call the document a capability/evidence scorecard rather than a
  build-history or live-state ledger. The existing contiguous-series
  regression assertion remains owned by the mechanical README.
- **Public/private review:** public docs retain affected behavior, patch title,
  provenance/backport facts, and bounded safety evidence. Working hostile
  triggers, destructive/memory-corruption reproducers, severity/disclosure
  framing, submission destination/order, and send/withhold decisions remain in
  the sibling private repository; no private link or material was added.
- **Validation:** after restoring the regression-owned contiguous-series phrase,
  the full `bash scripts/check-repo.sh` handoff gate passed on 2026-08-05,
  covering Markdown links/anchors, all 62 regression tests, ShellCheck,
  documentation consistency, and whitespace. ORG-31 is closed.

### ORG-21 — PPA topology, mechanics, and recovery

- **Disposition:** the sole 2,471-line history file mixed routine upload
  chronology, publication polls, current-state summaries, package validation,
  and two material incidents. Current artifact identities route to standard
  Debian/Launchpad metadata; package results route to project/package owners;
  W05 owns service state; routine chronology is removed.
- **Promoted operations:** the PPA front door now owns one sign/upload/recovery
  entry point: signature and checksum verification, `.dsc` extraction, the
  client-transfer versus service-publication boundary, byte-identical orig
  reuse, safe `dput --force`, dependency-wave waits, failed-build log capture,
  and the preconditions for deliberate archive recreation.
- **Retained incident evidence:** the stable history path now contains a frozen
  dated audit of only (1) the librga/MPP non-deterministic-orig rejection, with
  accepted/rebuilt hashes and recovery, and (2) the ABI-driven six-archive
  split, holding-copy boundary, 46-minute name-reuse delay, restoration order,
  and archive-dependency cleanup. Git history preserves forensic chronology.
- **Front-door disposition:** the PPA README now owns stable archive roles,
  co-installability, build-dependency waves, source-package mechanics, signing,
  upload, reconstruction method, and recovery. It no longer presents package
  pins, publication IDs, validation chronology, or a timeless live matrix.
- **Identity boundaries:** executable assignments in
  `build-source-packages.sh` are the intended-input owner; signed `.dsc`,
  `.changes`, `.buildinfo`, and output hashes identify actual artifacts;
  Launchpad is the service authority; W05 is the dated cache; project evidence
  owners qualify runtime behavior. The MPP, FFmpeg, and GRD reconstruction
  anchors remain as method routes without copying live service records.
- **Package notes:** retained durable Plymouth quilt mechanics, codec access,
  MPP repacking, librga SONAME/kernel pairing, FFmpeg ABI separation, private
  FFmpeg-tool co-installability, clean GRD export, and opt-in GDM ACL policy.
  Package-specific behavior and validation route to their project owners.
- **Routes:** the PPA/history front doors and packaging hub describe the compact
  role. The forward-port package keeps its exact kernel transitions locally and
  links the incident record only for cross-package recovery decisions. FFmpeg
  baseline recovery remains in its package README.
- **Public/private review:** this slice changes public package operations and
  dated service incidents only. It contains no fix-submission destination/order,
  send/withhold choice, disclosure/CVE coordination, private harness, or
  memory-corruption reproducer.
- **Validation:** the completed slice preserves every prior H2/H3 heading and
  explicit reconstruction anchor. The full `bash scripts/check-repo.sh`
  handoff gate passed on 2026-08-05 across 437 Markdown files, 3,758 local
  links, 450 anchors, all 62 regression tests, ShellCheck, documentation
  consistency, and whitespace.

### ORG-22 — userspace delta policy and technical catalogs

- **Owner map:** `packaging/userspace-patches.md` owns fork-versus-quilt policy,
  patch-addition procedure, and cross-component maintenance traps. The source
  build helper owns intended tuples; signed package metadata owns artifacts;
  W05 owns publication observations; MPP, RGA, FFmpeg, GRD, VA-API, and package
  catalogs own behavior, public provenance, dependencies, and validation.
- **Map disposition:** removed source-tree paths presented as package truth,
  mutable branch counts, literal pins and versions, PPA columns, publication
  IDs, validation claims, and the copied MPP/GRD fix inventories. The compact
  matrix now names only delta form and the responsible executable or project
  owner.
- **Durable procedure:** retained the rule against mixing fork and quilt,
  byte-identical orig reuse, tuple updates, archive-content verification,
  sequential quilt application, fork/vendor-mirror separation, librga/kernel
  pairing, differing MPP bases, and external task-build placement.
- **Compatibility:** every original H2/H3 route remains; the former MPP count
  heading has an explicit successor anchor. The packaging hub now describes
  policy and traps instead of advertising duplicated pins and PPA state.
- **Public/private review:** the public map permits affected behavior, patch
  identity/provenance, dependencies, and validation in project catalogs. It
  explicitly excludes submission destination/order, send/withhold choices,
  disclosure coordination, and working memory-corruption reproducers. No
  private repository path or material was added.
- **Validation:** the full `bash scripts/check-repo.sh` handoff gate passed on
  2026-08-05 across 437 Markdown files, 3,767 local links, 450 anchors, all 62
  regression tests, ShellCheck, documentation consistency, and whitespace.

### ORG-32 — VA-API policy, mechanism, and application route

- **Owner map:** `video-libraries/vaapi/README.md` owns durable exposure and
  capability walls; `docs/architecture.md` owns object, memory, decode/encode,
  sandbox, failure, and validation mechanism; `docs/app-enablement.md` owns
  consumer contract fit and ordering; status track 14 owns the dated
  installed/browser verdict and next proof; W05/W18 own publication and
  moving-fork observations.
- **Front-door disposition:** removed release/package chronology, exact build
  and payload identities, browser-version observations, duplicated application
  results, and the competing next-gate list. Retained default/opt-in/
  unadvertised policy, permanent backend walls, the narrow-width decision,
  artifact-identity warning, sandbox boundary, and evidence routes.
- **Architecture disposition:** retained immutable source pins and all
  mechanism, ownership, failure-policy, and debugging content. Replaced the
  dated application-result table and open-gate matrix with stable interface
  contracts and canonical-owner routing.
- **Application-map disposition:** converted versioned package/runtime results
  into durable per-consumer compatibility and first-discriminator statements.
  The map retains every H2/H3 anchor, source-contract rationale, and
  consumer-specific sequencing while routing the moving browser/package
  result to status.
- **Superseded-plan compatibility:** the narrow 10-bit plan keeps every
  original H2/H3 anchor. Its declined VA-API workstream is a frozen decision
  stub; its independent librga workstream routes to the existing detailed
  librga plan rather than remaining duplicate active work.
- **Evidence disposition:** dated findings remain intake for the later ORG-41
  promotion batches; this slice promoted their stable capability, ownership,
  and consumer conclusions without deleting evidence prematurely.
- **Public/private review:** no kernel safety, hostile reproducer, disclosure,
  CVE, submission destination/order, or send/withhold material entered this
  slice. The public DMA-BUF kernel precondition remains a compatibility route;
  no memory-corruption trigger was copied.
- **Validation:** the full `bash scripts/check-repo.sh` handoff gate passed on
  2026-08-05 before ledger closure, covering 435 Markdown files, 3,749 local
  links, 428 anchors, all 62 regression tests, ShellCheck, documentation
  consistency, and whitespace.

### ORG-33 — Mesa validation and MR-state route

- **Owner map:** GitLab is authoritative for MR records; W06 is the only dated
  cache of heads, mergeability, review, and selected CI; status track 8 owns
  the public verdict/next proof; `validation.md` owns accumulated correctness,
  performance, build, CI-classification, and workaround evidence;
  `mr-review-findings.md` owns conclusions at immutable reviewed tips;
  `blit-precision.md` owns the causal model.
- **Front-door disposition:** replaced the open-MR table and 28-row
  force-push/experiment diary with a compact project router, a stable mechanism
  summary, evidence-owner map, and durable facts. The explicit `#mr-status`
  compatibility route remains and sends live-state readers to W06.
- **Validation disposition:** preserved all prior H2/H3 anchors while
  compacting superseded candidate history and repeated run prose into
  discriminating evidence tables, negative controls, CI root-cause
  classification, invocation/build boundaries, and a promoted depth-bias
  workaround/benchmark conclusion.
- **Review disposition:** the detailed public code review remains at its
  immutable four tips. Its introduction and verdict no longer claim current
  CI state or schedule a next force-push; W06 owns later remote state.
- **Status route:** track 8's unchanged next proof now links directly to W06,
  so it cannot be mistaken for a project-README MR cache.
- **Evidence disposition:** the stable conclusions from the July erratum,
  geometry, and benchmark findings are promoted into the validation owner.
  Intake files remain for the later ORG-41 owner-based deletion batch.
- **Public/private review:** public MR URLs, reviewed code behavior, proposed
  technical fixes, and validation conclusions remain public engineering facts.
  No private submission destination/order, send/withhold decision,
  disclosure/CVE coordination, or hostile reproducer was added.
- **Validation:** the full `bash scripts/check-repo.sh` gate passed before
  ledger closure on 2026-08-05 across 435 Markdown files, 3,737 local links,
  434 anchors, all 62 regression tests, ShellCheck, documentation consistency,
  and whitespace.

### ORG-34 — FFmpeg accumulated validation and branch-state route

- **Owner map:** `docs/validation.md` now owns the evidence ladder and
  accumulated conclusions; W04 owns Ubuntu version drift, W07 moving branch
  heads/evidence invalidation, W05 publication, the package build script
  intended input, status track 5 the public verdict/next proof, and the
  asynchronous-frame finding the current focused hardware/application gate.
- **Scorecard:** distinguishes source replay, compile/source, registration,
  focused hardware, package-artifact, installed-runtime, and application
  evidence. It records immutable evidence points and durable failure classes
  without repeating live branch/package state.
- **Front-door disposition:** removed the literal current-state row and the
  duplicate rolling-branch/PPA verdict. Retained source roles, historical build
  recipe, file ownership, package-input route, and the warning that branch
  results require W07 freshness.
- **Audit disposition:** `rockchip81-package-validation.md` remains a frozen
  2026-07-06 measured audit with all original H2 anchors. Its former next-step
  section is now a successor route rather than a stale current blocker.
- **Replay/comparison disposition:** immutable three-line pins and source
  conclusions remain; “latest/current publication” wording and package
  rollups were replaced by W07, W05, build-input, scorecard, and status routes.
- **Evidence disposition:** dated FFmpeg findings remain intake for later
  ORG-41 batches. The scorecard promotes their durable evidence classes and
  conclusions without prematurely deleting exact run records.
- **Public/private review:** the public fix series retains behavior, patch
  identity, and validation. No submission destination/order, send/withhold
  decision, disclosure/CVE coordination, or hostile reproducer moved from the
  private repository.
- **Validation:** after correcting one generated Markdown anchor, the full
  `bash scripts/check-repo.sh` handoff gate passed on 2026-08-05 across 436
  Markdown files, 3,771 local links, 449 anchors, all 62 regression tests,
  ShellCheck, documentation consistency, and whitespace.

### ORG-35 — GRD application validation and branch-state route

- **Owner map:** `docs/validation.md` owns accumulated application
  conclusions and failure classification; design/capture docs own mechanism;
  profiling owns dated measurements; testing owns safe operations; the build
  script owns intended package source; W10 owns branch heads, W05 publication,
  and status track 7 the installed verdict/next proof.
- **Front-door disposition:** replaced a 406-line mixed runtime/status and
  investigation narrative with a compact integration model, evidence router,
  durable four-issue lessons, patch/package roles, and provenance. Every prior
  H2/H3 heading remains at the same stable path.
- **Scorecard:** separates build, smoke, live-RDP, sustained-session,
  installed-stack, and recovery/handover evidence. It promotes capability
  conclusions for hardware encode, panvk conversion, throughput/quality, IDR,
  backpressure, greeter ACL, cached readback, and frame-ACK recovery.
- **Design correction:** replaced the stale “VA-API may become a comparison
  gate” statement with the maintained packed-slice-header incompatibility:
  GRD authors headers that MPP cannot accept or splice safely.
- **Run/patch disposition:** profiling and testing explicitly identify dated
  evidence versus operation; audio identifies its archived probe boundary.
  The 50.1 patch README is mechanical reconstruction material and routes the
  package source/head to the build input and W10.
- **Evidence disposition:** exact GRD run findings remain intake for later
  ORG-41 owner batches. Stable conclusions are already promoted without
  deleting run-level evidence prematurely.
- **Public/private review:** public behavior, patch identities, architecture,
  and validation remain. No private upstream destination/order,
  send/withhold decision, disclosure/CVE coordination, or hostile reproducer
  entered the public tree.
- **Validation:** the full `bash scripts/check-repo.sh` gate passed before
  ledger closure on 2026-08-05 across 437 Markdown files, 3,783 local links,
  453 anchors, all 62 regression tests, ShellCheck, documentation consistency,
  and whitespace.

### ORG-40 — project front doors and document interfaces

- **Audit scope:** reviewed the taxonomy-defined boot, kernel-base,
  kernel-driver, MPP, IEP2, RGA, AV1, IOMMU, RKNPU, vendor-library, libmpp,
  librga, FFmpeg, VA-API, Mesa, GRD, Kodi, and packaging front doors. Category
  hubs remain indexes; test, script, patch, and package subdirectories keep
  their operational roles rather than imitating projects.
- **Interface normalization:** project briefs now use stable evidence-boundary
  routes instead of copied “current state” pins, counts, package matrices, or
  dated verdicts. `docs/work-packages.md` names that contract and owns the
  detailed re-entry paths.
- **Focused rewrites:** IEP2 now routes hardware/source model, safety evidence,
  runnable tests, and public status separately. Kodi now separates decoder
  mechanism, build/run operation, and status. Both retain every prior H2 route.
- **Packaging disposition:** the deploy front door no longer embeds a mutable
  FFmpeg ABI hold/downgrade recipe or chronological package diary. Stable
  channel exclusions, recovery routes, artifact policy, and design lessons
  remain; PPA support/install helpers own current operations. Every former
  H2/H3 anchor remains as a useful compatibility route.
- **Plans, audits, and coverage:** the shared interfaces and the earlier
  rewrite/forward-port/VA-API/Mesa/FFmpeg/GRD slices already separate live plans,
  frozen audits, operations, and accumulated evidence. Support coverage remains
  the sole whole-board scope/first-missing-evidence inventory.
- **Public/private review:** kernel and userspace front doors now route public
  technical behavior and qualification only. No working hostile or
  memory-corruption reproducer, disclosure/CVE coordination, upstream
  destination/order, send/withhold decision, or private repository path was
  added.
- **Validation:** the full `bash scripts/check-repo.sh` handoff gate passed on
  2026-08-06 across 415 Markdown files, 3,632 local links, 442 anchors, all 62
  regression tests, ShellCheck, documentation consistency, and whitespace.

### ORG-41 — findings promotion batches

#### Legacy promotion-tombstone batch

- **Disposition:** removed all 22 findings that had already been reduced to a
  `promoted →` stub. Their durable content was already owned by RGA, MPP,
  FFmpeg, Mesa, boot firmware, maxline, GRD, VA-API, and IEP2 maintained docs.
- **Inbound routes:** repointed the remaining RGA import/consumer, RCB/SRAM,
  FFmpeg package, GRD audio, and IEP2 callers to those durable owners before
  deletion. Findings that referenced the retired stubs now link to the same
  maintained evidence directly.
- **Hub contract:** `findings/README.md` now requires promotion, inbound-route
  migration, deletion, and index regeneration in one change. It forbids
  tombstones and permanent curated chronology, and routes historical evolution
  to project owners plus Git history.
- **Public/private review:** several removed stubs concerned kernel lifetime,
  DMA/IOMMU, and driver audit material. This batch adds no trigger, exploit,
  disclosure/CVE framing, upstream destination/order, send/withhold decision,
  private harness, or private repository route; it only redirects public
  technical links to already-maintained public explanations.
- **Validation:** the regenerated live-inbox index contains 165 findings and no
  `promoted →` stub. The full `bash scripts/check-repo.sh` gate passed on
  2026-08-05 across 415 Markdown files, 3,643 local links, 448 anchors, all 62
  regression tests, ShellCheck, documentation consistency, and whitespace.

#### Mesa/Panfrost owner batch

- **Promotion:** moved the remaining unique benchmark machine controls and
  cleanup commands into `mesa/reproducers/README.md`. The causal model,
  geometry counterexamples, NIR implementation, corrected benchmark result,
  trust, and negative boundaries were already owned by `blit-precision.md`,
  `fix-walkthrough.md`, and `validation.md`; links now stay within those owners.
- **Removal:** deleted the eight Mesa/Mali intake files covering NIR migration,
  uncached readback, the varying erratum, geometry/size matrices, benchmark
  plan, first result, and timing correction. The topic group disappears rather
  than becoming project history; the generated chronology was regenerated.
- **Identity and operation:** `source-trees.md` retains the immutable benchmark
  tips, the validation scorecard retains exact measured signals and scope, and
  the reproducer front door retains the byte-identical A/B, fixed-clock,
  control, rejection, and raw-output contract.
- **Public/private review:** this userspace/GPU batch contains public MR,
  erratum, source, and measurement facts only. It adds no private submission
  plan, send/withhold decision, disclosure coordination, or kernel-security
  reproducer.
- **Validation:** the full `bash scripts/check-repo.sh` handoff gate passed on
  2026-08-06 across 407 Markdown files, 3,588 local links, 451 anchors, all 62
  regression tests, ShellCheck, documentation consistency, and whitespace.

#### FFmpeg/MPP/Kodi owner batch

- **Promotion:** moved the two fixed HEVC parser/HAL cases into the libmpp
  architecture owner, the unused-following-reference and historical package
  proofs into the FFmpeg validation scorecard, the frei0r FATE proof into the
  baseline package README, and the three frozen Debian corrections into the
  PPA reconstruction guide. Kodi's decoder analysis and build runbook retain
  decoder selection, AV1 extradata behavior, and the pending playback gate.
- **Removal:** deleted the four mature 2026-07-09, 2026-07-11, 2026-07-27, and
  2026-07-29 intake files. The curated topic group now contains only the live
  2026-07-30 asynchronous-frame-lifetime investigation; the generated
  chronology was regenerated and every maintained inbound route was repointed.
- **Evidence boundary:** immutable commits, package correction mechanisms,
  exact focused frame/test signals, trust, and negative boundaries remain in
  maintained project/package docs. Current branch, publication, installed
  state, consumer playback, and broader conformance remain with W05/W07,
  `status.md`, Kodi's runbook, or the surviving live finding as appropriate.
- **Public/private review:** this batch retains public codec conformance,
  parser/HAL behavior, build, and application-integration evidence. It adds no
  memory-corruption trigger, private harness, disclosure/CVE coordination,
  upstream destination/order, or send/withhold decision.
- **Validation:** the full `bash scripts/check-repo.sh` handoff gate passed on
  2026-08-06 across 403 Markdown files, 3,583 local links, 457 anchors, all 62
  regression tests, ShellCheck, documentation consistency, and whitespace.

#### GNOME Remote Desktop owner batch

- **Classification:** retained the 2026-07-29 authenticated reconnect finding
  and 2026-08-01 watchdog/forced-IDR/VBR finding because status track 7 names
  their exact unrun gates. The other ten files were completed diagnostics,
  superseded experiments, or policy analyses with established durable owners.
- **Promotion:** the GRD scorecard now owns fixed-QP transport pressure and
  full-range BT.709 conclusions with trust boundaries; profiling owns cached
  readback, driver exclusion, MPP input backpressure, and the FFmpeg retry;
  testing owns focus/ACK recovery, false idle charging, wake-watch versus
  handover diagnosis, clean package activation, and TLS-path safety. The VA-API
  front door owns the packed-slice-header refusal policy.
- **Evidence and routes:** the retained full-range bundle moved from the intake
  archive into `apps/gnome-remote-desktop/evidence/` and links directly to the
  promoted scorecard result. The two live findings, TCP Reno finding, and every
  project caller were repointed before deletion; the curated GRD group and
  generated chronology were regenerated around the two live owners.
- **Removal:** deleted ten dated intake files spanning 2026-07-18 through
  2026-08-04: starvation diagnostics, userspace encoder wedge and backpressure,
  two focus/resume diagnoses, two color experiments, the wake-watch diagnosis,
  transport pressure, and the GRD/VA-API packed-header assessment.
- **Public/private review:** this batch retains public application, codec,
  protocol, package, and network behavior. It adds no memory-corruption
  trigger, private harness, disclosure/CVE coordination, upstream
  destination/order, or send/withhold decision.
- **Validation:** the full `bash scripts/check-repo.sh` handoff gate passed on
  2026-08-06 across 393 Markdown files, 3,547 local links, 471 anchors, all 62
  regression tests, ShellCheck, documentation consistency, and whitespace.
