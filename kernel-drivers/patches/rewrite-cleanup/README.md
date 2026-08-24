# rewrite-cleanup/

Behavior-preserving cleanup patches for the clean-room rewrite drivers.

## Current series

| Patch | Target | Cleanup |
|-------|--------|---------|
| [`0001-mpp-remove-duplicate-job-reference-prototypes.patch`](0001-mpp-remove-duplicate-job-reference-prototypes.patch) | `mpp_rewrite.c` | Removes duplicate declarations of `rk_mpp_job_get()` and `rk_mpp_job_put()`. |
| [`0002-rga-remove-duplicate-validation-prototypes.patch`](0002-rga-remove-duplicate-validation-prototypes.patch) | `rga_rewrite.c` | Removes two duplicate declarations of `rk_rga_task_validate_ignored_semantics()`. |

## Source state

Prepared at the documented boundary-hardening mainline pin
`rk3588-rewrite-mainline@b6335efd8f98bedabf426a80d224f85a266c8ea4`.
Because the tracked rewrite sources are byte-identical across the
maintained 6.18 and mainline branches, each patch applies unchanged to
both trees.

Apply from the kernel source root with:

```sh
git apply ../rock-5b-ysp/kernel-drivers/patches/rewrite-cleanup/*.patch
```

Then run the rewrite audits and warning-fatal build profiles with
[`kernel-drivers/tests/rewrite-build-gate.sh`](../../tests/rewrite-build-gate.sh).
