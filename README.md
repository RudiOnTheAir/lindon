# lindon

A private, trimmed fork of [Rivolution](https://github.com/anjeleno/rivolution)
(itself a Qt6 fork of [Rivendell](https://github.com/ElvishArtisan/rivendell)),
maintained for use at Radio Ostfriesland / Radio Rudi.

Not a public project — kept private intentionally. This README exists
for our own future reference as much as anything else.

## What this is

Rivolution's Qt6 migration is the part worth having: vanilla Rivendell
v4 still depends on Qt5 components (notably QtWebKit) that have aged
out of current distributions, making it awkward to package on a
current Ubuntu. Rivolution solves that.

What we didn't want was everything Rivolution built *on top of* that
migration — a web dashboard, a self-healing PipeWire patchbay,
Icecast/Stereo Tool/Tailscale baked into the packaged stack, and (the
one that actually broke things) a segue back-timing feature that
doesn't compose correctly with voice tracking. `lindon` is Rivolution
with those parts removed or reverted, plus a couple of packaging bugs
fixed that we ran into ourselves.

## How this differs from upstream Rivolution

- **`rivapi` (the Go dashboard) removed entirely** — never built by
  the autotools chain to begin with; its systemd/sudoers hooks are
  stripped from `postinst`/`rules.src` too. No web UI, no dashboard
  auth, no associated `sudo` grant for the service account.
- **PipeWire is user-scope, not system-scope** — this deployment
  always runs with desktop autologin (`rdairplay` in the desktop
  autostart), so a separate system-scope PipeWire instance (and its
  linger/tmpfiles workarounds) is unnecessary complexity.
  `rivendell.service` binds to `user@<uid>.service` instead.
- **`icecast2` and `stereo-tool.service` dropped from the packaged
  stack** — neither is installed or managed by `lindon`. Stereo Tool
  runs locally and gets patched into PipeWire by hand.
- **`tailscaled` removed** from `rivolution-stack.target`.
- **Segue back-timing (upstream spec `docs/specs/0002-segue-
  backtiming.md`) fully reverted, including its follow-on "second
  bug" fix.** Upstream's own spec explicitly reasoned that voice
  tracking wouldn't interact with this feature — that reasoning
  turned out to be wrong on two separate counts:
  - Voice-tracked transitions save `SEGUE_GAIN=0` as their normal,
    incidental value (full volume, no duck) — the exact same field
    this feature gates on — so every voice-tracked segue triggered
    it regardless of operator intent, playing out to the element's
    natural end with no audible transition instead of blending.
  - The follow-on fix for a related regression (`Finished()`/
    `FinishEvent()` skipping the next element's start whenever
    anything else was still running, assuming it would be
    re-triggered later) silently stalled the log whenever the next
    line was a marker or an empty voice-track slot with no audio of
    its own to generate that re-trigger — the log would just sit
    there indefinitely, indistinguishable from a Stop.

  Both reverted; confirmed via diff that the affected functions are
  now byte-identical to vanilla Rivendell 4.5.0. Reported upstream
  weeks ago, no response as of this writing.
- **`libmad0` / `libtwolame0` added to `Depends:`** — both are loaded
  via `dlopen()` at runtime rather than linked, so their absence
  doesn't show up via `ldd` and wasn't caught by upstream's own
  packaging; without them, MP3/MPEG import silently fails.
- **`lindon-install.sh`** — a setup wrapper (not part of upstream)
  that creates the `rd` operator account, configures desktop
  autologin (preferring X11 over Wayland — SPICE console access via
  Proxmox has had clipboard/resize/stability problems under Wayland
  that don't reproduce under X11), installs the built `.deb`s, and
  walks through NFS export/mount plus database pointer setup for
  standalone/server/client roles.

## Installation

Grab the `.deb` files and `lindon-install.sh` from this repo's
[Releases](../../releases) page, put them in the same directory, then:

```bash
sudo ./lindon-install.sh
```

The operator account is always named `rd` — see the comments in
`lindon-install.sh` for why, and what to do if you need something
else.

## Remotes / staying current

This repo tracks `anjeleno/rivolution` as its `upstream` remote:

```bash
git remote add upstream https://github.com/anjeleno/rivolution.git
git fetch upstream
git log --oneline main..upstream/main
```

Pulling upstream changes in isn't automatic or guaranteed to be
conflict-free — Rivolution's own Qt6 migration touched a large
fraction of the codebase, so a given upstream fix may or may not apply
cleanly depending on whether it lands in code that migration also
touched.

## Not our own bug reports

Where a problem traces back to vanilla Rivendell itself rather than
anything Rivolution- or `lindon`-specific, that's tracked separately —
this repo's commit history is specifically about the delta from
Rivolution, not a general Rivendell bug tracker.
