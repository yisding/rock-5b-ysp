# RDP reconnect after idle dies in the greeter→session handover, masquerading as the wake-watch wedge

**Date:** 2026-07-29 (~06:45–06:58, investigated live while the tripwire from the
[wake-watch finding](2026-07-29-rdp-black-screen-gsd-power-one-shot-wake-watch-wedge.md)
was running)
**Symptom:** Identical from the client side to the wake-watch wedge — reconnect
after a long idle period, GDM password accepted, then a stuck frame and never
the desktop. Root cause is entirely different: the RDP client is never
redirected from the greeter to the user session, and no input ever reaches the
user session at all.

## What actually happened (wire + journal narrative)

- **03:16:06** — the original RDP connection (held since 00:30) drops
  (`ERRINFO_LOGOFF_BY_USER`, network/idle). GRD user daemon (5935) stops its
  session and removes its virtual monitor. Crucially, the system daemon's
  handover object `/org/gnome/RemoteDesktop/Rdp/Handovers/session8` (registered
  at the 00:30 login) is **never unregistered**.
- **03:22:21** — gsd-power's sleep idle watch fires; login1 refuses suspend
  (`SleepVerbNotSupported`, suspend disabled by config) and gsd stays parked in
  mode `sleep` with `PowerSaveMode=3`. Its user-active wake watch (mutter
  upstream id 1044, armed at the 03:09:51 dim) stays armed.
- **03:16→06:45** — zero RDP connections (system daemon logs nothing). The
  03:54/03:58 "activity" in gsd's journal is an app churning session idle
  inhibitors, not a user (see mutter discovery below).
- **06:45:49** — reconnect. Greeter leg works: new greeter session c3,
  `StartHandover(c3)` → server redirection → client re-attaches with routing
  token → greeter GRD takes the client. User types password.
- **06:47:10** — auth succeeds. GDM *updates* the stale remote-display record
  (no fresh "Registering handover at session8"), the user-session daemon 5935
  instantly calls `StartHandover(session8)`, and the system daemon emits
  `RedirectClient` to the **greeter's** GRD — the process holding the client
  TCP — which must send the RDP server redirection.
- **06:47:11** — GDM tears down greeter session c3 (its handover is
  unregistered). **No redirection is ever sent.** Compare the healthy 00:30
  flow: redirect + token reconnect + `TakeClient` all completed *before* the
  greeter handover was unregistered.
- **06:47:41** — `MAX_HANDOVER_WAIT_TIME_S` (30 s) expires: "Aborting handover,
  removing remote client". The client saw a frozen greeter the whole time.

The defect is the ordering race on the unlock path: redirect-to-user-session
races greeter-session teardown, and the loser is a fire-and-forget D-Bus signal
(`RedirectClient` in `grd-daemon-system.c on_handle_start_handover`) with no
delivery check, no retry, and a 30 s abort as the only failure handling. The
stale `session8` handover object (left over because client disconnect does not
unregister it) is what enables the instant-`StartHandover` reordering.

## Mutter discovery: inhibitor release resets idletime without firing wake watches

`meta_idle_monitor_inhibited_actions_changed` (mutter 50.1
`src/backends/meta-idle-monitor.c:176-178`) sets
`last_event_time = g_get_monotonic_time()` when `InhibitedActions` loses the
IDLE flag — **without firing user-active watches** (only
`meta_idle_monitor_reset_idletime`, the input path, fires them). Consequences:

- `GetIdletime` going back to ~0 does **not** prove input reached the session.
  Tonight every apparent "reset" (03:54:57, 03:58:34) matched an inhibitor
  release to the millisecond; timeout watches re-added at those moments fired
  exactly `timeout` later, completing the illusion of user activity.
- An app that toggles an idle inhibitor (browser video probes etc.) silently
  postpones dim/blank/sleep timeouts — a wake-suppression quirk of its own.
- The wake-watch finding's "01:57:53 keystrokes did reset idletime" evidence is
  weaker than written (could have been inhibitor churn); that finding still
  stands on its two direct proofs (injected EIS → zero `WatchFired`; re-blank
  → no `AddUserActiveWatch`).

## Wake path exonerated tonight (live disproof of watch loss)

