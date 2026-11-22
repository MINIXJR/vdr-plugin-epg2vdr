# Bug B regression check

Read-only check that `timers.eventid` is no longer remapped by VDR's
`cTimer::SetEventFromSchedule()` and written back by epg2vdr (fix in
`timer.c`, keeps the DB eventid on the same channel).

```sh
./bugb-check.sh snapshot        # save eventid of all pending/running timers
./bugb-check.sh compare [FILE]  # compare with FILE (default: oldest snapshot)
./bugb-check.sh check           # consistency checks only
```

`compare` exits with 1 if any eventid changed. It also searches the local
VDR journal for the log line of the fix ("keeping event ... of the database");
other VDRs log to their own journal.

`snap-20261122-181030.tsv` is the baseline taken right after the upgrade to
epg2vdr 1.2.23 (fork build) on all three VDRs, 253 timers.
