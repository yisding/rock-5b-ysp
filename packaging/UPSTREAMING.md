# Upstreaming decisions — packaging

This package holds the deploy-time delivery channels (codec udev rules, DKMS,
the GDM greeter ACL, the PPA, and Plymouth/FFmpeg distro packaging); this file
records its upstream submission disposition, decided 2026-07-29. Cross-package
ordering and coupling constraints live in the central
[upstreaming ledger](../docs/upstreaming-ledger.md); dated claims below must be
re-verified before acting on them.

## Decision list

| ID | Item | Artifact | Upstream target | Decision | Priority | Gates / prerequisites |
|----|------|----------|------------------|----------|----------|------------------------|
| PKG-1 | Rockchip codec/dma-heap udev rule for Armbian images | `kernel-drivers/scripts/99-rockchip-codec.rules` (also shipped as the rk3588-codec-udev deb) | armbian/build (GitHub PR #10085) | MERGED | P2 | — |
| PKG-2 | Armbian docs: the empty-userpatch "disable a patch" instruction is stale on glob branches | `packaging/docs/armbian-patch-precedence.md` | armbian/documentation (PR against `docs/Developer-Guide_User-Configurations.md`) | SUBMIT-NOW | P3 | — |
| PKG-3 | Armbian patcher: restore userpatch-over-core precedence | `packaging/docs/armbian-patch-precedence.md` § "Restoring the documented behavior" | armbian/build (PR against `lib/tools/patching.py`) | HOLD | P3 | Maintainer agreement that the precedence flip is wanted at all; likely redesign to key the dedup dict on relative path rather than basename; whole-board CI matrix run to catch userpatches that would suddenly take effect |
| PKG-4 | Plymouth incomplete-CSI keyboard hang patch carried in the PPA | `packaging/ppa/plymouth/debian/patches/ply-keyboard-fix-hang-on-incomplete-csi.patch` | Plymouth upstream / Debian-Ubuntu Plymouth | NEVER | P3 | — |
| PKG-5 | Report the boot-transaction defect: an unresponsive inherited plymouthd wedges sysinit.target forever | Two dated findings plus failed/adjacent-healthy journals | Plymouth upstream (freedesktop GitLab issue) | HOLD | P3 | Capture the wedged daemon live (debug-shell.service, `plymouth.debug=stream:/dev/ttyS2`, `/proc/<pid>/stack`/wchan/syscall); one `plymouth.enable=0` exclusion boot to confirm the mitigation and bound the attribution |
| PKG-6 | gdm-hwenc: the setfacl g:gdm codec-node udev rule itself | `packaging/gdm-hwenc/root/usr/lib/udev/rules.d/70-gnome-remote-desktop-gdm-hwenc.rules` + build-deb.sh/control/postinst | Any distro or GNOME channel | NEVER | P3 | — |
| PKG-7 | Report: logind uaccess does not follow GDM's dynamic-greeter-user churn on non-seat device nodes | The measured getfacl/udevadm diagnosis behind gdm-hwenc | systemd (GitHub issue) or gnome-remote-desktop | HOLD | P3 | Build a minimal reproducer independent of Rockchip codec nodes on stock systemd, and record the systemd version; decide the target — logind behavior change vs documented pre-login-greeter guidance |
| PKG-8 | rk3588-vcodec-dkms out-of-tree build (Kbuilds, devfreq re-guard, DT overlay) | `packaging/dkms/` | No external upstream | NEVER | P3 | — |
| PKG-9 | Armbian builds a patch-free kernel with zero errors when KERNELPATCHDIR does not exist | Measured build report (no patch yet) | armbian/build (GitHub issue, then a small assertion PR) | SUBMIT-NOW | P3 | — |
| PKG-10 | Debian/Ubuntu ffmpeg source package omits frei0r-plugins from Build-Depends | One-line `debian/control` Build-Depends change | Debian ffmpeg (BTS) or Ubuntu (Launchpad) | SUBMIT-NOW | P3 | — |

## Rationale and evidence

### PKG-1 — Rockchip codec/dma-heap udev rule for Armbian images

Merged as armbian/build commit `a6163444eb6c305b635c82242fbeb636daf4b6f4` on
2026-06-30, re-verified still merged at watchlist check W03 on 2026-07-11. The
non-obvious content is the dma-heap grant matched by `SUBSYSTEM==dma_heap`
rather than `KERNEL` (the heap node is named just `system`) — without it MPP
init dies at `MppBufferService::get_group` even when `mpp_service` itself is
granted, so `packaging/codec-udev/` stays useful as a backfill for pre-merge,
kernel-only, and custom images. This row also absorbs the kernel track's
KFP-13 duplicate (same merged PR/commit) and carries the security corollary
that granting these nodes to the video group is what makes the KFP-1 defects
unprivileged-reachable.

- Evidence: [packaging/codec-udev/README.md](codec-udev/README.md), [kernel-drivers/scripts/99-rockchip-codec.rules](../kernel-drivers/scripts/99-rockchip-codec.rules), [status.md](../status.md), [packaging/README.md](README.md)
- Coupled with: KFP-1

### PKG-2 — Armbian docs: the empty-userpatch "disable a patch" instruction is stale on glob branches

The documented method silently does nothing on every glob family (roughly 45
branches including `rockchip64-*`), because `ALL_DIR_PATCH_FILES_BY_NAME` is
keyed by basename with core written last. The claim is source-inspected
against a pinned armbian/build tree (`82b6430`) and independently corroborated
by Igor on forum topic 26732 — the evidence class a docs PR needs, with no
board or CI run required. It is strictly separable from PKG-3: correcting the
docs to describe what actually works needs no behavior change and cannot
regress anything. This row also absorbs KFP-14's docs half and the kernel
track's duplicate row, since landing it retires real fork delta and removes
the mechanical half of KFP-15's collision problem.

- Evidence: [packaging/docs/armbian-patch-precedence.md](docs/armbian-patch-precedence.md), [status.md](../status.md)
- Coupled with: PKG-3, KFP-15

### PKG-3 — Armbian patcher: restore userpatch-over-core precedence

The code change is genuinely two lines, and the analysis argues apply order is
unaffected since the list is re-sorted alphabetically immediately after — only
the collision winner flips. But the cost here is validation, not code, and
that gate cannot be closed locally: there is no access to Armbian's board
matrix and no way to survey third-party userpatches for basename collisions.
Revisit if a maintainer signals interest after PKG-2, or once the
basename-to-path re-key is done and tested locally across the families this
project builds.

- Evidence: [packaging/docs/armbian-patch-precedence.md](docs/armbian-patch-precedence.md), [status.md](../status.md)
- Coupled with: PKG-2, KFP-15

### PKG-4 — Plymouth incomplete-CSI keyboard hang patch carried in the PPA

There is nothing of ours to upstream: the patch is authored by D Scott
Phillips and is already applied upstream as `45655f12fa2d5553ab4ba509f2e203c249191664`
against issue #321, so the delta here is packaging only. The distro-backport
framing is separately unsupported: W20 records that on 2026-07-23 the stall
recurred on a boot where the patched Plymouth was binary-verified in the
running initramfs, which falsifies the incomplete-CSI loop as the sole cause
here. Asking a distro to cherry-pick on the strength of an attribution this
project itself disproved would be dishonest.

- Evidence: [packaging/ppa/plymouth/debian/patches/ply-keyboard-fix-hang-on-incomplete-csi.patch](ppa/plymouth/debian/patches/ply-keyboard-fix-hang-on-incomplete-csi.patch), [packaging/userspace-patches.md](userspace-patches.md), [status.md](../status.md), [findings/2026-07-23-rock5b-boot-hang-recurred-with-patched-plymouth.md](../findings/2026-07-23-rock5b-boot-hang-recurred-with-patched-plymouth.md), [findings/2026-07-22-rock5b-boot-hang-plymouth-initramfs-daemon.md](../findings/2026-07-22-rock5b-boot-hang-plymouth-initramfs-daemon.md)
- Coupled with: PKG-5

### PKG-5 — Report the boot-transaction defect: unresponsive inherited plymouthd wedges sysinit.target forever

The transaction-level mechanism is the part that survived falsification and is
genuinely report-worthy: a client with no timeout plus an infinite-start-timeout
unit ordered before `sysinit.target` converts any daemon wedge into an
unbounded boot hang, independent of which internal wedge is at fault. But
upstream's first question will be where the daemon is stuck, and that evidence
does not exist yet — the 2026-07-22 attribution was a source match rather than
a sampled task state, and the 2026-07-23 recurrence retired it. The gate is
cheap and already specified; hold until the next hang is captured live.

- Evidence: [findings/2026-07-22-rock5b-boot-hang-plymouth-initramfs-daemon.md](../findings/2026-07-22-rock5b-boot-hang-plymouth-initramfs-daemon.md), [findings/2026-07-23-rock5b-boot-hang-recurred-with-patched-plymouth.md](../findings/2026-07-23-rock5b-boot-hang-recurred-with-patched-plymouth.md), [status.md](../status.md)
- Coupled with: PKG-4

### PKG-6 — gdm-hwenc: the setfacl g:gdm codec-node udev rule itself

Deliberately fork-only. The rule widens video-codec access to the entire gdm
group, which is a security choice rather than a default, and there is no
Armbian or distro precedent for granting the gdm group codec access. GRD does
not depend on it — without it the greeter simply falls back to software RFX —
so there is no upstream defect to fix by shipping it, and pushing a group-wide
ACL grant as a default would be an unreviewable security change dressed as an
enablement patch. The knowledge behind it is worth upstreaming; the policy is
not, which is what PKG-7 separates out.

- Evidence: [packaging/gdm-hwenc/README.md](gdm-hwenc/README.md), [packaging/README.md](README.md), [apps/gnome-remote-desktop/README.md](../apps/gnome-remote-desktop/README.md)
- Coupled with: PKG-7, GRD-14

### PKG-7 — Report: logind uaccess does not follow GDM's dynamic-greeter-user churn

This is a real measured behavior: uaccess-tagged codec nodes kept the ACL of
whichever gdm-greeter-N user appeared first while logind refreshed the DRM
seat node correctly, so the active greeter had `renderD128` but not
`/dev/mpp_service` or `/dev/dma_heap/*`. It is also plausibly
working-as-designed (uaccess is scoped to seat devices for the active seat
user), so a report needs a reproducer that separates a logind bug from "no
mechanism exists for a pre-login greeter to reach a non-seat device." The
current evidence is entangled with a vendor codec stack on a forward-ported
kernel, the weakest possible framing for a systemd issue.

- Evidence: [packaging/gdm-hwenc/README.md](gdm-hwenc/README.md), [apps/gnome-remote-desktop/README.md](../apps/gnome-remote-desktop/README.md)
- Coupled with: PKG-6, GRD-14

### PKG-8 — rk3588-vcodec-dkms out-of-tree build

A delivery channel, not a fix. The Kbuilds exist only because the vendor
`CONFIG_ROCKCHIP_MPP_*`/`_RGA_*` symbols do not exist in a stock host config,
so they hand-list objects and `-D` the symbols the vendor C code `#ifdef`s on
— downstream packaging glue with no upstream consumer. The one arguably
portable insight, the devfreq re-guard, is a change to vendor driver source
and belongs to the kernel-drivers track's submission units, not a packaging
PR. The evidence class also would not support a submission: compile-and-link
tested on 6.18 only, and its DT overlay is dtc-validated but not
boot-validated as of 2026-07-01.

- Evidence: [packaging/dkms/README.md](dkms/README.md), [packaging/README.md](README.md), [status.md](../status.md), [docs/status-ledger.md](../docs/status-ledger.md)

### PKG-9 — Armbian builds a patch-free kernel with zero errors when KERNELPATCHDIR does not exist

Same defect class as BOOT-4 and the same target: a build that silently emits
a structurally valid but wrong artifact. Measured, not theorised — a
BOARDFAMILY rename moved LINUXFAMILY, KERNELPATCHDIR resolved to a directory
that does not exist, and the build applied zero core patches and zero of the
75 staged userpatches, ran 2 h 10 m, and produced four installable,
correctly-named debs with no `ROCKCHIP_MPP`/`RKVENC`/`RKVDEC2` symbols at all,
with no error anywhere. File the issue now on the measurement alone; the
assertion PR can follow once written and tested against a deliberately-missing
patch dir.

- Evidence: [findings/2026-07-25-armbian-linuxfamily-rename-silent-patch-free-kernel.md](../findings/2026-07-25-armbian-linuxfamily-rename-silent-patch-free-kernel.md), [packaging/docs/armbian-patch-precedence.md](docs/armbian-patch-precedence.md), [kernel-drivers/scripts/build-kernel.sh](../kernel-drivers/scripts/build-kernel.sh)
- Coupled with: PKG-2, PKG-3, BOOT-4

### PKG-10 — Debian/Ubuntu ffmpeg source package omits frei0r-plugins from Build-Depends

The smallest true item in the sweep, listed so it is dropped deliberately
rather than by omission. `distort0r.so` ships in the runtime `frei0r-plugins`
package, not in `frei0r-plugins-dev`, so `filter-frei0r-filter` and
`filter-frei0r-filter-unaligned` cannot run in a clean sbuild/Launchpad-style
chroot as the packaging stands. Zero risk, no behaviour change, and it retires
a small real delta in this project's own packaging tree; not coupled to the
FFmpeg upstream track since this is distro packaging.

- Evidence: [findings/2026-07-09-ffmpeg-baseline-rk2-local-build-validation.md](../findings/2026-07-09-ffmpeg-baseline-rk2-local-build-validation.md), [packaging/userspace-patches.md](userspace-patches.md)
