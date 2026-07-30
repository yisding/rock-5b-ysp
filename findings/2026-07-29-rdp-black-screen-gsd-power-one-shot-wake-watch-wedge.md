# RDP session wedges black after idle lock: gsd-power's one-shot wake watch is unrecoverable

**Date:** 2026-07-29 (~01:53–02:23 wedge window, investigated live)
**Symptom:** RDP client (Windows App on macOS → GRD) shows a frozen/black frame after
the session idle-locks. Keystrokes reach the session (PAM unlock helper spawns,
mutter idletime resets) but the display never repowers — `PowerSaveMode` stays 3
(DPMS off), GRD encodes zero video frames, and only the silent PCM audio stream
(~1.44 Mbit/s) keeps flowing. State is sticky: every later blank/wake cycle is
also dead until gsd-power restarts.

## Wake mechanism (as shipped, GNOME 50.1 / gsd 50.0)

1. Idle lock → shell shield activates → gjs shim (`org.gnome.ScreenSaver`,
   separate process in GNOME 50) forwards `ActiveChanged(true)` to gsd-power.
2. gsd-power `handle_screensaver_active` → `idle_set_mode(BLANK)` →
   `disable_monitors()` → D-Bus `Properties.Set` `PowerSaveMode=3` on
   `org.gnome.Mutter.DisplayConfig` (gsd-power-manager.c:2375-2393, 1414-1431).
3. On any non-NORMAL transition gsd arms a **one-shot** user-active watch via
   libgnome-desktop's `GnomeIdleMonitor` → mutter `AddUserActiveWatch`
   (gsd-power-manager.c:1879-1887).
4. Input (incl. EIS/virtual input from GRD — not flagged SYNTHETIC) →
   `handle_idletime_for_event` (mutter core/events.c:94-114) →
   `meta_idle_monitor_reset_idletime` fires all user-active watches and
   **deletes them server-side** (meta-idle-monitor.c:453-480, 57-74), emitting
   one unicast `WatchFired(id)` to the owner.
5. gsd's `idle_became_active_cb` → `idle_set_mode(NORMAL)` → `PowerSaveMode=0`,
   and zeroes `user_active_id` (gsd-power-manager.c:2668-2683).

## The defect chain

The contract in steps 3–5 is a single **one-shot, unacknowledged,
asynchronously-registered** watch. If gsd-power misses one `WatchFired` for any
reason, the wedge is permanent:

- **gsd-power-manager.c:1880** — re-arm is guarded by
  `if (manager->user_active_id < 1)`. A stale nonzero id means every future
  BLANK transition *skips arming* and there is no timeout/recovery path.
  This is what converts a single lost signal into a permanent no-wake wedge.
- **gnome-idle-monitor.c `on_watch_fired`** (libgnome-desktop 44.5:73-95) —
  unknown upstream id → `if (!watch) return;` silently. Because mutter already
  deleted the watch on fire, a dropped/mismatched dispatch consumes the watch
  with no error, no log, no client-side cleanup.
- **gnome-idle-monitor.c `add_user_active_watch`** (:503-526) — returns a
  live-looking client id immediately; server registration is async
  (`on_watch_added` installs the upstream-id mapping later). A fire that lands
  before the mapping insert is dropped by the previous bullet. Also, if
  `priv->proxy` is NULL the watch is never registered upstream at all
  (mitigated only by the `connect_proxy` replay).
- Secondary: `temporary_unidle_done_cb` (gsd-power-manager.c:2246-2252)
  re-blanks unconditionally 15 s (`POWER_UP_TIME_ON_AC`) after a WakeUpScreen
  even while the user is actively typing, re-entering the fragile arm path
  under live input.

## Evidence (live, wire-level)

- During the wedge: `PowerSaveMode=3`; mutter `GetIdletime` showed the
  01:57:53 password keystrokes *did* reset idletime; no `WatchFired` for gsd.
- Controlled re-blank at 02:23 (dbus-monitor): gsd Set `PowerSaveMode=3` but
  issued **no `AddUserActiveWatch`** — proving `user_active_id` was stale ≥1.
- Injected EIS keystroke (mutter RemoteDesktop `NotifyKeyboardKeycode`) during
  the wedge: **zero** `WatchFired` emissions — no user-active watch existed
  server-side for anyone.
- After restarting gsd-power (fresh state, `G_MESSAGES_DEBUG=all`): every
  properly-timed blank → arm → EIS-input → fire → unblank cycle works,
  including with shield up and DPMS off. The armed path is robust; the loss
  happens around watch registration/consumption, not steady-state.
- Session wakes that bypass the watch (SessionIsActive toggle, manual
  `PowerSaveMode` set) repower the display but do **not** heal the stale id.

## Workarounds

- Heal a wedged session over SSH (either):
  - `systemctl --user kill -sKILL org.gnome.SettingsDaemon.Power.service`
    (Restart=on-failure respawns it with clean state), or
  - `gdbus call --session -d org.gnome.Mutter.DisplayConfig -o /org/gnome/Mutter/DisplayConfig -m org.freedesktop.DBus.Properties.Set org.gnome.Mutter.DisplayConfig PowerSaveMode "<0>"`
    (repowers display; does not heal gsd's stale id).
- Prevent: `gsettings set org.gnome.desktop.session idle-delay 0`.

## Upstream fix directions

- gsd-power: drop the `user_active_id < 1` guard in favor of re-arming on
  every non-NORMAL transition (remove+re-add), or add recovery (e.g. re-arm on
  each `idle_configure`).
- libgnome-desktop: log unknown `WatchFired` ids; make user-active watches
  re-registered per use instead of trusting one unregistered async round-trip.
- Protocol: one-shot + unacknowledged + async registration is inherently racy;
  an idempotent "subscribe to user-active" signal would remove the class.

## Status

- Trigger of the original loss (what consumed the watch armed at the ~01:40 DIM
  without dispatching the callback) not yet caught in the act.
- 06:45 same-day recurrence of the symptom was **not** this bug: watches were
  alive (injected EIS fired them); the client died in the greeter→session
  handover instead. See
  [the handover-race finding](2026-07-29-rdp-reconnect-handover-redirect-race-and-inhibitor-idletime-reset.md),
  which also documents that inhibitor releases reset idletime without firing
  user-active watches — so this finding's "keystrokes did reset idletime"
  evidence line is inconclusive on its own (the injection and re-blank proofs
  are unaffected).
- Tripwire left running: gsd-power with `G_MESSAGES_DEBUG=all` (via user-manager
  env; PID 379659) + `dbus-monitor` on `org.gnome.Mutter.IdleMonitor` →
  `~/Code/tmp/rdp-wake-bug/dbus5.log`. Next natural recurrence will be fully
  narrated (arm ids, fires, wire traffic).
- Investigation scratch + extracted sources in `~/Code/tmp/rdp-wake-bug/`
  (gsd 50.0, gnome-desktop 44.5, gnome-shell 50.1, mutter 50.1 at
  `~/Code/rock-5b/gnome/mutter-src/`).
