#!/bin/bash
#
# bugb-check.sh - regression test for Bug B (timers.eventid remapped by VDR's
#                 cTimer::SetEventFromSchedule() and written back by epg2vdr)
#
#   ./bugb-check.sh snapshot        save eventid of all pending/running timers
#   ./bugb-check.sh compare [FILE]  compare current state with FILE
#                                   (default: the oldest snapshot = baseline)
#   ./bugb-check.sh check           consistency checks only, no snapshot needed
#
# Read only: nothing in the database is changed. Snapshots are TSV files in
# the directory of this script.
#
# What counts as a Bug-B hit:
#   1. eventid of a timer changed between two snapshots (the fix in
#      epg2vdr 1.2.23+local keeps the DB eventid on the same channel)
#   2. the event the timer points to does not start at timers.evtstarttime,
#      or not at the start time stored in timersdone when the timer was
#      created (hint only: epgd legitimately moves evtstarttime when the
#      broadcaster shifts an event, timersdone is not updated then)
#   3. two pending timers of the same VDR on the same event (duplicates on
#      the long neighbor event, variant B2)
#
# Limits: only the journal of vdrserver is searched for the log line of the
# fix; yavdrbox/vdrslz log to their own journal.

set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
DB=(mysql -u epg2vdr -pepg epg2vdr --batch)

sql() { "${DB[@]}" "$@" 2>&1 | grep -v '^Warning\|Using a password' || true; }

# useid of an event is unique per channel; min(starttime) because merged
# events may appear more than once

EVENTS="(SELECT useid, channelid, min(starttime) starttime, max(title) title,
                max(shorttext) shorttext
           FROM events WHERE updflg IN ('A','L','P','I','T','C','S','R')
          GROUP BY useid, channelid)"

snapshot()
{
   local f="$DIR/snap-$(date +%Y%m%d-%H%M%S).tsv"

   sql -N -e "SELECT t.id, v.name, t.state, t.eventid, t.channelid, t.evtstarttime,
                     t.doneid, ifnull(t.autotimerid, 0), t.file
                FROM timers t LEFT JOIN vdrs v ON v.uuid = t.vdruuid
               WHERE t.state IN ('P','R') ORDER BY t.id" > "$f"

   echo "==> $(wc -l < "$f") pending/running timers saved to $f"
}

check()
{
   echo "==> event of the timer vs. evtstarttime / timersdone start (per VDR)"
   sql -e "SELECT ifnull(v.name, t.vdruuid) vdr, count(*) timers,
                  sum(e.useid IS NULL) no_event,
                  sum(e.starttime <> t.evtstarttime) evt_start_diff,
                  sum(e.starttime <> td.starttime) done_start_diff
             FROM timers t
             LEFT JOIN vdrs v ON v.uuid = t.vdruuid
             LEFT JOIN timersdone td ON td.id = t.doneid
             LEFT JOIN $EVENTS e ON e.useid = t.eventid AND e.channelid = t.channelid
            WHERE t.state = 'P' GROUP BY 1"

   echo "==> details of differing timers"
   sql -e "SELECT t.id, ifnull(v.name, t.vdruuid) vdr, t.eventid,
                  from_unixtime(t.evtstarttime) timer_evt,
                  from_unixtime(e.starttime) event_start,
                  from_unixtime(td.starttime) done_start,
                  left(t.file, 60) file, left(e.shorttext, 40) event_shorttext
             FROM timers t
             LEFT JOIN vdrs v ON v.uuid = t.vdruuid
             LEFT JOIN timersdone td ON td.id = t.doneid
             LEFT JOIN $EVENTS e ON e.useid = t.eventid AND e.channelid = t.channelid
            WHERE t.state = 'P'
              AND (e.useid IS NULL OR e.starttime <> t.evtstarttime
                   OR e.starttime <> td.starttime)
            ORDER BY t.id"

   echo "==> duplicates: more than one pending timer of a VDR on the same event"
   sql -e "SELECT ifnull(v.name, t.vdruuid) vdr, t.eventid, t.channelid,
                  count(*) n, group_concat(t.id ORDER BY t.id) timer_ids
             FROM timers t LEFT JOIN vdrs v ON v.uuid = t.vdruuid
            WHERE t.state IN ('P','R')
            GROUP BY t.vdruuid, t.eventid, t.channelid HAVING n > 1"

   echo "==> same event on more than one VDR (multi-VDR, not Bug B)"
   sql -e "SELECT t.eventid, t.channelid, count(*) n,
                  group_concat(concat(t.id, '@', ifnull(v.name, t.vdruuid)) ORDER BY t.id) timers,
                  left(max(t.file), 60) file
             FROM timers t LEFT JOIN vdrs v ON v.uuid = t.vdruuid
            WHERE t.state IN ('P','R') AND t.vdruuid <> 'any'
            GROUP BY t.eventid, t.channelid HAVING count(DISTINCT t.vdruuid) > 1"
}

compare()
{
   local base=${1:-$(ls "$DIR"/snap-*.tsv 2>/dev/null | head -1)}
   [ -n "$base" ] && [ -s "$base" ] || { echo "ERROR: no snapshot, run '$0 snapshot' first" >&2; exit 1; }

   local now
   now=$(mktemp "$DIR/.now.XXXXXX")
   trap 'rm -f "$now"' RETURN EXIT

   sql -N -e "SELECT t.id, t.eventid, t.state, ifnull(v.name, t.vdruuid)
                FROM timers t LEFT JOIN vdrs v ON v.uuid = t.vdruuid ORDER BY t.id" > "$now"

   echo "==> baseline $(basename "$base") vs. now ($(date '+%Y-%m-%d %H:%M'))"

   # base: id vdr state eventid channelid evtstart doneid autotimer file
   # now:  id eventid state vdr

   awk -F'\t' '
      NR == FNR { ev[$1] = $2; st[$1] = $3; next }
      {
         total++
         if (!($1 in ev)) { gone++; next }
         if (ev[$1] != $4)
         {
            changed++
            printf "    CHANGED timer %s (%s): eventid %s -> %s  [%s]\n", $1, $2, $4, ev[$1], $9
         }
         else if (st[$1] == "R" || st[$1] == "F")
            done++
      }
      END {
         printf "    %d timers in baseline, %d eventid changed, %d recorded/running unchanged, %d no longer in table\n",
                total, changed, done, gone
         exit changed > 0
      }' "$now" "$base" && rc=0 || rc=$?

   local since
   since=$(date -d "@$(stat -c %Y "$base")" '+%Y-%m-%d %H:%M:%S')
   echo "==> journal vdrserver since $since: log line of the fix"
   journalctl -u vdr --since "$since" --no-pager 2>/dev/null \
      | grep -E 'keeping event .* of the database' | cut -c1-220 || echo "    (none)"

   check
   return $rc
}

case "${1:-}" in
   snapshot) snapshot ;;
   compare)  compare "${2:-}" ;;
   check)    check ;;
   *)        echo "usage: $0 snapshot | compare [FILE] | check" >&2; exit 2 ;;
esac
