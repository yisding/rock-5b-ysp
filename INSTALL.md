# INSTALL — hardware codecs on a Radxa ROCK 5B

The one page for **"I want the RK3588 hardware codecs working on my board."**
It chooses a delivery model, walks the canonical quickstart, and hands off to
userspace. Deep dives are linked at every step; if you only read one other
page afterwards, make it [`docs/01`](docs/01-how-the-drivers-work.md).

## 1. Choose your delivery model

Two ways to get the **kernel drivers**, plus the **userspace** layer you need
in either case:

| Path | What you get | What it needs | Validation status ([`STATUS.md`](STATUS.md)) | Where |
|------|--------------|---------------|-----------------------------------------------|-------|
| **(a) Combined Armbian kernel** | All three accelerators **built in (`=y`)** — no modules, no overlay | An Armbian build tree (§2) + a kernel install/reboot | ✅ **Hardware-validated** (build `Pb6ab-Cb831`, [`docs/04`](docs/04-status.md)) | [`scripts/`](scripts/README.md) + [`patches/`](patches/README.md) |
| **(b) DKMS on a stock kernel** | `rk_vcodec.ko` + `rga3.ko`, auto-rebuilt on every kernel update, + a boot-time DT overlay | A *stock* Armbian 6.18+ kernel, `dkms` + `dtc` installed | ⚠️ Compile-tested on **6.18 only**; overlay dtc-validated, **not boot-validated** | [`packaging/dkms/`](packaging/dkms/README.md) |
| **(c) Userspace** (needed by **both** kernel paths) | `librockchip_mpp` + `librga` + an rkmpp-enabled FFmpeg | A working kernel path (a) or (b), + the udev rule (§6) | ffmpeg-rockchip build: hardware-validated; PPA: local builds OK 2026-06-30, **nothing uploaded yet** | [`ffmpeg/`](ffmpeg/README.md), [`packaging/ppa/`](packaging/ppa/README.md) |

> **⚠️ Hard warning: (a) and (b) are mutually exclusive.** On a kernel that
> already carries the drivers `=y` (the combined kernel), the DKMS build fails
> `modpost` with `'…' exported twice` — the module's exports clash with
> vmlinux. Pick **one** kernel path. ([`packaging/dkms/README.md`](packaging/dkms/README.md)
> caveat 1; restated in the deploy hub, [`packaging/README.md`](packaging/README.md).)
>
> The **udev rule (§6) is needed on both paths** — no kernel path makes the
> device nodes usable without root by itself.

Not sure? Take **(a)** — it is the only path validated end-to-end on hardware.
Take (b) only if you cannot replace the kernel and accept the not-boot-validated
overlay gate.

## 2. Prerequisites (path a)

`scripts/build-combined-kernel.sh` expects an Armbian build tree at
**`<repo>/armbian-build`** (a gitignored sibling of `scripts/`):

```bash
git clone https://github.com/armbian/build "$(git rev-parse --show-toplevel)/armbian-build"
```

