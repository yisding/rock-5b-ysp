# Agent instructions

Environment-specific overrides for agents working in this repository. The
working contract — where a change belongs, the evidence lifecycle, how to update
status, and the handoff gate (`bash scripts/check-repo.sh`) — is
[`CONTRIBUTING.md`](CONTRIBUTING.md); read that first. This file holds only the
things that differ from ordinary practice on this machine.

## Running the handoff gate

This repository is primarily documentation. Most changes are Markdown, and the
gate is scoped to match — do not reach for the full matrix by reflex.

- Run plain `bash scripts/check-repo.sh`. It always checks Markdown links,
  documentation consistency, and whitespace over the whole repository (seconds),
  and scopes the two expensive stages to what the branch actually changed.
- Add `--all` **only** when the change is global: editing
  `scripts/check-repo.sh` itself or the checks it drives, a repository-wide
  rename or reformat, a release handoff, or when you have reason to believe the
  scoping missed something. `--all` re-runs the rewrite source-audit tests,
  which take minutes.
- Do not invoke `shellcheck` across every shell file, or run
  `python3 -m unittest discover` directly, to "be thorough". Both bypass the
  scoping and cost minutes for changes that cannot affect them. Use the gate.
- The gate prints which stages it scoped or skipped. Quote that line when you
  report the result rather than implying full coverage — a scoped pass is a
  pass for what changed, not for the repository.

## GitHub workflow

- Push completed changes directly to `main`; do not open pull requests.
- Run all `gh` CLI commands outside the sandbox by requesting escalated permissions up front.

## Build workspace

- Put new build directories and generated build artifacts under
  `../rock-5b/build/`, using a separate subdirectory for each project or task.
  Treat that directory as disposable build state so it can be cleaned up as a
  unit; keep source checkouts and durable evidence outside it.
- Use `ccache` whenever the compiler and build system support it. The **only**
  compiler-cache store for work under `~/Code` is `~/Code/.ccache`; do not
  create a cache under `../rock-5b/build/`, a project tree, or a task build
  directory. Use `bash scripts/centralize-ccache.sh --status` to verify the
  host and container wiring. Bypass ccache only when measuring uncached build
  time or diagnosing cache behavior, without creating a second store.

## Native package builds

- Run Debian/native package builds with `PATH=/usr/sbin:/usr/bin:/sbin:/bin` so Meson uses `/usr/bin/pkg-config` and the Ubuntu multiarch package metadata.
- Do not let Homebrew/Linuxbrew's `pkg-config` drive these builds. It cannot see system entries such as `libdrm.pc` and has repeatedly produced false missing-dependency failures.
