# ROCK 5B boot hang recurred with the patched Plymouth provably in the boot path

> Scope: ROCK 5B dev board, kernel `6.18.38-current-rockchip64` build `#7`; recurrence of the boot stall analyzed in [`2026-07-22-rock5b-boot-hang-plymouth-initramfs-daemon.md`](2026-07-22-rock5b-boot-hang-plymouth-initramfs-daemon.md)
> Source: on-board `journalctl` (failed boot `ef4e0754…`, 2026-07-23 09:56 PDT, and adjacent healthy boots), `dpkg.log`, extraction of the live `/boot/uInitrd`, and disassembly of the installed vs. stock `libply-splash-core.so.5.0.0`
> Date: 2026-07-23
> Trust: MEASURED (recurrence + fingerprint + binary/initramfs identity); CODE-INSPECTED (disassembly proves the fix is in the running binary); the prior finding's internal CSI-loop attribution is thereby FALSIFIED as the sole cause

## Result

The boot hung again on 2026-07-23 at 09:56 with the exact fingerprint of the
2026-07-22 failures — and this time the initramfs daemon **provably contained
the upstream `45655f12` incomplete-CSI fix**. The one-line parser fix is
therefore not sufficient: the incomplete-CSI infinite loop is **not the
board's actual internal wedge** (or at minimum not the only one). The
boot-transaction analysis of the prior finding is unchanged and reconfirmed;
the internal root cause of the daemon wedge is back to **unknown**.

## The failed boot ran the patched daemon

Chain of custody, all on 2026-07-23:

| Time (PDT) | Event |
|---|---|
| 05:35–05:37 | `plymouth`/`libplymouth5` `…-0ubuntu8.1~rk1` installed from the YSP PPA (`dpkg.log`) |
| 05:41:24 | `/boot/initrd.img-6.18.38-current-rockchip64` regenerated |
| 05:41:25 | `/boot/uInitrd-6.18.38-current-rockchip64` regenerated, `uInitrd` symlink updated |
| 05:53 | Boot `-2` (`9930cbde…`): **healthy** — `SIGRTMIN+20` from `plymouthd` PID 243 at 16.559 s, read-write finishes 16.566 s, `sysinit.target` 20.371 s |
| 09:56 | Boot `-1` (`ef4e0754…`): **hung** — read-write starting 13.948 s, plymouth-start starting 15.232 s, then no `SIGRTMIN+20`, neither job completes, no `sysinit.target`; the chronic networkd wait-online timeout is again the last persisted line |
| ~09:58 | Board reset; boot `0` healthy |

Identity proofs:

- `uInitrd` payload (64-byte u-boot header stripped) is byte-identical to the
  regenerated `initrd.img`.
- Inside that image, `usr/sbin/plymouthd`
  (`cc0d7b477ba7…`) and `usr/lib/aarch64-linux-gnu/libply-splash-core.so.5.0.0`
  (`fbab0dc4a0c2…`) are byte-identical to the installed `~rk1` files;
  `dpkg -V` on both packages is clean (one unrelated conffile).
- Boot `-1`'s kernel line confirms it booted `6.18.38-current-rockchip64 #7`,
  i.e. the initrd/uInitrd pair above.

## The `~rk1` binary provably contains the fix

Both libraries are stripped, so this was verified by disassembling the
`on_key_event` CSI scan loop (located via its `0x1b`/`0x5b` compares and the
`sub w0,w0,#0x40; cmp w0,#0x3e` final-byte range check):

- **Stock `0ubuntu8`** (`b8dc`–`bb18` region): when the scan exhausts the
  buffer with no final byte, `bae8: b.ls b908` branches back to the **outer
  per-character loop head without advancing the index** — the vulnerable
  `continue`, i.e. the infinite loop of upstream issue #321.
- **Installed `~rk1`**: the same no-final-byte condition falls through to
  `ply_buffer_remove_bytes` (drop the processed prefix, keep the incomplete
  sequence) and leaves the loop — exactly upstream `45655f12`'s `break`
  semantics.

## Tested hypothesis: "hangs only on the first boot after a kernel install"

Refuted as a strict gate by this very failure. The timeline above shows the
2026-07-23 hang hit the **second** boot of build `#7`: kernel installed 05:40,
initramfs/uInitrd regenerated 05:41, first boot 05:53 **healthy**, and
`dpkg.log` records **zero package activity** between 05:53 and the 09:56
reboot (a clean, deliberate `systemd-reboot`). Healthy boot `-2`, hung boot
`-1`, and healthy boot `0` all ran byte-identical kernel + uInitrd. So
first-boot-after-install is neither necessary (this hang) nor sufficient
(05:53 was fine).

Why the correlation looks real anyway:

- **Selection bias:** this board essentially only reboots right after
  installing a fresh trunk kernel build (boots otherwise run for hours). Most
  reboot opportunities *are* first boots, so an intermittent hang will mostly
  land on them. Both 2026-07-22 hangs (builds `#3`, `#6`) were indeed first
  boots after the 07:27 and 21:24 installs.
- A genuinely elevated first-boot probability can't be excluded — the first
  boot after package installs runs the one-shot `ConditionNeedsUpdate`
  services (hwdb/catalog/ldconfig) and shifts early-boot timing — but the
  2026-07-23 hung boot had those **skipped**, i.e. it hung *without* the
  first-boot timing perturbation.

Net: the trigger is an intermittent race, not an install-state difference in
the boot artifacts.

## Implications

1. The prior finding's internal attribution ("high-confidence source match" to
   the incomplete-CSI loop) is **downgraded**: with the fix installed,
   regenerated into the initramfs, and byte-verified in the booted image, the
   identical wedge recurred. The CSI bug is real in the stock package but it is
   not what wedges this board — or a second, independent wedge path exists.
2. The prior finding's evidence boundary anticipated exactly this: no live
   `plymouthd` stack or input bytes were ever captured. That capture is now the
   discriminating test, not optional hardening.
3. A quick source check eliminates the most tempting alternative: terminal fds
   are opened `O_RDWR | O_NOCTTY | O_NONBLOCK` (`ply-terminal.c:602`), so a
   flow-stopped `ttyS2` cannot wedge the event loop in a blocking `write()`.
   No other candidate has been inspected yet.

## Follow-up

- The board-level fix recommended on 2026-07-22 — `plymouth.enable=0` appended
  to `extraargs=` in `/boot/armbianEnv.txt` — was **never applied** (the failed
  boot's cmdline confirms). It remains the only known-reliable mitigation and
  is now also the clean exclusion test.
- To root-cause instead: before the next hang, (a) enable
  `debug-shell.service` (early root shell on `tty9`, `DefaultDependencies=no`,
  starts without `sysinit.target`), and (b) add
  `plymouth.debug=stream:/dev/ttyS2`. On the next hang, do **not** reset —
  capture the inherited `plymouthd`'s `/proc/<pid>/stack`, `wchan`,
  `/proc/<pid>/syscall`, and fds from the debug shell. That single capture
  discriminates a userspace spin (CSI-style loop elsewhere) from a blocked
  syscall.
- The PPA backport (`0ubuntu8.1~rk1`) is correct and harmless but
  **insufficient**; keep it installed, but stop treating it as the fix.

Tracked as status.md watchlist [`W20`](../status.md#watch-w20).
