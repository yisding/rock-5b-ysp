# RK3588 MPP/RGA Syzkaller Seeds

This directory holds the first structure-aware fuzzing scaffold for the
clean-room `/dev/mpp_service` and `/dev/rga` rewrite drivers.

`rockchip_mpp_rga.txt` is a syzlang draft for the current userspace-visible ABI:

- MPP `MPP_IOC_CFG_V1` query/control messages, including payload-bearing
  commands and disabled register-submit shapes.
- RGA legacy version/no-op ioctls, import/release, request create/cancel, and
  disabled legacy/request submit shapes.

Submit-capable calls are marked `disabled` or `no_generate` in the draft. Enable
them only on a sacrificial RK3588 fuzzing host with the IOMMU on, a serial
console, `panic=10`, ramoops, and the KASAN/KCOV debug kernel described in
`../../docs/debug-kernel.md`.

Run the local consistency check after updating the ABI probe headers or the
syzlang file:

```sh
kernel-drivers/tests/syzkaller/check-rockchip-syzlang.sh
```

That mandatory check verifies that the ioctl numbers and struct sizes recorded
in the syzlang draft still match `kernel-drivers/tests/abi-probe.sh`, accepting
the probe's `77` skip exit when the device nodes are not present. The same check
is part of `VALIDATE_ONLY=1 kernel-drivers/tests/rewrite-conformance-run.sh`, so
the normal device-free conformance validation fails if the draft's ABI constants
drift.

If an upstream syzkaller checkout and Go toolchain are available, also compile
the draft with syzkaller's real description generator:

```sh
SYZKALLER_DIR=/path/to/syzkaller \
kernel-drivers/tests/syzkaller/check-rockchip-syzlang-compile.sh
```

The compile check copies the syzkaller tree to a temporary directory, installs
the Rockchip draft as `sys/linux/dev_rockchip_mpp_rga.txt`, and runs
`make descriptions` there so the source checkout is not dirtied. The conformance
runner calls this as an optional step; it exits `77` and is reported as skipped
when `SYZKALLER_DIR` or Go is missing. Set `SYZKALLER_REQUIRE_COMPILE=1` to make
that absence a hard failure for a fuzzing-prep host.
