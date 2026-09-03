# Design

Why this plugin is shaped the way it is. For what it does, see the
[README](../README.md); for how to verify a change, [TESTING.md](TESTING.md).

## A menu panel, not a bar widget

The plugin is `"kinds": ["panel"]` and takes no bar slot. It is summoned:

```bash
omarchy-shell shell summon alhasapi.fingerprint
```

Every bar widget Omarchy ships is a live status indicator — battery percentage, network state,
volume, container health. A widget earns its permanent slot by having something to say at a
glance. A fingerprint manager has nothing: the enrolled-finger set changes a few times in the life
of a machine, and the PAM wiring less often than that. It is a settings screen, and the natural
home for it is beside the other Security entries in the menu.

The cost is that Omarchy has no mechanism for a plugin to register a menu row. `Menu.qml:50-51`
reads exactly two files — the vendor `omarchy-menu.jsonc` and the user's extensions file — and
`PluginRegistry.qml` validates nothing menu-related. `omarchy-plugin-add` has no post-install
hook either. That is the whole reason `bin/omarchy-fingerprint-install` exists; without it the
plugin would install and then be unreachable.

Being a `panel` also means the `qs.Ui` popup machinery is unavailable: `KeyboardPanel` and
`PopupCard` both take `anchorItem` as a required property, because they exist to hang off a bar
button. So the window is hand-rolled, following `plugins/panels/wifiqr/Panel.qml` — a full-screen
`PanelWindow` on the overlay layer with exclusive keyboard focus, a scrim that dismisses on click,
and a centered `BorderSurface` card. The card's colors, padding, border spec and radius are copied
from `KeyboardPanel.qml:379-388` so a summoned card looks like every other Omarchy popup rather
than a stranger.

The shell's contract for a panel plugin is four things on the root `Item`: `open(payloadJson)`,
`close()`, an `opened` property, and — to keep the shell's open-set in sync when the panel
dismisses itself — a `dismiss()` that calls `shell.hide(manifest.id)` (`shell.qml:480-495`).

## Three states, decided before anything else

`open()` runs `bin/omarchy-fingerprint-setup-status` before any D-Bus call, and the answer picks
one of three UIs:

| `hardware` | `backend` | State |
|---|---|---|
| false | — | `no-hardware` |
| true | false | `not-installed` |
| true | true | `ready` |

This ordering matters. Talking to `net.reactivated.Fprint` on a machine with no backend installed
does not fail cleanly — D-Bus activation stalls or times out — so the cheap filesystem checks come
first. `hardware` is Omarchy's own `omarchy-hw-fingerprint` (sysfs USB vendor/product); `backend`
re-derives the `fprintd-enroll`/`fprintd-list`/`fprintd-verify` + `pam_fprintd.so` + activatable
D-Bus service test that `omarchy-setup-security-fingerprint` already uses, so the plugin agrees
with the wizard about what "set up" means.

## Setup and uninstall are delegated, not reimplemented

The `not-installed` state's button and the danger zone's uninstall both do the same thing:

```qml
Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", script])
```

with `omarchy-setup-security-fingerprint` / `omarchy-remove-security-fingerprint`. That is exactly
what the Omarchy menu's own Security rows do.

The alternative — running those scripts under `pkexec` and streaming their output into the panel —
does not work, and not for a cosmetic reason. Both scripts call `sudo` internally for their
privileged steps. Under `pkexec` they would already be root, and a nested `sudo` with no TTY and
no askpass helper fails outright. Making them work in-panel would mean forking them to drop the
internal `sudo` when `$EUID` is 0, i.e. maintaining a private copy of the two scripts most likely
to change upstream, to avoid showing a terminal that Omarchy shows for these operations anyway.

Package installation, hardware detection, the suspend/resume systemd units and the capability
detection that skips installing `fprintd` when a compatible backend is already present all live in
those scripts and stay there. While a handoff runs, a 3-second `Timer` re-polls setup-status, so
the panel switches itself to `ready` when the wizard finishes — no reopening.

## Root: only the PAM edits

The split is not obvious, so it is worth stating plainly.

**Enrolling, listing and deleting need no root.** fprintd ships
`/usr/share/polkit-1/actions/net.reactivated.fprint.device.policy` with `allow_active=yes` for
`net.reactivated.fprint.device.{verify,enroll,setusername}`. An active local session may do all of
it, so `omarchy-fprintd-{status,enroll,delete-all}` are plain user processes talking to the system
bus.

**Toggling a task needs root**, because it edits `/etc/pam.d/sudo`, `/etc/pam.d/polkit-1` and
`/etc/pam.d/omarchy-lock-fingerprint`. That runs as
`pkexec bin/omarchy-fingerprint-toggle <task> <on|off>` under a dedicated action,
`omarchy.fingerprint.toggle`.

That action is `allow_active=auth_admin_keep`, deliberately stricter than fprintd's own
`allow_active=yes`. fprintd's actions drive a sensor; this one rewrites the authentication stack
for sudo and polkit. A local process being able to silently add or remove an auth method is a
worse failure than a prompt is an annoyance. `_keep` caches briefly, so flipping several switches
in one visit asks once.

