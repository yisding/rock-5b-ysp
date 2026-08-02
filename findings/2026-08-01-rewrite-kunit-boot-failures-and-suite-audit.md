# The two RGA KUnit boot failures were fixture lag; a full-suite audit tightened three more cases and pruned three

> Scope: rewrite drivers' KUnit suites (mpp-rewrite + rga-rewrite), both kernel branches
> Source: `linux-6.18-rkvenc` @ `8042f13c54591` (mirror `linux` @ `94e9ad41a19a2`); boot log of `6.18.41-video-rewrite-kasan-rockchip64` #28, 2026-08-01 20:44
> Date: 2026-08-01
> Trust: MEASURED (boot KTAP), SOURCE-INSPECTED, ROOT-CAUSED, FIX-COMPILE-VERIFIED — booted rerun still pending

## Result

Boot #28 ran `rk_mpp_rewrite` 90/90 green and `rockchip-rga-rewrite` 150/152.
Both failures were test bugs, not driver defects:

1. **`rk_rga2_validator_chain_exclusions_kunit`** (alpha-bitmap+OSD leg,
   added the same day in the profile-bits commit) expected `-EOPNOTSUPP`
   from the OSD exclusion in `rk_rga2_validate_alpha_bitmap()`, but the
   fixture never gave `task.pat` an address, so the validator's earlier
   `rk_rga_img_has_addr()` check returned `-EINVAL` first. The scenario had
   never passed. Fixed by building the emit test's *accepted* alpha-bitmap
   task (pat image, `bsfilter_flag`, supported alpha flags, `DST_OVER`),
   asserting acceptance, then flipping only `osd_info.enable` — the
   rejection is now attributable to the exclusion under test.
2. **`rk_rga_dma_mapping_hw_lifetime_kunit`** still built a DMA-BUF import
   with a persistent `map_hw`, a state the 2026-07-31 multi-SG rework
   removed (only userptr imports hold one now).
   `rk_rga_import_detach_map_locked()` treats that shape as can't-happen:
   `WARN_ON_ONCE`, clear `map_hw`, and deliberately keep the hw
   reference — so both refcount expectations failed, and the second was a
   cascade of the first. **The WARN splat in that boot's log was this
   fixture tripping the guard, not a driver bug.** Fixed by typing the
   fixture `RK_RGA_IMPORT_USERPTR` with a NULL sgt, so detach skips the
   DMA unmap and the test observes exactly the reference drop.

A six-agent audit then traced all 242 cases to the production checks they
claim to pin (errno provenance for every negative assertion; fixture
contracts against the recent reworks; subsumption between siblings). It
found three more cases whose target regression could no longer fail them
— `rk_mpp_av1_afbc_config_kunit`'s truncated-image case (inherited a
zeroed PP-config word, so the bounds gate wasn't load-bearing),
`rk_rga_timeout_target_replacement_kunit`'s first scenario (zero
watchdog generation, unreachable from dispatch, masked the pointer
guard), and `rk_rga_ffmpeg_fbc_profiles_kunit` (seven rejections all
firing the same `rk_rga3_hw_rd_mode()` gate before any varied field was
read) — and three cases fully subsumed by stronger siblings
(`rk_rga2_fill_multitask_hw_type_kunit`,
`rk_rga_dmabuf_public_provenance_kunit`,
`rk_mpp_session_abort_hw_active_kunit`). The weak cases were tightened
and the duplicates removed on both branches.

The ordered manifest is now **89 MPP + 150 RGA (239 cases)**;
`rewrite-kunit-manifest.tsv` was regenerated and the fixture-debt
baseline refreshed (305 signals, 0 new). Kernel commits: fixes
`db09af2111768`, tighten/prune `8042f13c54591` (6.18); mirrors
`d786134f28f33` / `94e9ad41a19a2` (mainline). Both objects compile
warning-free in-tree.

## Boundary

- Compile-verified only: the corrected suites have not yet run on a
  booted kernel. Nothing here is hardware evidence.
- The audit verified errno provenance per case in one reviewer pass per
  slice; a wrong-reason bug whose accidental errno source sits in the
  *same* production function could still hide.
- Subsumption claims for the three removed cases were checked against the
  current source only; they say nothing about older branches.

## Verification gate

Next boot of the rewrite KASAN kernel: `rewrite-kunit-log-check.sh`
against the regenerated 89+150 manifest with zero fail/skip, a
fatal-free KUnit interval, and specifically **no WARN from
`rk_rga_import_detach_map_locked()`**.
