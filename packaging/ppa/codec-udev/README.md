# codec-udev/ - PPA native source package

Native source-package wrapper for `rk3588-codec-udev`. It installs the
canonical Rockchip codec access rule for `/dev/mpp_service`, `/dev/rga`, and
the DMA heaps so unprivileged desktop users can use RKMPP/RKRGA.

The rule remains canonical in
[`../../../kernel-drivers/scripts/99-rockchip-codec.rules`](../../../kernel-drivers/scripts/99-rockchip-codec.rules).
`build-source-packages.sh codec-udev` copies it into the generated native
source tree before running `dpkg-buildpackage -S`.

Version `1.1` reloads the rule, retriggers every existing MPP, RGA, IEP, and
DMA-heap device through its `/sys/class` path, waits for udev to settle, and
requires each resulting device node to be owned by group `video` with mode
`0660`. Devices that are not exposed by the running kernel are skipped.

Source publication `18620729`, arm64-hosted build `33399688`, and the
architecture-independent binary are Published in the recreated main PPA.
Version 1.0 is superseded. Local source/binary builds, lintian, installation,
and live-device permission checks also pass.
