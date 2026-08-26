# rewrite-cleanup/

Behavior-preserving cleanup patches for the clean-room rewrite drivers.

## Current series

| Patch | Target | Cleanup |
|-------|--------|---------|
| [`0001-mpp-remove-duplicate-job-reference-prototypes.patch`](0001-mpp-remove-duplicate-job-reference-prototypes.patch) | `mpp_rewrite.c` | Removes duplicate declarations of `rk_mpp_job_get()` and `rk_mpp_job_put()`. |
| [`0002-rga-remove-duplicate-validation-prototype.patch`](0002-rga-remove-duplicate-validation-prototype.patch) | `rga_rewrite.c` | Removes the redundant test-region declaration of `rk_rga_task_validate_ignored_semantics()`, retaining the production prototype. |
| [`0003-remove-unused-rewrite-declarations.patch`](0003-remove-unused-rewrite-declarations.patch) | MPP and RGA | Removes an unnecessary MPP runtime-registration prototype and an unused RGA hardware-type helper. |
| [`0004-mpp-remove-duplicate-process-request-declaration.patch`](0004-mpp-remove-duplicate-process-request-declaration.patch) | `mpp_rewrite.c` | Removes a duplicate declaration of `rk_mpp_process_request()`. |
| [`0005-remove-stale-rewrite-fields.patch`](0005-remove-stale-rewrite-fields.patch) | MPP and RGA | Removes a stale MPP `__maybe_unused`, a write-only link-table size field, and a write-only per-execution timing accumulator. |
| [`0006-rga-remove-duplicate-import-prototype.patch`](0006-rga-remove-duplicate-import-prototype.patch) | `rga_rewrite.c` | Removes a duplicate declaration of `rk_rga_import_buffer_size()`. |
| [`0007-mpp-remove-duplicate-activation-declaration.patch`](0007-mpp-remove-duplicate-activation-declaration.patch) | `mpp_rewrite.c` | Removes a duplicate declaration of `rk_mpp_hw_install_active_locked()`. |

## Source state

Prepared against the maintained branch heads after cleanup:
mainline `a7a308ab63454` and 6.18 `9030386c8bcca`. Because the tracked
rewrite sources remain byte-identical across both branches, patches
`0003` onward are relative to the preceding series and the combined
series applies unchanged to either tree from the documented boundary
hardening base.

Apply from the kernel source root with:

```sh
git apply ../rock-5b-ysp/kernel-drivers/patches/rewrite-cleanup/*.patch
```

Then run the rewrite audits and warning-fatal build profiles with
[`kernel-drivers/tests/rewrite-build-gate.sh`](../../tests/rewrite-build-gate.sh).

A reviewer-proposed removal of the KUnit-used RGA
`rk_rga_job_hw_type()` helper was rejected after the clean-source build
gate proved it would break test builds. It is intentionally absent from
the series.

Reviewers also proposed removing early declarations used before their
definitions, removing KUnit-only helpers that require `__maybe_unused`
in production builds, and removing an RGA debug-events file whose fops
symbol is registered by `DEFINE_SHOW_ATTRIBUTE()`. These were triaged as
false positives and intentionally excluded.
