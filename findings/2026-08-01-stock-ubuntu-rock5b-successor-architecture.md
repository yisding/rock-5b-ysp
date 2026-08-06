# A ROCK 5B-only Ubuntu successor should keep Resolute userspace stock and own the board kernel and firmware

> Scope: C01 board/OS identity, C02 boot firmware, C03 kernel delivery, and
> C04–C19 release coverage for a proposed Radxa ROCK 5B-only Ubuntu 26.04 image
> Source: Canonical's [Ubuntu 26.04 release images](https://cdimage.ubuntu.com/ubuntu/releases/resolute/release/),
> [26.04 release notes](https://documentation.ubuntu.com/release-notes/26.04/),
> [Image Cookbook overview](https://ubuntu.com/hardware/docs/image-cookbook/overview/),
> [`image-definition.yaml` reference](https://ubuntu.com/hardware/docs/image-cookbook/reference/image_definition/),
> [`gadget.yaml` reference](https://ubuntu.com/hardware/docs/image-cookbook/reference/gadget_definition/),
> [firmware requirements](https://ubuntu.com/hardware/docs/image-cookbook/reference/firmware_requirements/),
> and [`ukpack` kernel guide](https://ubuntu.com/hardware/docs/image-cookbook/howto/packaging/package_kernel/),
> inspected 2026-08-01; [kernel.org release table](https://www.kernel.org/category/releases.html),
> inspected 2026-08-01; local source and evidence owners linked below
> Date: 2026-08-01
> Trust: SOURCE-INSPECTED / CONFIG-INSPECTED for the cited local and external
> inputs; DESIGN for the proposed architecture; INFERRED for effort and release
> sequencing; UNVERIFIED on hardware for the complete successor image

## Result

The useful definition of a successor to `ubuntu-rockchip` is not "Ubuntu with
no board-specific code." It is:

> **Ubuntu 26.04 LTS archive, seeds, services, desktop/server behavior, and
> normal userspace updates, paired with a community-maintained ROCK 5B kernel,
> device tree, boot firmware, and narrowly scoped board packages.**

That boundary matches Canonical's Image Cookbook model. The cookbook explicitly
targets hardware not yet supported by Ubuntu, expects vendor or board-specific
kernel/U-Boot/packages in a PPA, and keeps non-device packages on the Ubuntu
archive. Its image-definition schema (documented as of `ubuntu-image` 3.6.0)
accepts a custom kernel, a gadget, Ubuntu seed or rootfs inputs, PPAs, extra
packages, cloud-init data, fstab entries, and image/manifest artifacts. The
gadget schema can express GPT structures, raw firmware content, an EFI System
Partition, cloud-init data, and an ext4 root filesystem. This is a better
starting point than reviving the archived project's fork of `livecd-rootfs` or
post-processing an official image as the release build.

Ubuntu publishes a generic arm64 preinstalled-server image for 26.04. It is a
useful package/boot-integration reference and a smoke-test root filesystem, but
it is not a ROCK 5B image: the board still needs its boot artifacts, exact DTB,
and a kernel with the required RK3588 support. The release manifest carried the
generic Ubuntu 7.0 kernel line, whereas the strongest local board/media evidence
is on the custom 6.18 line. Calling the resulting product simply "stock Ubuntu"
would therefore hide a material support and security boundary.

Linux 6.18 is listed by kernel.org as longterm with projected end of life in
December 2028. It is the best first product kernel because the checked-in
forward-port series is generated against vanilla 6.18 and the deepest ROCK 5B
hardware evidence lives there. That does not align with the whole Ubuntu 26.04
support window, so a maintained image must budget a kernel-LTS transition before
the 6.18 maintenance window ends. A custom kernel also does not inherit
Canonical's generic-kernel security maintenance or Livepatch coverage merely
because its userspace is Ubuntu.

## Source-checked consequences

| Input | What carries forward | What must change or be proved |
|-------|----------------------|-------------------------------|
| [`ubuntu-rockchip` survey](../video-libraries/vaapi/docs/validation.md#consumer-and-sandbox-conclusions) | Board meta/settings concepts, Launchpad source-package patterns, firmware layout clues, and selected media/app packaging are useful quarry. | The project is archived; its multi-board matrices, forked image builder, vendor U-Boot line, blanket PPA priority, package holds, and legacy Chromium integration are not a sustainable base. |
| [Vanilla-kernel guide](../kernel-versions/docs/vanilla-kernel.md) and [forward-port patches](../kernel-drivers/patches/forward-port-rk3588/README.md) | The driver series applies to vanilla 6.18; encoder and RGA device-tree additions are already inline. | The decoder DT must be self-contained. Its Armbian convert-in-place form depends on `media-0001` labels and nodes that vanilla 6.18 does not provide. |
| [Kernel PPA track](../packaging/ppa/README.md) | Source builds, provenance checks, production config work, versioned payload comparison, and Launchpad delivery are reusable. | The current exporter and package identity are Armbian-coupled. The successor must build from a clean pinned tree and use Ubuntu/GRUB/`flash-kernel` lifecycle hooks. |
| [DKMS track](../packaging/dkms/README.md) | It remains useful as a compile/ABI experiment. | It is not the product path: only 6.18 compile/link is established, the overlay is unbooted, and it assumes Armbian DT/overlay plumbing. |
| [U-Boot comparison](../boot-firmware/docs/version-comparison.md) | Upstream has a dedicated ROCK 5B target and a modern EFI/Bootstd-oriented lineage; the inspected vendor line is a deep 2017.09 fork. | The upstream tip is source-inspected, not boot-qualified. A released tag, exact DDR/TPL and BL31 inputs, generated artifact names, raw offsets, EFI/GRUB handoff, Ethernet, storage, and recovery all need hardware proof. |
| Existing media PPA packages | MPP, librga, FFmpeg Rockchip, VA-API, GRD, and udev packaging can be rebuilt against Resolute independently of the Armbian image builder. | Invasive replacements of system FFmpeg or GRD should be opt-in profiles, not part of the stock base promise. Latest driver fixes also retain their current compile/runtime evidence boundaries. |

The durable proposed architecture, package split, boot policy, proof ladder, and
release gates now live in
[`docs/ubuntu-rock5b-image-plan.md`](../docs/ubuntu-rock5b-image-plan.md).

## Boundary

No successor repository, `ubuntu-image` definition, gadget, clean
`linux-rock5b` source package, upstream U-Boot build, or bootable disk image was
created or tested by this survey. Upstream U-Boot has not been hardware-qualified
in this repository. The current 6.18 evidence is heavily media-focused; the
[support coverage inventory](../docs/support-coverage.md) still leaves thermal,
general memory/storage, networking, USB, display, audio, wireless, GPIO, power,
and recovery coverage narrow or unassessed. The estimates and milestone order in
the design are planning judgments, not delivery commitments.
