# <one-line title of the finding>

> Scope: <which project / source tree; include the C## coverage row when relevant>
> Source: <tree @ pin, and the anchor — `file.c` `func()` (~:NNN), or a commit/URL>
> Date: <YYYY-MM-DD>
> Trust: <one or more tags defined in findings/README.md>

## Result

<What you learned, stated plainly. Enough that future-you or an agent does not
have to re-derive it. Prefer the stable anchor (function name + nearby code) over
a bare line number, since sibling trees drift.>

## Evidence and reproduction

- **Identity:** <board/accessory + boot path + kernel/DT + relevant userspace,
  or the exact source tree and commit for a code-only finding>
- **Detection:** <driver/interface/code path actually selected, when applicable>
- **Exercise:** `<exact command or inspection method>`
- **Pass/fail signal:** <observable result and exit status; do not infer a pass
  from device or file existence alone>
- **Artifacts:** <log/bundle location and checksum, or “none”; never commit raw
  machine captures>

## Boundary

<What this evidence does not establish. Name untested hardware, formats,
reconnect/reboot/rollback behavior, or causal attribution explicitly.>

## Why it matters / follow-up

<Optional: what this unblocks or contradicts, and any next action. If there is a
follow-up that can go stale, also add it to the status.md watchlist.>
