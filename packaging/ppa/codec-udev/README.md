# codec-udev/ - PPA native source package

Native source-package wrapper for `rk3588-codec-udev`. It installs the
canonical Rockchip codec access rule for `/dev/mpp_service`, `/dev/rga`, and
the DMA heaps so unprivileged desktop users can use RKMPP/RKRGA.

The rule remains canonical in
[`../../../kernel-drivers/scripts/99-rockchip-codec.rules`](../../../kernel-drivers/scripts/99-rockchip-codec.rules).
`build-source-packages.sh codec-udev` copies it into the generated native
source tree before running `dpkg-buildpackage -S`.
