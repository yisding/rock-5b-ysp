# RK3588 exposes IEP2 deinterlacing, not VDPP, and the YSP 6.18 port omits IEP2

Promoted and superseded by the maintained
[RK3588 IEP2 versus VDPP guide](../kernel-drivers/iep2/docs/rk3588-iep2-vdpp.md)
and its
[forward-port safety review](../kernel-drivers/iep2/docs/forward-port-safety-review.md).

The original observation remains historically accurate for the installed
`6.18.41-ysp-rockchip64` kernel measured on 2026-08-02: it exposes neither IEP2
client 28 nor VDPP client 29. The external Linux 6.18 source tree has since
gained the IEP2 driver and DT path, so this dated finding is no longer the
canonical source-state description.
