# GitHub workflow

- Push completed changes directly to `main`; do not open pull requests.
- Run all `gh` CLI commands outside the sandbox by requesting escalated permissions up front.

# Native package builds

- Run Debian/native package builds with `PATH=/usr/sbin:/usr/bin:/sbin:/bin` so Meson uses `/usr/bin/pkg-config` and the Ubuntu multiarch package metadata.
- Do not let Homebrew/Linuxbrew's `pkg-config` drive these builds. It cannot see system entries such as `libdrm.pc` and has repeatedly produced false missing-dependency failures.
