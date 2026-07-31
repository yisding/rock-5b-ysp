# First fully green rewrite KUnit boot failed the gate: four harness defects, zero kernel defects

> Scope: `rewrite-kunit-log-check.sh`, `rewrite-kunit-manifest.tsv`,
> `rewrite-evidence-audit.sh`; booted kernel `eb78ceed2fd67`
> (6.18.40-video-rewrite-kasan, package 26.08.0-trunk)
> Evidence: `rock-5b/rockchip-conformance/logs/rewrite/20260730-070115-*`
> Date: 2026-07-30
> Trust: MEASURED (boot artifacts, journal, manifest hashes) +
> SOURCE-VERIFIED (KUNIT_CASE arrays at the booted pin) + FIXED
> (selftests green; on-board rerun of the gate step still pending)

## Result

The 07:01 conformance run on the soft-CCU-fixed kernel produced the first
**fully green** rewrite KUnit boot — `pass:89 fail:0 skip:0` MPP plus
`pass:148 fail:0 skip:0` RGA, `ok 1`/`ok 2` suite summaries, live lockdep,
and a boot interval whose only non-KTAP lines were USB hotplug noise — and
the gate still reported both suites `fail` with `result_cases 0`, four
fatal lines, and `lockdep-disabled`. Every failure was the harness's own:

1. **KTAP parser required a `- ` separator KUnit never emits.** Commit
   `701d2e7` tightened the case-line regex from `ok N ` to `ok N - `; the
   kernel's KUnit runner prints `    ok 1 case_name` with no dash (the
   KTAP spec makes it optional). Zero cases parsed, and the ordered-name
   hash became the empty-file SHA-256 (`e3b0c442…`). The selftest passed
   because its fixtures were written in the dash form — the fixture
   modeled the spec, not the kernel.
2. **Stale 84-case manifest.** The manifest hash `19262f86…` matches the
   `KUNIT_CASE` array exactly at pre-phase pin `669697f23d3df`; the booted
   kernel plans 89 because `1115e0c89c8ff` (AV1 rewrite backend) added
   `rk_mpp_av1_{reg_layout,lazy_regions,dynamic_metadata,
   post_offset_provenance,afbc_config}_kunit` at ordinals 13–17 without
   the paired YSP manifest bump the rationalization plan's commit
   strategy requires. Booted KTAP order, source array, and the build
   gate's derivation all agree on 89 + `e9efee58…`.
3. **Fatal regex matched passing test names.** The shared
   fatal-signature regex treats `_` as a token separator, so the
   `iommu[^[:alnum:]]*…fault` and `rga…fault` clauses fired on the KTAP
   rows of four *passing* cases (`rk_mpp_iommu_fault_generation_kunit`
   etc.). Any fault-handling coverage added to the suites would keep
   re-triggering it.
4. **Lockdep gate read a sysctl that does not exist.** The check
   defaulted `KUNIT_DEBUG_LOCKS_FILE` to `/proc/sys/kernel/debug_locks`;
   mainline exposes `debug_locks` only as a row of `/proc/lockdep_stats`.
   With the file unreadable the gate reported `lockdep-disabled` on a
   boot whose lockdep was alive — the selftest again passed against a
   bare-`0/1` fixture file that nothing real produces.

A fifth, latent half of the same story: `rewrite-evidence-audit.sh` still
required the *release string* to embed `-g<sha12>`, which `8877e45`
(gsha moved to `uname -v` because Armbian's deb packaging hard-fails on
`LOCALVERSION` divergence) made permanently unsatisfiable — the audit
would have rejected every future green report.

## Fixes (this repository, same day)

- Parser accepts the real `ok N name` form (dash optional), keeping the
  ordinal/duplicate/manifest-hash checks; selftest fixtures now use the
  kernel's actual no-dash output, plus a dash-tolerance case.
- Manifest and both suite specs regenerated at the booted pin: 89 MPP
  (`e9efee58…`) + 148 RGA (unchanged `251a8183…`).
- Fatal scan filters KTAP-formatted lines (version/plan/result/`# `
  diagnostics) before applying the shared regex; real KASAN/BUG/WARNING/
  lockdep reports never render as KTAP rows. Selftest asserts an
  `iommu_fault`-named passing case cannot trip the gate.
- Lockdep state defaults to `/proc/lockdep_stats` and parses both the
  `debug_locks:` row and bare fixture files; selftest covers both
  formats in both polarities.
- The dmesg-scan report now records `kernel_version`, and the evidence
  audit binds the source commit against release *or* version
  (`-g<sha>` / ` g<sha>`), with selftests for both binding paths.
- Current-gate docs moved from 84/148 (232) to 89/148 (237); historical
  84- and 85-era statements left as recorded.

## Process gap worth keeping visible

The gate did its job in the wrong direction twice for the same reason:
selftest fixtures were derived from the checker's own assumptions rather
than from captured kernel output. Both regressions (dash form, bare
`debug_locks` file) were invisible to green selftests. Fixtures that
gate real artifacts should be generated from a real boot's artifacts at
least once per format they claim to model.

## Boundary

The fixed gate has not yet re-run on the board: the 07:21 rerun skipped
the KUnit step (`RUN_KUNIT_CHECK=0`) and then hard-wedged at
`mpi_dec_h265` — the soft-CCU wedge family, one case past the fixed
`mpi_dec_mt_h264` ([7/29 finding](2026-07-29-rewrite-soft-ccu-dual-core-wedge.md));
that investigation is open and separate. The five AV1 cases are blessed
on source+boot agreement at `eb78ceed2fd67`; if a later rationalization
phase retires or parameterizes cases, the manifest regenerates from the
registered source arrays per the plan's Phase 6 contract.
