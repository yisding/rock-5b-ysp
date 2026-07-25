# <one-line title of the finding>

> Scope: <which project / source tree; include the C## coverage row when relevant>
> Source: <tree @ pin, and the anchor — `file.c` `func()` (~:NNN), or a commit/URL>
> Date: <YYYY-MM-DD>
> Trust: <one or more tags from findings/README.md; add a new tag there first
> if none fit>

The four header fields are required and are the one part of this template that
is uniform across every finding. Keep the Trust line honest as the finding ages:
a tag that says "pending" above a section recording the gate going green is the
most common way a finding starts lying.

## Result

<What you learned, stated plainly. Enough that future-you or an agent does not
have to re-derive it. Prefer the stable anchor (function name + nearby code) over
a bare line number, since sibling trees drift.>

## Boundary

<What this evidence does not establish. Name untested hardware, formats,
reconnect/reboot/rollback behavior, or causal attribution explicitly.>

<!--
Everything below is a menu, not a checklist. `Result` and `Boundary` are the two
sections worth having every time. Use whichever of the rest carry weight for
this finding, and drop the others rather than leaving empty headings.

## Evidence and reproduction   — its own section, or fold these into Result
- **Identity:** <board/accessory + boot path + kernel/DT + relevant userspace,
  or the exact source tree and commit for a code-only finding>
- **Detection:** <driver/interface/code path actually selected, when applicable>
- **Exercise:** `<exact command or inspection method>`
- **Pass/fail signal:** <observable result and exit status; do not infer a pass
  from device or file existence alone>
- **Artifacts:** <log/bundle location and checksum, or "none"; never commit raw
  machine captures>

## Root cause     — the mechanism, once pinned. Common in the driver findings.
## Fix            — patch number + commit, and what scope of proof it has.
## Verification gate  — the smallest run that would close this. status.md
                        deep-links to this heading, so keep the wording.
## Why it matters / follow-up
                  — what this unblocks or contradicts, and any next action. If
                    the follow-up can go stale, add it to the status.md
                    watchlist too.

A correction or supersession goes in a `>` block directly under the header, not
buried in the body:

> **Corrected YYYY-MM-DD by** <a relative link to the superseding finding>.
> <what changed and why.>

When this finding graduates into a project doc, replace the whole file with the
tombstone shape described in findings/README.md § Lifecycle.
-->
