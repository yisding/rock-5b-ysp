# RK3588 HDMI 2.1 (FRL) forward port — plan

What it would take to bring HDMI 2.0 and HDMI 2.1 FRL display output to the
ysp production 6.18 kernel line. Today that kernel's `dw-hdmi-qp` bridge
rejects every mode above 340 MHz TMDS character rate
(`HDMI14_MAX_TMDSCLK` at `drivers/gpu/drm/bridge/synopsys/dw-hdmi-qp.c:36`,
enforced in `dw_hdmi_qp_bridge_tmds_char_rate_valid()`), so the practical
ceiling on the ROCK 5B HDMI ports is 4K@30. Two missing tiers sit above it:

1. **HDMI 2.0** — SCDC scrambling and the high TMDS clock ratio, up to
   600 MHz: 4K@60. Donor code is the public Collabora `dw-hdmi-qp` scrambling
   series already integrated in the maxline `public` profile.
2. **HDMI 2.1 FRL** — fixed-rate-link training, PHY FRL/TxFFE modes, and VOP2
   ACLK scaling: 4K@120 and other high-rate modes. Donor code is the Collabora
   WIP FRL stack already reconciled once in the maxline `wip` profile.

Both donors were reconciled against Linux 7.2-rc6 in the 2026-08-02 maxline
refresh, so this port is a **backport across DRM API drift**, with the maxline
integration record as the map. Neither tier has ever been booted on hardware
in any tree this repository tracks (maxline `booted_on_rock_5b: false`).

> **Nothing here has been started.** This document is DESIGN only. No patch,
> branch, or build exists for either stage as of 2026-08-23.

> Source pins used throughout: forward-port target
> `../rock-5b/kernel/linux-6.18-rkvenc-av1-fwport` @ `e7ff978398825`
> (6.18.44, series tip `0097`) · maxline base Torvalds `075b74841bd0`
> (7.2.0-rc6) · maxline `public` @ `e6951bc3f935` · maxline `wip` @
> `73d29539f7bb` · donor identities in
> [`../maxline/public-series.tsv`](../maxline/public-series.tsv) and
> [`../maxline/wip-donors.tsv`](../maxline/wip-donors.tsv).

## 0. Baseline — what 6.18 already has, verified in the target tree

The gap is narrower than "no HDMI 2.1 anywhere": 6.18 already carries the
modern mainline display stack the donors build on.

| Present in 6.18.44 target tree | Missing |
|---|---|
| VOP2, `dw-hdmi-qp` bridge, `dw_hdmi_qp-rockchip` glue, `samsung-hdptx` PHY | Everything above 340 MHz TMDS: scrambling, high-clock-ratio SCDC writes |
| The new DRM HDMI bridge framework (the driver implements `tmds_char_rate_valid`) | FRL registers in `include/drm/display/drm_scdc.h` (zero `FRL` matches), FRL link-training helpers, FRL mode-validation hook |
| SCDC read/write helpers | PHY FRL operating mode and TxFFE level control in `samsung-hdptx` |
| Working TMDS output ≤ 340 MHz (daily-driver desktop) | VOP2 ACLK scaling for FRL modes; `frl-enable-gpios` in the ROCK 5B DT |

Consequence: this is additive bridge/helper/PHY work on top of the stack the
board already runs. No vendor DRM code is required.

## 1. Donor decision

Three candidate donors; the choice shapes everything downstream.

