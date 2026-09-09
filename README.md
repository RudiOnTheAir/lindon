# lindon

A private, trimmed fork of [Rivolution](https://github.com/anjeleno/rivolution)
(itself a Qt6 fork of [Rivendell](https://github.com/ElvishArtisan/rivendell)),
maintained for use at some local radio stations, both fm and dab+ transmitted.

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
- **Renamed from `rivolution` to `lindon` at the package level**
  (`Conflicts:`/`Replaces:` against every old `rivolution-*` package
  for a clean `apt` upgrade). Internal paths went the other way —
  `/usr/share/rivolution/`, our own systemd units
  (`rivolution-stack.target`, `rivolution.conf`) — reverted back to
  plain `rivendell` naming, since there's no benefit to a third naming
  scheme once the package itself already says `lindon`, and it keeps
  the diff surface smaller if anything here is ever worth pulling back
  upstream. Two things this surfaced, worth knowing if you're doing
  the same kind of rename elsewhere:
  - `postinst`'s fresh-install-vs-upgrade branch keyed only on
    `$OLD_VERSION` (set by dpkg for a same-name package upgrade).
    dpkg leaves that empty for a `Replaces:`-triggered rename, even
    with a fully working install already in place — the very first
    `rivolution`→`lindon` install would otherwise have hit the
    fresh-install branch and dropped the production database
    (`drop database if exists ...`). Now also checks for a
    pre-existing `/etc/rivendell.d/rd-default.conf` before deciding.
  - A `PYPAD_INSTANCES.SCRIPT_PATH` value written before the rename
    doesn't update itself — it's just a string frozen in the
    database at creation time, unaffected by anything the newly
    installed package changes. Existing PyPAD instances need their
    script path corrected by hand after an upgrade; new ones created
    afterward pick up the right path automatically (RDAdmin's file
    picker defaults into `RD_PYPAD_SCRIPT_DIR`, compiled from the
    current package).
  - `rivolution.conf` under `rivendell.service.d/` isn't a
    dpkg-tracked conffile (just `cp`'d in by `postinst`, same as
    `rivendell.conf` that replaces it) — dpkg has no reason to remove
    it on upgrade, so it's left sitting alongside the new
    `rivendell.conf` unless removed by hand.
- **New: "Make Next & Wait max" grace-time mode**, a fourth option
  alongside vanilla's Start Immediately / Make Next / Wait up to
  (`rdairplay`, `rdlogedit`, and `rdlogmanager`'s clock/event editor).
  Reserves the "next" slot immediately like Make Next (so the log
  doesn't fall through to whatever else happens to be next in a
  busy/segue-chained clock — e.g. a news slot skipping straight to
  the wrong interstitial instead of joining the current segue chain),
  but still enforces a bounded timeout like Wait up to, so an
  overrunning predecessor can't push a hard-timed element (news,
  legally-timed IDs) past its deadline. Encoded as `GRACE_TIME <= -2`
  (`timeout_ms = -GRACE_TIME - 2`); no database schema change.
  Two bugs found and fixed while building it, both worth remembering:
  - `RDLogPlay::transTimerData()`: `makeNext()` calls
    `SetTransTimer()` internally, which can silently reassign the
    *member* `play_trans_line` to whatever the next upcoming
    hard-time line is. Reading that member again afterward (instead
    of the function's own pre-captured local `trans_line`, which
    exists for exactly this reason and is already used elsewhere in
    the function) armed the grace timer for the wrong log line —
    the symptom was a hard-timed element several lines away getting
    force-started instead of the one actually configured, skipping
    everything in between.
  - Two separate, unrelated display bugs made a correctly-saved
    value look wrong without actually being wrong:
    `EventWidget::load()` (`rdlogmanager`) lost the `grace=
    event_event->graceTime()` assignment when its `switch` was
    restructured to add the new branch, so re-opening any Hard-Time
    event always showed "Start Immediately" regardless of what was
    saved. `RDEventLine::propertiesText()` didn't know about the new
    `GRACE_TIME <= -2` range and ran it through the old `Wait up to`
    formatting path, where `QTime::addMSecs()` wraps a sufficiently
    negative value around a 24-hour clock — a 2:00 timeout rendered
    as a nonsensical "57:59" in the RDLogManager event list.
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

### Upgrading an existing `rivolution` install

Don't run `lindon-install.sh` for this — it's a first-run wrapper
(account creation, autologin setup, NFS export/mount, database
pointer setup) that a working install has already been through.
Install the packages directly instead:

```bash
sudo apt install lindon_*.deb lindon-*.deb
```

`Conflicts:`/`Replaces:` handles removing the old `rivolution-*`
packages as part of the same transaction — review `apt`'s summary
before confirming, it should show the matching set of `rivolution-*`
packages being removed. Back up the database first regardless
(`mysqldump --all-databases > backup.sql`) — see the `PYPAD_INSTANCES`
and `rivolution.conf` notes above for what still needs manual cleanup
after an upgrade.

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
