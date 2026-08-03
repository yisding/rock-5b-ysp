# IEP2 ioctl-level harnesses

Three programs that talk to `/dev/mpp_service` as MPP client 28 directly,
bypassing libmpp. They cover the safety-review gates that `iep2_test` cannot
reach, because it validates its own inputs long before the kernel sees them —
its command line refuses anything above 1920x1088, which is exactly the bound
the driver's DMA-span check exists to enforce.

| Program | Gate |
| --- | --- |
| `iep2_negative.c` | malformed requests must be refused synchronously |
| `iep2_encoding.c` | packed and offset-alone address encodings on one session |
| `iep2_stress.c` | close-versus-completion, import churn, concurrent sessions |

## Build

They compile against the MPP source tree for the request and parameter structs;
the driver validates `sizeof` exactly, so the structs must come from the real
headers rather than being retyped.

```sh
S=~/Code/rock-5b/rockchip-userspace/mpp-rockchip
gcc -O1 -o iep2_negative iep2_negative.c \
  -I$S/inc -I$S/osal/inc -I$S/mpp/vproc/iep2 -I$S/mpp/vproc/inc
```

## Run

```sh
./iep2_negative              # 18 checks, exits nonzero on any deviation
./iep2_encoding 50           # rounds per direction
./iep2_stress 300 6          # iterations, concurrent processes
```

Each exits nonzero on failure. None of them scan the kernel log, so pair them
with a `journalctl -k` diff around the run — a driver that accepts a malformed
task and faults later would otherwise look like a pass.

## Reading the results

`iep2_negative` submits a baseline task first and again at the end. Both must be
accepted: without the opening baseline a rejection proves nothing (it could be
failing for an unrelated reason), and without the closing one a driver that
wedged its session after the first refusal would still score full marks.

The submitting ioctl only queues the message batch, so it returns 0 even for a
task the driver refuses — the refusal surfaces when the client polls for
completion. All three harnesses therefore check the poll, not just the submit.
