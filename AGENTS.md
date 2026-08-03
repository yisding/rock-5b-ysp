# Agent instructions

Environment-specific overrides for agents working in this repository. The
working contract — where a change belongs, the evidence lifecycle, how to update
status, and the handoff gate (`bash scripts/check-repo.sh`) — is
[`CONTRIBUTING.md`](CONTRIBUTING.md); read that first. This file holds only the
things that differ from ordinary practice on this machine.

## GitHub workflow

- Push completed changes directly to `main`; do not open pull requests.
- Run all `gh` CLI commands outside the sandbox by requesting escalated permissions up front.

## Build workspace

- Put new build directories and generated build artifacts under
  `../rock-5b/build/`, using a separate subdirectory for each project or task.
  Treat that directory as disposable build state so it can be cleaned up as a
  unit; keep source checkouts and durable evidence outside it.
- Use `ccache` whenever the compiler and build system support it. Keep the
  shared compiler cache under `../rock-5b/build/ccache/`; bypass it only when
  measuring uncached build time or diagnosing cache behavior.

## Native package builds

- Run Debian/native package builds with `PATH=/usr/sbin:/usr/bin:/sbin:/bin` so Meson uses `/usr/bin/pkg-config` and the Ubuntu multiarch package metadata.
- Do not let Homebrew/Linuxbrew's `pkg-config` drive these builds. It cannot see system entries such as `libdrm.pc` and has repeatedly produced false missing-dependency failures.