Debs land in `<repo>/armbian-build/output/debs` — exactly where
`install-combined-kernel.sh` looks by default, so the build → install handoff
needs no path edits. Background on the patch mechanism (userpatches, zero edits
to Armbian's own files, the `media-0001` collision):
[`docs/08`](docs/08-armbian-packaging.md).

For **vanilla mainline** (no Armbian) the driver patch applies as-is but the
decoder DT must be inline — follow [`docs/09`](docs/09-vanilla-kernel.md)
instead of this quickstart.

## 3. Canonical quickstart (path a — combined kernel)

```bash
# 1. Stage the two port patches as Armbian userpatches
#    (a fresh clone has no userpatches/ tree yet):
mkdir -p armbian-build/userpatches/kernel/archive/rockchip64-6.18
cp patches/rk3588-rkvenc2-0*.patch \
   armbian-build/userpatches/kernel/archive/rockchip64-6.18/

# 2. Build (~80-90 min cold, ~10-15 warm). USE_CCACHE must be an ARGUMENT,
#    not an env var -- the wrapper gets this right (docs/10):
bash scripts/build-combined-kernel.sh        # prints the new P####-C#### hash

# 3. Install (pin the hash the build printed), reboot, validate:
sudo PHASH='P####-C####' bash scripts/install-combined-kernel.sh
sudo reboot
sudo bash scripts/validate-combined.sh       # /dev/mpp_service, 4 cores, /dev/rga

# 4. Non-root device access (recommended; REQUIRED for non-root ffmpeg).
#    dma_heap is required, not just mpp_service -- rkmpp allocates buffers
#    there (docs/10). You must also be in the `video` group:
sudo cp scripts/99-rockchip-codec.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

A green `validate-combined.sh` shows the two encoder cores (`rkvenc-core0/1`),
the two decoder cores (`video-codec0/1` on the combined kernel — the DT keeps
mainline's node name, see [`docs/07`](docs/07-device-tree.md); pre-combined
revisions said `rkvdec-core0/1`), and `/dev/rga`.

## 4. PHASH pinning — don't install the wrong build

Armbian bakes a `P####-C####` pair into every kernel deb name: `P####` hashes
the **applied patch set**, `C####` the **kernel config** — so the pair names an
*exact* build ([`GLOSSARY.md`](GLOSSARY.md)). `install-combined-kernel.sh`
matches debs on `HASH` (kernel version) + `PHASH` so it can never grab a stale
deb from `output/debs`. Workflow:

1. `build-combined-kernel.sh` prints the new hash at the end of every build.
2. Pass it to the installer (`sudo PHASH='…' bash scripts/install-combined-kernel.sh`)
   or update the `PHASH` default in the script.
3. **Add a row to the log below** so the hash stays decodable later.

### Hash ↔ patch-revision log

| PHASH | Kernel | Patch set | Validated | Notes |
|-------|--------|-----------|-----------|-------|
| `Pb6ab-Cb831` | 6.18.37-current-rockchip64 | `patches/rk3588-rkvenc2-01` + `02` (current revision) | ✅ hardware ([`docs/04`](docs/04-status.md); tests re-run 2026-07-01) | The pinned default in `install-combined-kernel.sh`. |
| `P8c75` (config hash not recorded) | 6.18.37 | functionally-identical predecessor revision | ✅ ([`docs/04`](docs/04-status.md)) | Superseded by `Pb6ab-Cb831`. |

(Every new build you install gets a row; a PHASH change with *unchanged*
`patches/` means the Armbian patch stack moved — run the
[`docs/12` §4](docs/12-resyncing.md) bump checklist.)

## 5. Path b — DKMS on a stock kernel

Full instructions (KSRC reconstruction, out-of-tree Kbuild details, caveats):
[`packaging/dkms/README.md`](packaging/dkms/README.md). The shape:

```bash
# build the deb (stages source from a v6.18 + patch-01 tree -- docs/00 §1):
KSRC=/path/to/linux-6.18-rkvenc/drivers/video/rockchip bash packaging/dkms/build-deb.sh
# on a STOCK-kernel board:
sudo apt install dkms device-tree-compiler
sudo dpkg -i packaging/dkms/build/rk3588-vcodec-dkms_1.0_arm64.deb
# add rk3588-rock5b-vcodec to user_overlays= in /boot/armbianEnv.txt, reboot
```

Then validate exactly as in §3 (`validate-combined.sh` works for both paths).
Remember: **the overlay is not boot-validated** ([`STATUS.md`](STATUS.md)) and
the package must never be installed on the combined kernel (§1).

## 6. Validate, then exercise real frames

1. `sudo bash scripts/validate-combined.sh` — devices, 4 cores, clean-probe
   dmesg sweep ([`scripts/README.md`](scripts/README.md)).
2. [`tests/`](tests/README.md) — decode, encode (PSNR/fps), and full HW
   transcode smoke tests, with pass criteria and input-regeneration recipes.

## 7. Non-root access & the GDM greeter

- **Every user in the `video` group**: [`packaging/codec-udev/`](packaging/codec-udev/README.md)
  packages the §3-step-4 rule as a deb (`rk3588-codec-udev`). The canonical
  rule file is [`scripts/99-rockchip-codec.rules`](scripts/99-rockchip-codec.rules).
- **The GDM login screen** (only if you run
  [`gnome-remote-desktop/`](gnome-remote-desktop/README.md) and want the
  *greeter* hardware-encoded too): the opt-in
  [`packaging/gdm-hwenc/`](packaging/gdm-hwenc/README.md) deb grants the `gdm`
  group ACL access. Deliberately separate — it widens the security boundary.

## 8. Userspace handoff — you have a kernel, not an encoder

A validated kernel gives you `/dev/mpp_service` + `/dev/rga` and **no encoder
binary**. Get userspace one of two ways:

- **Build it**: [`ffmpeg/README.md`](ffmpeg/README.md) is the end-to-end recipe
  — building `rockchip-linux/mpp` (`librockchip_mpp` + `mpi_enc_test`/
  `mpi_dec_test`), staging `librga`, then building
  [`ffmpeg-rockchip`](https://github.com/nyanmisaka/ffmpeg-rockchip) with
  `h264_rkmpp`/`hevc_rkmpp`/`scale_rkrga`. This is the hardware-validated
  combination ([`tests/`](tests/README.md) uses it).
- **Install it packaged**: the [`packaging/ppa/`](packaging/ppa/README.md)
  source packages build the whole stack (MPP + librga + FFmpeg 8.1.2+rkmpp +
  GRD) — but **nothing is on Launchpad yet** ([`STATUS.md`](STATUS.md)); until
  then the packaged route is the local-deb flow documented in
  [`packaging/README.md`](packaging/README.md) § Operations (including the
  `apt-mark hold` pin and the exact rollback).

Player note: the rkmpp decoders are standalone AVCodecs, **not** `AVHWAccel` —
mpv needs `--hwdec=rkmpp` / `--vd=h264_rkmpp`, VLC 3.x cannot select them at
all ([`packaging/README.md`](packaging/README.md) § Player caveat, the
canonical copy).

Prove the whole chain with `sudo bash tests/transcode-test.sh` — `rkmpp`/
`rkrga` have no software fallback, so a pass *is* proof the hardware ran.
