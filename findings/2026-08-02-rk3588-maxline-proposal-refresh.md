# RK3588 maxline refreshed to current proposals, Linus master, and linux-next

> Scope: maximum-mainline kernel source and packaging record
> Source: Torvalds `master@075b74841bd0`, linux-next
> `next-20260731@415606a7be93`, and the subsystem refs pinned in
> `kernel-versions/maxline/manifest.yaml`
> Date: 2026-08-02
> Trust: SOURCE-INSPECTED / MEASURED

## Result

The maxline proposal set was re-audited and rebuilt as four clean source
branches. The packaged profiles use the latest fetched Torvalds master;
parallel validation branches use the latest available linux-next tag:

| Profile | Base | Tip | Delta |
| --- | --- | --- | ---: |
| public | `075b74841bd0` | `e6951bc3f935` | 299 commits |
| WIP | public | `73d29539f7bb` | 19 commits |
| public-next | `415606a7be93` | `0cae4ac66823` | 264 commits |
| WIP-next | public-next | `15a5179dc3b2` | 19 commits |

The public ledger now has 41 proposal entries: 21 applied, 12 reconciled, and
eight already in the Linus base. The WIP tail is now FRL-only. The old GitHub
VDPU381 VP9 donor was removed because a public four-patch v1 series supersedes
it and is now part of `public`.

## Upstream and subsystem-next audit

The Naneng SSC direction fix is already in Linus as `be2b5b17b705`; its
proposal commit was removed from the public delta. The 2026-08-02 subsystem
snapshot also contains these previously proposed changes:

- `drm-misc/for-linux-next@bc47d5937f21`: the five-patch VOP2 multi-output
  series, two-patch YUV-background series, and the non-i915 portion of the
  forced-color-format series; the four i915 tail patches remain in maxline;
- `usb/usb-next@5d5fd841c346`: the Type-C AltMode Discover Identity retry at
  `205dc9cb39f5`;
- `media-pending/next@31152f5b0f87`: the three RKVDEC H.265 corrections at
  `f0b9d7e5be06`, `796b5c6d4f16`, and `052c5ed5a1d9`;
- `drm-misc/for-linux-next`: the EDID test-data prerequisite imported by the
  Linus-based stack as `2693c9572eaf`.

The linux-next replay omitted exact equivalents already present in its base.
This is why `public-next` has 264 commits rather than the Linus-based public
stack's 299. An accepted subsystem-next patch can remain in the Linus-based
packaging delta until it reaches Linus; the two profiles therefore answer
different questions without duplicating patches inside either tree.

## New and revised proposal inputs

| Series | Previous | Selected 2026-08-02 input | Patches |
| --- | --- | --- | ---: |
| HDMI 2.0 scrambling | v8 | v10 | 69 |
| Synopsys DW-DP improvements | v3 | v8 | 21 |
| SCDC link health/debugfs | v6 | v9 | 5 |
| Samsung HDPTX clock fixes | v4 | v5 | 10 |
| HDMI-RX audio | v2 | v4 | 4 |
| RK3588 CAN-FD | v4 | v6 | 4 |
| VDPU381 VP9 | private/WIP donor | public v1 | 4 |
| Samsung CSI DCPHY | absent | public v2 | 4 |
| HDMI-QP audio N/CTS | absent | public v3 | 1 |

USBDP remains the already-integrated public v13 series; an older status matrix
entry was not used to downgrade it. Exact first-message IDs, mailbox hashes,
and dispositions are pinned in `public-series.tsv`.

## Rebase resolutions

The Linus replay replaced old revisions instead of layering new revisions over
them. Its substantive integrations preserve:

- HDMI v10 connector allocation, scrambling, forced-format state, targeted
  HPD notification, and the new audio N/CTS helper without reviving removed
  legacy tables;
- SCDC v9's source-version and debugfs behavior alongside force-context state;
- DW-DP v8's resource lifetime and fixed-bus-format negotiation on the bridge
  API used by each base;
- the public VP9 v1 shared layout and multicore RKVDEC model;
- CAN v6's move of assigned clocks from the Haikou carrier to the Tiger SoM.

The Linus endpoint ports HDMI v10's connector-state initialization back to the
available `reset` callback because `drm_connector_funcs.atomic_create_state`
has not reached Linus. It also maps DW-DP's OOB-HPD walk to Linus's renamed
`drm_for_each_bridge_in_chain_scoped()` iterator. Focused object builds catch
and verify both boundaries. On linux-next, the HDMI helper and DW-DP use the
base's newer state-creation APIs while retaining the v8
`atomic_get_input_bus_fmts` implementation. Its forced-color replay also
removes the second copy of a color-format helper already supplied by the next
base. The VP9 backend was ported from its single-device register, clock, DMA,
and watchdog assumptions to the selected multicore `rkvdec_core`; persistent
tables use the main core's DMA device. The linux-next replay also follows the
base's rename of `v4l2_isp_params_buffer_size()` to
`v4l2_isp_buffer_size()`. The FRL WIP replay keeps the public HDMI v10 connector lifetime and N/CTS
implementation, adds FRL N values and training, and drops the obsolete
sentinel-table cleanup. No conflict markers or whitespace errors remain in any
of the four trees.

## Verification

The exported public and WIP patches reverse-apply cleanly to their exact branch
heads. The full native arm64 `Image modules dtbs` build and incremental recheck
pass for Linus/public. Focused linux-next objects for the VDPU381 VP9 and
RKISP2 conflict resolutions pass, and the broader linux-next/WIP build passed
the refreshed PHY, PCIe, Rockchip DRM/VOP2, DW-DP, and HDMI paths before it was
stopped at the user's request; it has no successful full-build exit status.
Exact results and object identities are recorded in
`kernel-versions/maxline/verification.md`.

## Boundary

This is source-integration and compile evidence. Refreshed Debian packages were
not built, installed, or booted. No storage, network, USB, PCIe, suspend,
display, audio, camera, media, NPU, crypto, CAN-FD, HDMI-RX, FRL, VP9, or
rollback behavior is proven on hardware.
