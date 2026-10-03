# Bug B: recording metadata repair

Helper scripts to repair recordings that were filed under the wrong episode by
the eventid overlap-match problem (see commit "Fix Bug B: don't clobber
epgd-assigned timer.eventid via overlap-match").

VDR-Core's `cTimer::SetEventFromSchedule()` links a timer to the longest event
fully contained in its recording window. For a 5-minute episode next to a
15-minute one, VDR then writes the neighbor's title, subtitle and description
into the recording's `info` file. Without the plugin fix the directory name
drifts as well.

- `gen.py` - resolves the episode each timer was created for (`timersdone` of
  the `<timerid>` in the `info` file), stages corrected `info` and
  `info.epg2vdr` files in `stage/` and writes `stage/plan.tsv`. Self-test:
  recordings that are already correct must be reproduced byte-exact.
- `apply.sh` - moves the `.rec` directories into the correct episode folder
  and installs the staged files as `vdr:vdr`. `--check` is a dry run; the
  real run needs root.

Afterwards: `svdrpsend UPDR` and `svdrpsend PLUG epg2vdr UPDREC`.

Both scripts are written for one concrete case (search timer 281, SUPER RTL,
2026-10-03: `BASE`, `CHANNEL`, `DAY`, the autotimerid and the expected count of
8 are hard-coded) and serve as a template. `stage/` and
`info_backup_20261003.tar.gz` are the data of that run; the tarball holds the
original `info` files of all 12 recordings.
