# INSTALL — hardware codecs on a Radxa ROCK 5B

The one page for **"I want the RK3588 hardware codecs working on my board."**
It chooses a delivery model, walks the canonical quickstart, and hands off to
userspace. Deep dives are linked at every step; if you only read one other
page afterwards, make it [kernel driver guide](./kernel-drivers/docs/how-the-drivers-work.md).

> **Unfamiliar term?** MPP, RGA, DKMS, PHASH, convert-in-place and the rest are
> all defined in [`glossary.md`](glossary.md) — keep it open alongside this page.

## 1. Choose your delivery model

Two ways to get the **kernel drivers**, plus the **userspace** layer you need
in either case:

| Path | What you get | What it needs | Validation status ([`status.md`](status.md)) | Where |
|------|--------------|---------------|-----------------------------------------------|-------|
| **(a) Combined Armbian forward-port kernel** | MPP encode/decode (including AV1) and RGA **built in (`=y`)** — no modules, no overlay | The forward-port kernel tree + an Armbian build tree (§2) + a kernel install/reboot | Has extensive hardware evidence, but the latest installed result and any regression live in [`status.md` track 1](status.md#dashboard); the durable boundary lives in the [forward-port scorecard](kernel-drivers/docs/forward-port-status.md). | [`kernel-drivers/scripts/`](kernel-drivers/scripts/README.md) + [`kernel-drivers/patches/forward-port-rk3588/`](kernel-drivers/patches/forward-port-rk3588/README.md) |
| **(a2) Published PPA forward-port kernel** | A prebuilt combined kernel — MPP/AV1/RGA `=y`, no local build | The `ppa:yi-ding/ubuntu-rock-5b` archive + `apt install` + reboot | [`docs/ppa-support.md`](docs/ppa-support.md) owns the newcomer install and support boundary; [`status.md`](status.md) owns the dated kernel and publication verdicts. | [`packaging/ppa/kernel-forward-port/`](packaging/ppa/kernel-forward-port/README.md) |
| **(b) DKMS on a stock kernel** | `rk_vcodec.ko` + `rga3.ko`, auto-rebuilt on every kernel update, + a boot-time DT overlay | A *stock* Armbian 6.18+ kernel, `dkms` + `dtc` installed | ⚠️ Compile-tested on **6.18 only**; overlay dtc-validated, **not boot-validated** | [`packaging/dkms/`](packaging/dkms/README.md) |
| **(c) Userspace** (needed by **both** kernel paths) | `librockchip_mpp` + `librga` + an rkmpp-enabled FFmpeg | A working kernel path (a) or (b), + the udev rule (§8) | Source-built `ffmpeg-rockchip` is hardware-validated; the system PPA publishes codec access, MPP, librga, FFmpeg 8.0.3, GRD, and co-installable FFmpeg 6.1, while dedicated PPAs publish both FFmpeg 8.1 tracks | [`video-libraries/ffmpeg/`](video-libraries/ffmpeg/README.md), [`packaging/ppa/`](packaging/ppa/README.md) |

> **⚠️ Hard warning: (a) and (b) are mutually exclusive** — installing the DKMS
> module on the combined kernel breaks the build. Mechanism and the exact
> `modpost` error are owned by
> [`packaging/dkms/README.md`](packaging/dkms/README.md) § Caveats. Pick **one**
> kernel path.
>
> The **udev rule (§8) is needed on both paths** — no kernel path makes the
> device nodes usable without root by itself.

For what the published archive and its kernel do and do not support — including
the board/OS/architecture boundary, the evidence behind each claim, and the
comparison with a Rockchip BSP distribution — read
[`docs/ppa-support.md`](docs/ppa-support.md) before path **(a2)**.

Before choosing, read [`status.md`](status.md) tracks 1, 3, and 9. Path **(a2)**
is the lowest-effort route; its moving package identity and qualification
boundary live in the status dashboard and watchlist, not in this runbook. Take
**(a)** for a specific source tail or a debug/KASAN discriminator. Take **(b)**
only if the stock kernel must remain in place, and accept that its overlay has
not booted in this evidence record.
Whichever you pick, complete §3 first and use §9 to identify what the archive or
local build actually carries.

The [`maximum-mainline profiles`](kernel-versions/maxline/README.md)
are research comparison builds, not a third validated codec delivery model.
Both compile and package, but neither has been installed or booted; follow
[`status.md` track 13](status.md#dashboard) and its recovery-first gate before
using either on a board.

## 2. Prerequisites (path a)

[Armbian](glossary.md) is the Debian/Ubuntu-based distro + build framework this
port targets; the kernel is produced by *its* build system, not compiled by
hand. Do not confuse the two operating-system roles: **Ubuntu 26.04 Resolute is
the target image/userspace**, while Armbian's documented native build hosts are
Armbian or **Ubuntu 24.04 Noble**. Any current Docker-capable Linux can instead
use the containerized build. The official requirements are at least **8 GB RAM**
(less only with BTF disabled) and about **50 GB free disk**; the measured cold
kernel build takes ~80–90 minutes and a warm patch-only build ~10–15 minutes.

`compile.sh` prefers Docker when a working daemon is available
(`PREFER_DOCKER=yes`, the default) and otherwise relaunches through `sudo` for a
native build. Choose one supported host mode:

| Build-host mode | Requirement | Invocation through this repo |
|-----------------|-------------|------------------------------|
| Containerized (default) | A current Docker-capable Linux host; install/start Docker and give your user daemon access. | `bash kernel-drivers/scripts/build-kernel.sh forward-port` |
| Native | Armbian or Ubuntu 24.04 Noble, plus working `sudo`. The measured aarch64 VM path is documented in the [builder finding](findings/2026-07-08-armbian-builder-setup.md). | `bash kernel-drivers/scripts/build-kernel.sh forward-port PREFER_DOCKER=no` |

On a ROCK 5B already running the target Ubuntu 26.04 userspace, use the Docker
mode unless Armbian adds Resolute to its native-host support list. See Armbian's
official [build preparation](https://docs.armbian.com/Developer-Guide_Build-Preparation/)
and [`PREFER_DOCKER` switch](https://docs.armbian.com/Developer-Guide_Build-Switches/#prefer_docker).

`kernel-drivers/scripts/build-kernel.sh` expects an Armbian build tree at
**`$WORKSPACE/armbian-build`** — an external, gitignored build workspace
(default `WORKSPACE=../rock-5b/build/kernel/rock5b-kernel-build`, override with `WORKSPACE=`)
and a forward-port Git tree at `KERNEL_TREE` (default
`../rock-5b/kernel/linux-6.18-rkvenc-av1-fwport`). The tracked split series under
[`kernel-drivers/patches/forward-port-rk3588/`](kernel-drivers/patches/forward-port-rk3588/README.md)
records the source commits. The bootstrap clones Armbian's configured branch
(`main` by default) and checks out the conformance sources at the commits in
their manifest:

```bash
bash kernel-drivers/scripts/bootstrap-workspaces.sh
```

Debs land in `$WORKSPACE/armbian-build/output/debs` — exactly where
`install-combined-kernel.sh` looks by default, so the build → install handoff
needs no path edits. Background on the patch mechanism (userpatches, zero edits
to Armbian's own files, the `media-0001` collision):
[Armbian packaging guide](./packaging/docs/armbian-packaging.md).

For **vanilla mainline** (no Armbian) the driver patch applies as-is but the
decoder DT must be inline — follow [vanilla-kernel guide](./kernel-versions/docs/vanilla-kernel.md)
instead of this quickstart.

## 3. Prepare recovery and capture the old baseline

Do this **before either kernel install path**. Armbian's ROCK 5B U-Boot flow has
no kernel-selection menu: keeping another file under `/boot` does not make it
selectable after a failed boot.

Each local flavor now installs into its own package slot — `video-port`,
`video-port-kasan`, `video-rewrite`, `video-rewrite-kasan`, all `-rockchip64`
([package slots](kernel-drivers/docs/kernel-builds.md#package-slots)) — so a
debug install can no longer clobber a production one, and
`install-kernel.sh` refuses Armbian's stock `current-rockchip64` and the PPA's
`ysp-rockchip64` outright. The hazard that remains is **within** a slot:
successive builds of one flavor share a package name and kernel version string,
so installing a newer build replaces the known-good one. Pin every install by
the `PHASH` the build printed.

1. Capture the working board/kernel/userspace identity:

   ```bash
   PROFILE=pre-install \
     bash kernel-drivers/tests/conformance/scripts/collect-system-info.sh
   ```

2. Record which kernel `/boot` selects and keep the known-good **image + DTB
   debs** somewhere the rescue environment can reach:

   ```bash
   sudo bash kernel-drivers/scripts/kernel-revert.sh list
   cp -a /boot/armbianEnv.txt ./armbianEnv.txt.pre-ysp
   ```

3. Have a tested SD rescue path that can mount the internal Armbian root. The
   current SD/SPI limitations are tracked in [`status.md` track 12](status.md#dashboard);
   do not assume an arbitrary raw SD image bypasses the installed loader.

   **Operator-validated 2026-08-04:** this documented SD-rescue flow and the
   exact `kernel-revert.sh` commands below have been used successfully for
   forward-port rollback. A reader can use the same mechanism; the dated
   evidence boundary is recorded in the
   [recovery finding](findings/2026-08-04-forward-port-sd-rescue-rollback-used.md).

4. Know which recovery operation applies:

   | Situation | Recovery from the rescue boot |
   |-----------|-------------------------------|
   | A distinct known-good kernel version is still present | `sudo bash kernel-drivers/scripts/kernel-revert.sh --auto list`, then `sudo bash kernel-drivers/scripts/kernel-revert.sh --auto switch <version>` |
   | The install overwrote the same-version package files | `sudo bash kernel-drivers/scripts/kernel-revert.sh --auto reinstall <known-good-image.deb> <known-good-dtb.deb>` |

The full target-selection and clobber explanation is in
[`kernel-drivers/scripts/kernel-revert.sh`](kernel-drivers/scripts/kernel-revert.sh).
For a persistent distinct fallback, repackage known-good image/DTB debs with
[`make-fallback-kernel-deb.sh`](kernel-drivers/scripts/make-fallback-kernel-deb.sh)
and install them before testing the new kernel.

`install-combined-kernel.sh` now refuses to modify `/boot` until
`RECOVERY_READY=1` is supplied. That flag is an acknowledgement, not a test;
the commands above are the actual preparation.

## 4. Canonical quickstart (path a — combined kernel)

```bash
# 0. Bootstrap the external Armbian workspace if this machine does not have it.
export WORKSPACE="${WORKSPACE:-../rock-5b/build/kernel/rock5b-kernel-build}"
bash kernel-drivers/scripts/bootstrap-workspaces.sh

# 1. Regenerate and stage the self-contained-DT forward-port patches, then build
#    (~80-90 min cold, ~10-15 warm). USE_CCACHE must be an ARGUMENT, not an env
#    var -- the wrapper gets this right (docs/gotchas.md). On a supported
#    Noble/Armbian native host, append PREFER_DOCKER=no.
bash kernel-drivers/scripts/build-kernel.sh forward-port # prints the new P####-C#### hash

# 2. Install (pin the hash the build printed), reboot, validate:
sudo RECOVERY_READY=1 WORKSPACE="$WORKSPACE" PHASH='P####-C####' \
  bash kernel-drivers/scripts/install-combined-kernel.sh
sudo reboot
sudo bash kernel-drivers/scripts/validate-combined.sh       # /dev/mpp_service, 4 cores, /dev/rga

# 3. Non-root device access (recommended; REQUIRED for non-root ffmpeg).
#    dma_heap is required, not just mpp_service -- rkmpp allocates buffers
#    there (docs/gotchas.md). You must also be in the `video` group:
sudo cp kernel-drivers/scripts/99-rockchip-codec.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

A green `validate-combined.sh` shows the two encoder cores (`rkvenc-core0/1`),
the two decoder cores (`rkvdec-core0/1` on the self-contained-DT forward port),
and `/dev/rga`. The validator also accepts the older convert-in-place kernel's
`video-codec0/1` names.

## 5. PHASH pinning — don't install the wrong build

Armbian bakes a `P####-C####` pair into every kernel deb name: `P####` hashes
the **applied patch set**, `C####` the **kernel config** — so the pair names an
*exact* build ([`glossary.md`](glossary.md)). `install-combined-kernel.sh`
matches debs on `HASH` (kernel version) + `PHASH` so it can never grab a stale
deb from `output/debs`. Workflow:

1. `build-kernel.sh` prints the new hash at the end of every build.
2. After completing §3, pass it to the installer (`sudo RECOVERY_READY=1
   PHASH='…' bash kernel-drivers/scripts/install-combined-kernel.sh`).
3. Record the hash wherever the build's state is being tracked — the
   `status.md` track or watchlist entry that owns it — so it stays
   decodable later.

### Hash ↔ patch-revision log (6.18.37 era)

| PHASH | Kernel | Patch set | Validated | Notes |
|-------|--------|-----------|-----------|-------|
| `P1c9d` (config hash not recorded) | 6.18.37-current-rockchip64 | Self-contained-DT MPP/RGA/AV1 forward port | ✅ hardware ([kernel status](kernel-drivers/docs/forward-port-status.md); AV1 re-run 2026-07-04) | First hardware-validated AV1 superset build. |
| `Pb6ab-Cb831` | 6.18.37-current-rockchip64 | `kernel-drivers/patches/rk3588-rkvenc2-01` + `02` (current revision) | ✅ hardware ([kernel status](kernel-drivers/docs/forward-port-status.md); tests re-run 2026-07-01) | Known validated pair; `install-combined-kernel.sh` still requires it explicitly. |
| `P8c75` (config hash not recorded) | 6.18.37 | functionally-identical predecessor revision | ✅ ([kernel status](./kernel-drivers/docs/forward-port-status.md)) | Superseded by `Pb6ab-Cb831`. |

This table is a closed historical record of the three 6.18.37 builds, kept
because `install-combined-kernel.sh` still names `Pb6ab-Cb831` explicitly. It is
**not** a running log: the 6.18.38 builds that superseded it (`Pabd5-C4ad2`,
`P9636-C4ad2`, `P272c-Cb831`, and the rest) are identified where their evidence
lives — [`status.md`](status.md) track 1 and its watchlist entries, and
[kernel status](kernel-drivers/docs/forward-port-status.md). Record a new build
there rather than appending here, so one build's identity and its validation
state do not drift apart.

A PHASH change with unchanged forward-port commits means the Armbian patch stack
moved — run the [resyncing guide §4](./kernel-drivers/docs/resyncing.md) bump
checklist.

## 6. Path b — DKMS on a stock kernel

Full instructions (KSRC reconstruction, out-of-tree Kbuild details, caveats):
[`packaging/dkms/README.md`](packaging/dkms/README.md). The shape:

```bash
# build the deb (stages source from a v6.18 + patch-01 tree -- docs/source-trees.md §1):
KSRC=/path/to/linux-6.18-rkvenc/drivers/video/rockchip bash packaging/dkms/build-deb.sh
# on a STOCK-kernel board:
sudo apt install dkms device-tree-compiler
sudo dpkg -i packaging/dkms/build/rk3588-vcodec-dkms_1.0_arm64.deb
# add rk3588-rock5b-vcodec to user_overlays= in /boot/armbianEnv.txt, reboot
```

Then validate exactly as in §4 (`validate-combined.sh` works for both paths).
Remember: **the overlay is not boot-validated** ([`status.md`](status.md)) and
the package must never be installed on the combined kernel (§1).

## 7. Validate, then exercise real frames

Compare the post-boot result against the pre-install capture from §3; a new
device node or package alone is not proof that real frames ran on hardware.

1. `sudo bash kernel-drivers/scripts/validate-combined.sh` — devices, 4 cores, clean-probe
   dmesg sweep ([`kernel-drivers/scripts/README.md`](kernel-drivers/scripts/README.md)).
2. [`kernel-drivers/tests/`](kernel-drivers/tests/README.md) — decode, encode (PSNR/fps), and full HW
   transcode smoke tests, with pass criteria and input-regeneration recipes.

## 8. Non-root access & the GDM greeter

- **Every user in the `video` group**: [`packaging/codec-udev/`](packaging/codec-udev/README.md)
  packages the §4-step-4 rule as a deb (`rk3588-codec-udev`). The canonical
  rule file is [`kernel-drivers/scripts/99-rockchip-codec.rules`](kernel-drivers/scripts/99-rockchip-codec.rules).
- **The GDM login screen** (only if you run
  [`apps/gnome-remote-desktop/`](apps/gnome-remote-desktop/README.md) and want the
  *greeter* hardware-encoded too): the opt-in
  [`packaging/gdm-hwenc/`](packaging/gdm-hwenc/README.md) deb grants the `gdm`
  group ACL access. Deliberately separate — it widens the security boundary.

## 9. Userspace handoff — you have a kernel, not an encoder

A validated kernel gives you `/dev/mpp_service` + `/dev/rga` and **no encoder
binary**. Get userspace one of two ways:

- **Build it**: [`video-libraries/ffmpeg/README.md`](video-libraries/ffmpeg/README.md) is the end-to-end recipe
  — building `rockchip-linux/mpp` (`librockchip_mpp` + `mpi_enc_test`/
  `mpi_dec_test`), staging `librga`, then building
  [`ffmpeg-rockchip`](https://github.com/nyanmisaka/ffmpeg-rockchip) with
  `h264_rkmpp`/`hevc_rkmpp`/`scale_rkrga`. This is the hardware-validated
  combination ([`kernel-drivers/tests/`](kernel-drivers/tests/README.md) uses it).
- **Install it packaged**: follow the newcomer-facing
  [`PPA guide`](docs/ppa-support.md). Reproducible source-package mechanics live
  under [`packaging/ppa/`](packaging/ppa/README.md), while
  [`status.md`](status.md) track 9 and [W05](status.md#watch-w05) own the dated
  qualification and live-publication facts. The established local-deb flow
  remains in [`packaging/README.md`](packaging/README.md) § Operations.

Player note: the rkmpp decoders are standalone AVCodecs, **not** `AVHWAccel` —
mpv needs `--hwdec=rkmpp` / `--vd=h264_rkmpp`, VLC 3.x cannot select them at
all ([`packaging/README.md`](packaging/README.md) § Player caveat, the
canonical copy).

Prove the whole chain with `sudo bash kernel-drivers/tests/transcode-test.sh` — `rkmpp`/
`rkrga` have no software fallback, so a pass *is* proof the hardware ran.
