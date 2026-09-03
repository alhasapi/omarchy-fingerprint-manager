# Testing

There is no QML test framework in Omarchy, and this plugin's UI cannot be checked by reading it.
What follows is the loop that actually catches things, in the order worth running it.

The two traps at the top cost more time than every real bug in this plugin combined. Read them
before changing any QML.

## Trap 1: the shell keeps running the old code

Editing a QML file logs a reload:

```
DEBUG qml: Local plugin changed, reloading: alhasapi.fingerprint
```

**That line does not mean your change is on screen.** The file watcher reloads the plugin
definition; a panel instance that is already constructed is not torn down and rebuilt. Twice
during development a fix was written, the log showed the reload, the panel was reopened, and the
old behaviour was still there — the second time after a "fix" for a bug that had never been live.

```bash
omarchy restart shell
```

is the only reliable way to load edited QML. Do it before believing any UI observation. This is
not specific to this plugin: `avila.ultra-docker`'s own `CLAUDE.md` documents the same trap after
losing time to it.

Restarting is cheap and non-destructive — the whole shell reloads from disk.

## Trap 2: QML errors are silent

A QML error does not raise a dialog or change the exit code of anything. The panel just does not
appear, or appears wrong. Errors go to Quickshell's log:

```bash
tail -f /run/user/$UID/quickshell/by-id/*/log.log
```

After every restart, check it before anything else:

```bash
grep -iE "fingerprint|error|warn" /run/user/$UID/quickshell/by-id/*/log.log | tail -20
```

The path changes per shell instance — `ls -t` to find the newest after a restart. A panel plugin
that fails to load also logs `panel plugin <id> failed to load:` from `shell.qml`.

## Static checks

Cheap, run them first:

```bash
omarchy-plugin-validate ~/.config/omarchy/plugins/alhasapi.fingerprint   # manifest, entry points, id
bash -n bin/omarchy-fingerprint-toggle                                   # and every other bash script
python3 -m py_compile bin/*.py
```

For QML there is no linter here (`qmllint` is not installed), so a brace-balance check is the
crude stand-in for catching a truncated edit:

```bash
python3 -c 's=open("Panel.qml").read(); print(s.count("{"), s.count("}"))'
```

Balanced braces prove nothing about correctness, but unbalanced ones explain a silent
non-appearance immediately.

## The bin/ scripts, standalone

Every helper is runnable on its own and prints JSON. This is the fastest way to separate a backend
problem from a UI problem, and none of it needs the shell:

```bash
bin/omarchy-fingerprint-setup-status    # {"event":"setup-status","hardware":true,"backend":true}
bin/omarchy-fprintd-status              # device + enrolled fingers
bin/omarchy-fingerprint-toggle-status   # {"event":"toggle-status","sudo":true,...}
```

Cross-check them against the system directly — they should never disagree:

```bash
fprintd-list "$USER"
grep -l pam_fprintd.so /etc/pam.d/sudo /etc/pam.d/polkit-1
ls /etc/pam.d/omarchy-lock-fingerprint
```

`bin/omarchy-fprintd-enroll <finger>` and `bin/omarchy-fprintd-delete-all` change real enrollment
state — running them means physically rescanning fingers afterwards. Leave them to deliberate
end-to-end runs.

## Layout: screenshot it

**Reading the QML will not tell you whether the layout is right.** The bug that took longest here
was the uninstall button rendering outside the card — invisible in the source, obvious in a
screenshot.

```bash
omarchy-shell shell summon alhasapi.fingerprint
sleep 0.5
grim -o eDP-1 /tmp/panel.png     # hyprctl monitors -j for the output name
```

Then look at the image. Check the card is centered, the scrim covers the screen, nothing is
clipped at the bottom edge, and — the regression that has appeared twice — that the settings
overlay's danger-zone button is fully visible.

`grim -g "<x>,<y> <w>x<h>"` crops to a region, and `magick <file> -scale 400%` enlarges small
detail.

The panel opens over IPC, so summoning does not need a click. Opening the settings overlay does —
there is no IPC method for it. Two ways to get a screenshot of it:

**Flip the property.** Fastest and it never mis-clicks: temporarily default `settingsOpen` to
`true` in `Panel.qml`, restart, summon, capture, revert. It verifies the layout, which is the
thing that keeps regressing; it does not verify the gear button is wired.

**Synthesize the click** with `ydotool` (needs `ydotoold` running:
`ydotoold --socket-path=/run/user/$UID/.ydotool_socket --socket-own=$UID:$UID &`, then export
`YDOTOOL_SOCKET` to that path). Two things to get right, both of which will silently waste a
capture otherwise:

- **Coordinates.** `grim` captures physical pixels; Hyprland's pointer works in logical
  coordinates; `ydotool`'s absolute axis is half that again. On a 1920x1080 output at `scale 1.6`
  the chain is `ydotool = physical / 3.2`. Derive it rather than assuming — move to a known value
  and read `hyprctl cursorpos` back, twice, and take the ratio.
- **Button mask.** `ydotool click 0x00` sends a bare button code and does not click.
  `0xC0` (`0x40` down + `0x80` up) is a real press-and-release.

```bash
ydotool mousemove -a -x $((PX / 32 * 10)) -y $((PY / 32 * 10))   # PX,PY from the screenshot
hyprctl cursorpos                                                # confirm before clicking
ydotool click 0xC0
```

A hover that lands correctly shows the button's tooltip in the next capture, which is a cheap way
to confirm aim before committing to the click.

## End-to-end

Worth doing after any change to the toggle path, because it is the one that edits root-owned auth
files.

Record the starting state, so you can prove you restored it:

```bash
cp /etc/pam.d/sudo /tmp/sudo.before
```

Install the polkit action (needed after any move of the plugin directory, since `exec.path` is
absolute):

```bash
bin/omarchy-fingerprint-install
```

Round-trip one task and diff:

```bash
pkexec bin/omarchy-fingerprint-toggle sudo off
pkexec bin/omarchy-fingerprint-toggle sudo on
diff /tmp/sudo.before /etc/pam.d/sudo && echo "restored"
```

The first `pkexec` should raise Omarchy's *themed* polkit dialog, not a terminal prompt and not a
generic system one — that is the check that the action is installed and matched by `exec.path`.
Subsequent calls within the cache window will not prompt again; that is `auth_admin_keep` working.

`sudo` uses `pam_fprintd.so` as `sufficient`, so password auth keeps working throughout and a
half-applied toggle cannot lock you out. Still worth confirming with `sudo -k && sudo true` after.

Then the parts that need a person: the menu row appears under `Setup > Security` and opens the
panel; Escape and a scrim click both dismiss it; a re-summon comes back clean with no stale enroll
flow or open confirmation; and the add-finger flow advances a dot per scan.
