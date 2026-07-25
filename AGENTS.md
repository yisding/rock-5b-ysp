# Agent instructions

Environment-specific overrides for agents working in this repository. The
working contract — where a change belongs, the evidence lifecycle, how to update
status, and the handoff gate (`bash scripts/check-repo.sh`) — is
[`CONTRIBUTING.md`](CONTRIBUTING.md); read that first. This file holds only the
things that differ from ordinary practice on this machine.

## GitHub workflow

- Push completed changes directly to `main`; do not open pull requests.
- Run all `gh` CLI commands outside the sandbox by requesting escalated permissions up front.

## Native package builds

- Run Debian/native package builds with `PATH=/usr/sbin:/usr/bin:/sbin:/bin` so Meson uses `/usr/bin/pkg-config` and the Ubuntu multiarch package metadata.
- Do not let Homebrew/Linuxbrew's `pkg-config` drive these builds. It cannot see system entries such as `libdrm.pc` and has repeatedly produced false missing-dependency failures.
