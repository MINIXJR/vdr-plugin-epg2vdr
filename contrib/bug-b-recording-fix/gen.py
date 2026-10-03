#!/usr/bin/env python3
"""Stage corrected info / info.epg2vdr files for the Tom und Jerry recordings of 2026-10-03.

Bug B2 (eventid overlap-match) made 8 of 12 recordings land under the wrong
episode. Source of truth per recording: timersdone entry of the timer named in
the info file's <timerid> tag (the episode the search timer originally wanted).
Timer 11012 has no timersdone entry any more; its event is derived from the
recording window (start + 15 min lead, as for the other 11 timers).

Nothing outside the staging directory is written.
"""
import os, re, subprocess, sys

BASE = "/srv/vdr/video/Serien/Die_Tom_und_Jerry_Show"
STAGE = os.path.dirname(os.path.abspath(__file__)) + "/stage"
CHANNEL = "S19.2E-1-1089-12040"
DAY = "2026-10-03"

def db(sql):
    pw = None
    for line in open("/etc/epgd/epgd.conf"):
        m = re.match(r"\s*DbPass\s*=\s*(.*)", line, re.I)
        if m:
            pw = m.group(1).strip()
    out = subprocess.run(["mysql", "-u", "epg2vdr", "-p" + pw, "epg2vdr", "-B", "-N", "--raw", "-e", sql],
                         check=True, capture_output=True, text=True).stdout
    return [l.split("\t") for l in out.splitlines()]

def nn(v):
    return "" if v == "NULL" else v

# rec dir -> current episode dir
recs = {}
for epdir in sorted(os.listdir(BASE)):
    for rec in sorted(os.listdir(os.path.join(BASE, epdir))):
        if rec.startswith(DAY + ".") and rec.endswith(".rec"):
            recs[rec] = epdir

rows = []
for rec, epdir in sorted(recs.items()):
    path = os.path.join(BASE, epdir, rec)
    info = open(path + "/info", encoding="utf-8").read()
    m = re.search(r"<timerid>(\d+)</timerid>", info)
    if not m:
        sys.exit("no timerid in %s" % path)
    timerid = int(m.group(1))

    # intended event: via timersdone, fallback via recording window (+900 s lead)
    r = db("SELECT ue.cnt_useid, 'timersdone' FROM timers t JOIN timersdone td ON td.id = t.doneid "
           "JOIN useevents ue ON ue.cnt_channelid = t.channelid AND ue.cnt_starttime = td.starttime "
           "WHERE t.id = %d AND t.autotimerid = 281" % timerid)
    if not r:
        r = db("SELECT ue.cnt_useid, 'rec window +900s' FROM timers t "
               "JOIN useevents ue ON ue.cnt_channelid = t.channelid AND ue.cnt_starttime = t._starttime + 900 "
               "WHERE t.id = %d AND t.autotimerid = 281" % timerid)
    if len(r) != 1:
        sys.exit("cannot resolve intended event for timer %d (%s)" % (timerid, rec))
    useid, how = int(r[0][0]), r[0][1]

    e = db("SELECT cnt_useid, cnt_starttime, cnt_duration, HEX(cnt_tableid), sub_shorttext, sub_category, "
           "REPLACE(IFNULL(sub_longdescription,''), '\\n', '|'), epi_episodename, epi_shortname, epi_partname, epi_season, epi_part, epi_parts, epi_number, "
           "sub_scrseriesepisode FROM useevents WHERE cnt_useid = %d AND cnt_channelid = '%s'" % (useid, CHANNEL))
    if len(e) != 1:
        sys.exit("event %d not found" % useid)
    (uid, st, dur, tid, short, cat, longd, epname, epshort, eppart, season, part, parts, number, screp) = [nn(x) for x in e[0]]

    lines = info.split("\n")
    old = {k: next(l for l in lines if l.startswith(k + " ")) for k in "ESD"}
    version = old["E"].split(" ")[5]          # keep VDR's version token, it is ignored on read
    new = {
        "E": "E %s %s %s %s %s" % (uid, st, dur, tid, version),
        "S": "S %s" % short,
        "D": "D Kategorie: %s||%s||Serie: %s|Kurzname: %s|Episode: %s|Staffel: %s|Staffelfolge: %s|Staffelfolgen: %s|Folge: %s||Quelle: DVB"
             % (cat, longd, epname, epshort, eppart, season, part, parts, number),   # "Episode:" is the eplists part name, not the EPG shorttext
    }
    newinfo = "\n".join(new[l[0]] if l[:2] in ("E ", "S ", "D ") else l for l in lines)

    ext = open(path + "/info.epg2vdr", encoding="utf-8").read()
    newext = re.sub(r"(?m)^LONGDESCRIPTION: .*$", lambda _: "LONGDESCRIPTION: " + longd, ext)
    newext = re.sub(r"(?m)^SCRSERIESEPISODE: .*$", lambda _: "SCRSERIESEPISODE: " + screp, newext)

    newdir = ("%02dx%02d - %s" % (int(season), int(part), short)).replace(" ", "_")
    changed = newinfo != info or newext != ext or newdir != epdir
    rows.append((rec, timerid, how, epdir, newdir, changed, old, new, newinfo, newext))

print("%-24s %-6s %-17s %-36s %s" % ("rec", "timer", "resolved via", "current dir", "target dir"))
for rec, timerid, how, epdir, newdir, changed, old, new, newinfo, newext in rows:
    print("%-24s %-6d %-17s %-36s %s" % (rec, timerid, how, epdir, newdir if changed else "(unchanged - generator reproduces files byte-exact)"))

os.makedirs(STAGE, exist_ok=True)
plan = open(STAGE + "/plan.tsv", "w", encoding="utf-8")
for rec, timerid, how, epdir, newdir, changed, old, new, newinfo, newext in rows:
    if not changed:
        continue
    d = os.path.join(STAGE, rec)
    os.makedirs(d, exist_ok=True)
    open(d + "/info", "w", encoding="utf-8").write(newinfo)
    open(d + "/info.epg2vdr", "w", encoding="utf-8").write(newext)
    plan.write("%s\t%s\t%s\n" % (rec, epdir, newdir))
    print("\n== %s (timer %d)" % (rec, timerid))
    for k in "ESD":
        if old[k] != new[k]:
            print(" - " + old[k][:150])
            print(" + " + new[k][:150])
plan.close()
print("\nstaged %d recordings in %s" % (sum(1 for r in rows if r[5]), STAGE))