Injected one EIS Shift keystroke (mutter RemoteDesktop
`NotifyKeyboardKeycode`) at 06:58:19 → mutter fired **both**
`WatchFired(1049)` to gnome-session (its user-active watch armed at 03:12:21 —
alive ~3 h 46 m later) and `WatchFired(1105)` to the fresh gsd-power, which
transitioned `sleep → normal` and unblanked. So tonight the one-shot watches
survived; the display stayed black only because **no input event was ever
dispatched into the user session between 03:09 and 06:58** — there was no
session for input to arrive through.

The two failure modes produce identical symptoms and are distinguished only by
whether an injected EIS event produces `WatchFired` emissions.

## Heals used tonight (over SSH)

- `systemctl --user kill -sKILL org.gnome.SettingsDaemon.Power.service` —
  respawn keeps the `G_MESSAGES_DEBUG=all` tripwire env (user-manager scoped).
- `Properties.Set PowerSaveMode <0>` on `org.gnome.Mutter.DisplayConfig` to
  repower immediately (fresh gsd starts straight into `sleep` mode when
  idletime already exceeds the sleep timeout, so it does not repower by itself).
- The handover race self-cleans on abort (+30 s); the *next* connection attempt
  takes the fresh-registration path that worked at 00:30. No daemon restart
  needed — 5935 was responsive throughout (its `StartHandover` landed < 1 s).

## Upstream fix directions

- grd: unregister the per-session handover object when the remote client goes
  away, so a later reconnect can't bind to stale ordering; make
  `RedirectClient` acknowledged (or have the system daemon fall back to
  sending the redirection itself when the source daemon vanishes).
- gdm: don't tear down the greeter session until the handover destination has
  taken the client (or at least until the redirection is on the wire).
- gsd-power: entering `sleep` mode when login1 refuses the suspend verb parks
  the session in a state only recoverable by input that a dead RDP transport
  can never deliver; falling back to `blank` would at least keep the
  sleep-warning temporary-unblank path alive.

## Act 2 (07:12): the aborted handover leaves GRD deaf to GDM, bouncing logins

The next reconnect (07:12) failed *differently*: password accepted → instantly
back at the GDM login. Trace:

- Greeter leg fine (session c4, `TakeClient` 07:12:40); three `gdm-password`
  PAM workers spawned (07:12:42/:46/:55 — one per attempt), no auth failures;
  session 8's gsd-power woke (`normal`, 07:12:44) — **auth and unlock
  succeeded** each time.
- GDM did its part: its session-8 remote-display object (alive since the 00:30
  login) had `RemoteId` updated to the new client
  (`/org/gnome/RemoteDesktop/Client/3674216596`, verified via
  `busctl --system introspect org.gnome.DisplayManager .../Displays/...`).
- The GRD system daemon **never reacted** — no "GDM updated a remote display",
  no `Handovers/session8` registration, so no redirect, and the greeter simply
  reset to the prompt. The user-session daemon (5935) never got anything to
  respond to.

Root cause: the 06:47 abort ran the old cleanup —
"`Aborting handover, removing remote client`" — which frees the
`GrdRemoteClient` and with it the subscription to GDM's session-8
remote-display object. From then on, property updates on that object have no
listener: every unlock succeeds, no handover ever starts. This exact hole is
covered by one part of **our old commit `a3a1a32` "rdp: make handover
reconnect cleanup robust" (2026-06-27)**, which preserved the remote client
(and its remote-display subscription) when a registered remote display still
existed. The installed deb
(`50.2+rkmpp+git20260721.13.cf60b4d+fullrange709`, the BT.709 color-fix build
line) deliberately omits that old broad preservation path — the binary has
only the old abort string, no preservation message.

The first live diagnosis overreached by calling that a packaging regression
and recommending `a3a1a32` wholesale. A 2026-07-29 source re-audit confirmed
the current package already contains the safe replacements developed after the
June experiment: GNOME 50's `SetRemoteId` flow, corrected variant/socket/timer
ownership, and pending-only redirected-socket coalescing. The old commit's
global `client_taken` state makes the routing token single-use and rejects the
legitimate second GDM→session leg; its broad registered-display predicate can
also retain greeter state. Only the user-display subscription-survival
behavior was missing.

Recovery without a subscription-retaining build: disconnect the client, restart the system
daemon (`sudo systemctl restart gnome-remote-desktop`) to rebuild its
remote-display subscriptions from GDM state, then reconnect — the fresh
full-chain flow (as at 00:30) works. Durable fix: rebuild the grd package with
the narrowed `c4ef3c9` successor described below, not with `a3a1a32`.