| Donor | Verdict | Why |
|---|---|---|
| Rockchip 6.1 BSP display stack ([`../bsp/05-display-panels-drm.md`](../bsp/05-display-panels-drm.md)) | **Rejected** | The BSP replaces the whole DRM display stack (vendor VOP2, vendor HDMI TX). The codec forward port worked because vendor MPP/RGA is additive — new device nodes beside mainline. Display is not additive: a vendor DRM port would collide with the mainline VOP2/`dw-hdmi-qp` the board already depends on for its console and desktop. |
| Collabora mailing-list series and WIP branch directly | Fallback | The raw v10/v9/v5 mboxes and the `collabora-rockchip-release` commits are pinned per-patch in the two TSVs. Usable, but every conflict the maxline refresh already resolved would be re-fought blind. |
| **Maxline reconciled result** (`public` HDMI subset + `wip` FRL delta) | **Chosen** | The 2026-08-02 refresh already reconciled these series against each other and against a real tree, and recorded the decisions ([refresh finding](../../findings/2026-08-02-rk3588-maxline-proposal-refresh.md), [integration decisions](../maxline/README.md#important-integration-decisions)). Port the reconciled patches, using the TSV dispositions (`applied` / `reconciled` / `superseded-by-public-*` / `upstream`) to know what is one feature and what is two revisions of the same feature. |

Direction of adaptation: the donors sit on 7.2-rc6; the target is 6.18. The
maxline Linus-endpoint decisions are precedents for exactly this kind of
boundary — connector state creation via the `reset` callback where
`drm_connector_funcs.atomic_create_state` does not exist, and the older
scoped-bridge-iterator name — but 6.18 predates even that Linus base, so
expect more of the same, resolved the same way: adapt to the older API, note
each boundary in the series README.

## 2. Two stages, strictly ordered

Stage A is independently valuable (4K@60 on the desk monitor), much lower
risk, and a hard prerequisite: the FRL WIP commits are written against the
public scrambling/SCDC/N-CTS result (three donor rows are
`superseded-by-public-*`). Do not start Stage B until Stage A has hardware
evidence.

### Stage A — HDMI 2.0 (scrambling, ≤ 600 MHz, 4K@60)

Donor series, by `public-series.tsv` id:

| Series id | Rev | Patches | Role |
|---|---|---:|---|
| `hdmi-2-scrambling` | v10 | 69 | Core: SCDC scrambling, high TMDS clock ratio, connector-state and HPD rework in `dw-hdmi-qp` |
| `hdmi-scdc-debugfs` | v9 | 5 | SCDC link health + debugfs — the observability the validation plan relies on |
| `hdptx-clock-fixes` | v5 | 10 | Samsung HDPTX clock correctness at high TMDS rates |
| `hdmi-qp-audio-ncts` | v3 | 1 | Audio N/CTS at the new rates (replaces the legacy tables) |
| `hdmi-yuv` | v3 | 14 | Optional: 10-bit/YUV output formats. Take only if it falls out of the scrambling conflicts cheaply; otherwise defer. |

The 69-patch scrambling series is the size risk. Phase A0 (below) decides
whether 6.18's HDMI-bridge framework is close enough to take it near-verbatim
or whether a subset must be carved; a large carve is a go/no-go signal, not
something to push through silently.

### Stage B — HDMI 2.1 FRL (4K@120)

Donor is the 19-commit maxline `wip` delta; per `wip-donors.tsv` the
functional pieces are:

- `drm/display`: SCDC FRL register definitions and link-training control
  helpers; the FRL mode-validation hook; bridge-connector rate-validation
  wiring.
- `dw-hdmi-qp`: FRL support, link-config consolidation, TxFFE level control.
- `samsung-hdptx`: FRL TxFFE level control, PHY config after module reload.
- `dw_hdmi_qp-rockchip`: FRL operating-mode and TxFFE wiring; VOP2 ACLK
  scale-up for FRL modes; `SND_SOC_HDMI_CODEC` selects.
- DT: `frl-enable-gpios` for the ROCK 5B (in maxline it rides the public DT;
  here it must land in the YSP DTB path the forward-port packages ship).

Rows marked `upstream` in the TSV need a per-row check against 6.18 — they
were upstream relative to 7.2-rc6, and some (for example the `detect_ctx`
bridge hook) may not exist in 6.18 and so rejoin the port as prerequisites.

## 3. Series and repository mechanics

- **New tracked series, not an extension of `0001`–`0097`.** The codec/RGA
  series has its own qualification history and bisection value
  ([series README](../../kernel-drivers/patches/forward-port-rk3588/README.md));
  display churn must not re-open it. Create a separate numbered series
  directory (proposal: `kernel-drivers/patches/hdmi-display/`, final home
  decided at first commit) that applies on top of the codec series tip, with
  its own README owning order and API-boundary notes.
- **Branch**: a new branch off the current `rk3588-video-6.18` tip in
  `../rock-5b/kernel/`, e.g. `rk3588-hdmi-6.18`, so codec-series work and
  display work never contend for one branch head.
- **Builds** under `../rock-5b/build/hdmi-fwport/` with ccache, per the
  repository build-workspace rules.
- **Hygiene bar**: same as the codec series — strict checkpatch on the new
  patches and a clean focused `W=1 WERROR=1` build of the touched DRM/PHY
  objects, before any full build.
- **Delivery**: same Armbian-injection/PPA package pipeline as the codec
  series, but only after local install with the recovery-first order in
  [`install.md`](../../install.md) (known-good kernel retained, SD rescue
  available, `kernel-revert.sh` tested path).

## 4. Risk register

### 4.1 API drift is the schedule risk

Backporting 7.2-era DRM series onto 6.18 is the inverse of what the maxline
refresh did, against a two-major-versions-wider gap. The HDMI connector
helper framework was still moving fast in this window; if Phase A0 finds the
6.18 framework too far behind the v10 series' assumptions, the honest
fallback is to carry the framework prerequisite patches too — growing the
series — or to stop and say 4K@60 costs more than planned. Do not invent a
hybrid half-framework.

### 4.2 FRL has zero hardware evidence anywhere

The WIP stack is explicitly work-in-progress; even maxline has never booted
it. Treat every Stage B behavior — training, mode selection, recovery to
TMDS — as unproven until this board shows it.

### 4.3 External dependency: an FRL sink and cable

Stage B cannot be validated without an HDMI 2.1 sink (4K@120-capable) and a
certified Ultra High Speed cable. If none is on hand, Stage B ends at
"compiles, TMDS regression-free, FRL paths dormant" — which must then be
stated as the boundary, not silently promoted. Stage A validates on any
4K@60-capable monitor.

### 4.4 The display is the recovery path

HDMI console output is how boot failures, ramoops triage, and hang
diagnostics get seen on this board. A display regression is therefore worse
than a codec regression of equal size. Primary acceptance bar for **both**
stages: every mode that works today keeps working, and a sink that
negotiates neither FRL nor scrambling gets exactly the current behavior.

### 4.5 Interaction with the codec/RGA stack

VOP2 ACLK scaling touches the clock tree, and display patches ride the same
kernel package as the qualified codec series. After each stage's install,
re-run the codec smoke set (the 12 MPP cases and the quick librga set from
[`kernel-drivers/tests/`](../../kernel-drivers/tests/README.md)) to show
non-interference before recording the display result.

## 5. Phases

| Phase | Deliverable | Exit signal |
|---|---|---|
| A0 survey | Per-patch map of the five Stage A series against 6.18: applies / adapt / needs-prereq / drop, plus the `upstream`-row audit from §2 | Written scope decision: take-mostly-verbatim vs carve vs no-go |
| A1 port | Stage A series on `rk3588-hdmi-6.18`; checkpatch + focused `W=1` clean | Full `Image modules dtbs` build passes |
| A2 hardware | Local package install, recovery retained | Stage A validation gates (§6) pass; finding recorded |
| B0 port | FRL delta adapted on top of A; DT `frl-enable-gpios` in the YSP DTB | Full build passes; TMDS-only boot regression-free |
| B1 hardware | FRL sink campaign | Stage B validation gates pass; finding recorded |
| Ship | PPA publication of the combined series | Status track added with the dated verdict |

Per repository convention, no `status.md` track is added until A2 produces
runtime evidence; until then this document plus its README entry is the
record. The validation campaigns should also produce the connector-and-mode
matrix that [`support-coverage`](../../docs/support-coverage.md) row C10
currently lists as missing.

## 6. Validation gates

Baseline first, on the current kernel, per
[`system-baseline`](../../docs/system-baseline.md): connected sink EDID,
current mode list, active mode, and a dmesg display-error scan — so "no
regression" has a recorded before-state.

Stage A (existing monitor): 4K@60 (or the sink's max ≤ 600 MHz mode) is
listed, selectable, and stable under desktop use; SCDC debugfs shows
scrambling active; audio plays at the new mode; hotplug and reboot
persistence hold; the dmesg scan stays clean; codec smoke passes (§4.5);
then a bounded soak at the new mode.

Stage B (FRL sink): FRL link training succeeds and is visible in the logs;
4K@120 scanout is stable; unplugging the FRL sink and attaching a
TMDS-only sink falls back cleanly, and back again; audio at FRL rates;
suspend/resume or DPMS cycling at the FRL mode if configured; codec smoke;
soak. Explicit negative gate: with no FRL sink attached, behavior is
byte-for-byte the Stage A behavior.

Every campaign lands as a dated finding with exact source, package, DTB, and
sink identity, then rolls up per the evidence lifecycle.

## 7. Explicitly out of scope

- HDMI 8K modes, ARC/eARC, and HDCP — the status document's separate TODOs;
  no public donor code exists, and FRL does not make them complete.
- HDMI input (`hdmirx`, support-coverage C14) and the `hdmirx-audio` series.
- DisplayPort / USB-C DP-AltMode paths (separate DW-DP series, separate
  validation).
- The maxline profiles themselves — they already carry these donors at
  7.2-rc6; this plan changes nothing there.
- Upstream submission of any adaptation — consumption port only.