`bin/omarchy-fingerprint-toggle` is a refactor of the wizard's own `setup_pam_config`,
`setup_lock_fingerprint_pam`, `remove_pam_config` and `remove_lock_fingerprint_pam`, split into
independent per-task `<task>_on`/`<task>_off` pairs instead of one all-or-nothing pass. Same
idempotency guards, same clamshell gate line (`pam_exec.so ... omarchy-hw-laptop-closed`, which
skips the reader when the lid is shut so PAM drops straight to the password prompt), same
vendor-seeding fallback for `polkit-1`. Since `pkexec` already runs it as root it drops the
internal `sudo` the wizard uses.

One bug found while testing it: inserting with `sed -i '1i ...'` puts the new auth line *above* the
`#%PAM-1.0` header. Harmless — PAM treats it as a comment wherever it sits — but wrong, so the
script now inserts after the header when one is present. The same pattern is still in the upstream
wizard.

### No per-finger delete

`net.reactivated.Fprint` has no per-finger delete. Both delete methods take a user, not a finger.
From `openfprintd/device.py:140-163`, `DeleteEnrolledFingers2()` — the modern, claim-scoped one —
ends at:

```python
return self.target.DeleteEnrolledFingers(self.claimed_by, signature='s')
```

the same per-user call as the legacy `DeleteEnrolledFingers(username)`. There is no finger
argument anywhere in the interface.

So the UI offers **Remove all fingerprints** and says so in the confirmation, rather than showing
per-row delete buttons that would each have to clear everything. Simulating per-finger removal —
delete all, then silently re-enroll the survivors — would mean making the user physically rescan
several fingers to remove one, which is worse than the honest limitation.

## The script/QML boundary

Quickshell exposes no generic D-Bus binding to QML. `Quickshell.Bluetooth`, `Services.Pipewire`,
`Services.UPower` and friends are purpose-built; there is nothing for an arbitrary interface like
`net.reactivated.Fprint`. Everything therefore goes through subprocesses, and the contract is
**one JSON object per line on stdout**:

| Script | Emits |
|---|---|
| `omarchy-fingerprint-setup-status` | `{"event":"setup-status","hardware":true,"backend":false}` |
| `omarchy-fprintd-status` | `{"event":"status","name":…,"scanType":…,"numEnrollStages":5,"fingers":[…]}` |
| `omarchy-fprintd-enroll <finger>` | a line per `EnrollStatus` signal: `{"event":"enroll-stage-passed",…}`, `{"event":"enroll-retry-scan"}`, `{"event":"enroll-completed"}` |
| `omarchy-fprintd-delete-all` | `{"event":"delete-completed"}` |
| `omarchy-fingerprint-toggle-status` | `{"event":"toggle-status","sudo":true,"polkit":true,"lock":true}` |
| `omarchy-fingerprint-toggle` | `{"event":"toggle-completed","task":"sudo","state":"on"}` |

Any of them may emit `{"event":"error","message":…}` instead.

One-shot scripts are read with `StdioCollector { waitForEnd: true }`. Enrollment is the exception
and uses `SplitParser`, because its whole value is arriving progressively — the same streaming
pattern `plugins/panels/speedtest/Panel.qml` uses. `Model.parseLine` wraps `JSON.parse` in a
try/catch so a truncated line cannot take the panel down.

Parsing fprintd's own client tools was the alternative and was rejected: their output is
human-readable, localized, and designed for a terminal. The Python helpers talk to D-Bus directly
via `python-dbus` — the same binding `open-fprintd` itself is written with.

`omarchy-fprintd-enroll` claims the device, subscribes to `EnrollStatus`, and releases in a
`finally` *and* on SIGTERM, so cancelling from the UI (`Process.running = false`) leaves the reader
free rather than claimed by a dead process.

## Reading state back

The panel never trusts its own optimism about the PAM files.

Toggling marks the row busy but does not move the switch. On `pkexec` exit — any exit code, since
a cancelled or failed run may still have edited one file — it re-runs
`omarchy-fingerprint-toggle-status` and takes the answer from the files. A cancelled auth prompt
therefore leaves the switch visibly unchanged, instead of flipping and snapping back.

Three `FileView { watchChanges: true }` watches on the PAM files catch edits made outside the
panel entirely — someone re-running the wizard scripts, or editing by hand. Same pattern
`plugins/polkit/PolkitAgent.qml` and `plugins/lock/Service.qml` use for the same files.

Enrolled fingers have no equivalent watch. fprintd's template storage is backend-specific and not
a path worth hardcoding, so that list refreshes on open and after enroll/delete complete.

## The settings overlay

The toggles and the danger zone are behind the gear icon, on a full-bleed overlay inside the same
card rather than in the main column, following `avila.ultra-docker`'s `settingsSurface`.

This started as a layout bug: with the finger list, three toggles and the danger zone all in one
column, the content exceeded the card and the uninstall button rendered off the visible edge.
Wrapping the column in a `Flickable` did not fix it — it was still the last item in a column
taller than its container. Moving the settings out was the actual fix, and it also reads better:
day-to-day use is "add a finger", not "rewire sudo".

Z-order is load-bearing. The overlay is `z: 90`, above the main content; both `ConfirmDialog`s are
`z: 100`, because a confirmation raised *from inside* settings (remove-all, uninstall) has to land
on top of it. Escape unwinds the same way — confirmation, then settings, then the panel.
