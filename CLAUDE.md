# CLAUDE.md

Working notes for **Fingerprint Manager** (`alhasapi.fingerprint`), an Omarchy
panel plugin. Read this before changing anything here.

Two docs carry the detail, and they are worth reading rather than rediscovering:

- [`docs/DESIGN.md`](docs/DESIGN.md) — why it is shaped this way. Read before
  changing the plugin's *shape*: the three states, the script/QML boundary, what
  needs root, why setup is delegated.
- [`docs/TESTING.md`](docs/TESTING.md) — the loop that actually catches things.
  Read before believing any observation.

## Development loop

This directory **is** the installed plugin — no symlink, no build step. Edits
here are live on this machine, and the directory name must keep matching
`manifest.json`'s `id`, because `omarchy-plugin-add` installs by id.

```bash
omarchy restart shell     # the ONLY thing that loads edited QML
```

Saving a file logs `Local plugin changed, reloading: alhasapi.fingerprint` and
**does not put the change on screen**. Neither does
`omarchy-shell shell rescanPlugins`. Both were tested directly with a visible
marker string; only the restart applied it. Skipping it costs a specific kind of
time — twice during development a fix was written, the log showed a reload, the
panel was reopened, and the old behaviour was still there. The second time, the
"fix" was for a bug that had never been live.

Then check the log, because **QML errors are silent** — nothing raises, no exit
code changes, the panel just doesn't appear:

```bash
grep -iE "fingerprint|error|warn" /run/user/$UID/quickshell/by-id/*/log.log | tail -20
```

## The bin/ contract

Every helper is runnable by hand and prints **one JSON object per line** on
stdout. That is the whole debugging story: it separates a backend problem from a
UI problem without involving the shell. Keep it — a helper that prints prose, or
that only makes sense when driven from QML, breaks the one property that makes
this plugin tractable.

```bash
bin/omarchy-fingerprint-setup-status    # hardware + backend
bin/omarchy-fprintd-status              # device + enrolled fingers
bin/omarchy-fingerprint-toggle-status   # the three PAM files
```

Any of them may emit `{"event":"error","message":…}` instead. `Model.parseLine`
wraps `JSON.parse` in try/catch so a truncated line cannot take the panel down.

**`omarchy-fprintd-enroll` and `omarchy-fprintd-delete-all` change real
enrollment state.** Running them means physically rescanning fingers afterwards.
Leave them to deliberate end-to-end runs.

## Root, and the polkit path

Enrolling, listing and deleting need **no** root — fprintd's own policy allows an
active local session. Only the PAM edits do, via
`pkexec bin/omarchy-fingerprint-toggle`.

**`exec.path` in the polkit action is absolute**, and is how polkit matches the
`pkexec`'d binary to the action. Move this directory and the toggles break until
`bin/omarchy-fingerprint-install` is re-run. The symptom is a generic system
password prompt instead of Omarchy's themed dialog, or an outright failure — not
an error message naming the path.

The installer exists at all because Omarchy gives plugins no post-install hook
and no way to register a menu row. It is idempotent; re-running is safe.

## Things that will bite you

- **Layout cannot be checked by reading the QML.** The longest-lived bug here was
  the uninstall button rendering outside the card — invisible in the source,
  obvious in a capture. Screenshot it: `grim -g "<x>,<y> <w>x<h>"`, where the
  literal `x` is required and the coordinates are logical (physical ÷ scale).

- **The settings overlay's danger-zone button has been clipped twice.** Any
  change to card sizing or the settings surface needs a capture of *that*
  specific button, not a general "looks fine".

- **Z-order is load-bearing.** Settings overlay `z: 90`, both `ConfirmDialog`s
  `z: 100`, because a confirmation raised from inside settings has to land on top
  of it. Escape unwinds the same way: confirmation, then settings, then panel.

- **`close()` must reset transient state.** Settings open, an in-flight enroll,
  an open confirmation — anything surviving a close makes the next summon a
  surprise.

- **Do not reimplement the setup/uninstall wizards.** They call `sudo`
  internally, so running them under `pkexec` fails: already root, nested `sudo`,
  no TTY. They are handed off to a floating terminal exactly as Omarchy's own
  menu rows do, and a 3s `Timer` re-polls so the panel switches itself when the
  wizard finishes.

- **There is no per-finger delete, and adding one is not possible.**
  `net.reactivated.Fprint` has no finger argument anywhere — both delete methods
  take a user. Simulating it by deleting all and re-enrolling the survivors would
  make someone rescan several fingers to remove one.

- **The panel never moves a switch optimistically.** It re-reads the PAM files
  after `pkexec` exits, on any exit code, because a cancelled or failed run may
  still have edited one file. A cancelled auth prompt must leave the switch where
  it was, not flip and snap back.

## Publishing

Repo: `https://github.com/alhasapi/omarchy-fingerprint-manager`. Commits follow
the house style of the other plugin repos — problem-first body explaining *why*,
wrapped prose. Claude attribution is scrubbed; commits carry a `Claude-Session:`
trailer matching the existing history.