## Act 3 (07:53): the user handover daemon doesn't survive a system-daemon restart

Restarting `gnome-remote-desktop.service` (the Act-2 recovery) traded one deaf
daemon for another. After the restart, the chain worked up to and including
"GDM updated a remote display" and the fresh system daemon registered
`Handovers/session8` and set `HandoverIsWaiting=true` — but the user-session
handover daemon (`gnome-remote-desktop-handover.service`, PID 5935, running
since 00:30) never called `StartHandover`: its proxies pointed at the *old*
system daemon's D-Bus objects and it does not re-attach when the
`org.gnome.RemoteDesktop` name changes owner. Every login attempt after a
system-daemon restart bounced back to GDM identically to Act 2, with the
system daemon waiting indefinitely.

`systemctl --user restart gnome-remote-desktop-handover.service` fixed it
instantly: the fresh instance saw the waiting handover on startup, called
`StartHandover(session8)` within a second, the redirect+routing-token
reconnect completed, and the session came up (first frame 311 ms reception).

Full recovery recipe after any GRD state desync, in order:
1. `sudo systemctl restart gnome-remote-desktop` (system daemon), then
2. `systemctl --user restart gnome-remote-desktop-handover.service` (must
   follow any system-daemon restart), then
3. reconnect the client and authenticate at GDM.

## Act 4: latest GNOME 50 rebase and narrowed June-fix salvage

The release branch was rebased from upstream 50.2 `60423c8` to the latest
GNOME 50 stable tip `18cc5f7` (the only upstream delta is a Norwegian Bokmål
translation update). The 16 existing downstream commits are patch-identical
under `git range-diff`. GNOME 51 is still the next development series; it was
not substituted for the Resolute/GNOME 50 package line.

New release commit `c4ef3c9` adds an explicit
`owns_reassigned_remote_display` marker only in
`on_remote_display_remote_id_changed()`, the point where GDM transfers an
existing user display to a new transport client. On timeout,
`abort_handover()` preserves the client only when:

- the display was reassigned through that path;
- the GDM display still has a session;
- that session still matches the destination handover; and
- the original transport session is already gone.

It clears any pending socket, credentials flag, and handover-waiting state
before returning. Initial greeter failures still follow the normal removal
path, redirected sockets are still coalesced only while pending, and no
`client_taken` state exists. The canonical source export, native arm64 Debian
package build, and RDP integration test pass with `/usr/bin/pkg-config`; TPM
and hardware-EGL skip on the build host. Source and binary Lintian error gates
pass with only the expected long-filename warnings. Launchpad source `18649293`
was Published, but arm64 build `33452991` failed after 8m42s and retained no
build log, buildinfo, changes file, dependency diagnosis, or upload log. A host
rebuild reproduced a package-test boundary: the RDP assertion succeeds, but a
complete Mutter/PipeWire teardown can take 21.64s and exceed Meson's 20s
default. Package `…~rk2` leaves production source unchanged, keeps that test
fatal, and applies `--timeout-multiplier 3`. Its local full arm64 build passed
with RDP green and the two expected skips; Launchpad source `18654077`, binary
publication `247717203`, and arm64 build `33461880` are
Published/successful. The build finished in 5m33s with RDP green in 9.76s.
The measured idle reconnect sequence still needs a board reproduction to prove
the runtime branch and to determine whether the first redirect race itself
needs a cross-GRD/GDM acknowledgement change.

## Status

- Wake-watch tripwire still running (gsd-power `G_MESSAGES_DEBUG=all`, PID
  640316 after tonight's respawn; dbus-monitor PID 394256 →
  `~/Code/tmp/rdp-wake-bug/dbus5.log`). The original watch-loss trigger remains
  uncaught — tonight's recurrence was this handover race, not watch loss.
- Handover race caught once; not yet reproduced deliberately. Repro sketch:
  connect → idle-lock → drop the client ≥ idle-sleep timeout → reconnect and
  authenticate; race window is greeter teardown (~1 s) vs client redirect.
  With the un-fixed build, the first aborted handover then converts into the
  Act-2 deaf state until the system daemon is restarted.
- Source fix complete and public at `release/50.2-rkmpp@c4ef3c9`; source/native
  package and signature gates pass. Replacement PPA source `18654077` is
  Published with binary `247717203` after build `33461880` succeeded;
  installation and the measured idle reconnect reproduction remain the handoff
  gates. Do not restore `a3a1a32` wholesale.
