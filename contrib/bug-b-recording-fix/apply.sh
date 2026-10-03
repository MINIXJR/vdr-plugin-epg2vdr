#!/bin/bash
# Move the 8 mis-filed Tom und Jerry recordings of 2026-10-03 into their correct
# episode directories and install the corrected info / info.epg2vdr files.
#
#   ./apply.sh --check     dry run, no root needed, changes nothing
#   sudo ./apply.sh        apply
#
# Input: stage/plan.tsv (rec <TAB> current episode dir <TAB> target episode dir)
#        stage/<rec>/info, stage/<rec>/info.epg2vdr      (written by gen.py)
# Backup of the original info files: info_backup_20261003.tar.gz (same directory)
set -euo pipefail

BASE="/srv/vdr/video/Serien/Die_Tom_und_Jerry_Show"
HERE="$(cd "$(dirname "$0")" && pwd)"
STAGE="$HERE/stage"
PLAN="$STAGE/plan.tsv"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

if [ $CHECK -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (sudo $0) or with --check" >&2
    exit 1
fi

# ---- pre-checks: verify everything before touching anything
N=0
while IFS=$'\t' read -r REC SRC DST; do
    N=$((N + 1))
    [ -d "$BASE/$SRC/$REC" ]            || { echo "ERROR: missing source $BASE/$SRC/$REC" >&2; exit 1; }
    [ ! -e "$BASE/$DST/$REC" ]          || { echo "ERROR: target already exists $BASE/$DST/$REC" >&2; exit 1; }
    [ -s "$STAGE/$REC/info" ]           || { echo "ERROR: missing staged info for $REC" >&2; exit 1; }
    [ -s "$STAGE/$REC/info.epg2vdr" ]   || { echo "ERROR: missing staged info.epg2vdr for $REC" >&2; exit 1; }
    # only E/S/D may differ between original and staged info
    if diff <(grep -v '^[ESD] ' "$BASE/$SRC/$REC/info") <(grep -v '^[ESD] ' "$STAGE/$REC/info") >/dev/null; then :; else
        echo "ERROR: staged info for $REC differs outside E/S/D lines" >&2; exit 1
    fi
    # a recording still being written has a newer .ts than 2 minutes
    if [ -n "$(find "$BASE/$SRC/$REC" -name '*.ts' -mmin -2 -print -quit)" ]; then
        echo "ERROR: $REC is still being written" >&2; exit 1
    fi
done < "$PLAN"
[ "$N" -eq 8 ] || { echo "ERROR: expected 8 plan entries, found $N" >&2; exit 1; }
[ -s "$HERE/info_backup_20261003.tar.gz" ] || { echo "ERROR: info backup missing" >&2; exit 1; }
echo "==> pre-checks passed for $N recordings"

# ---- apply
while IFS=$'\t' read -r REC SRC DST; do
    echo "$SRC/$REC"
    echo "   -> $DST/$REC"
    [ $CHECK -eq 1 ] && continue
    install -d -o vdr -g vdr -m 0755 "$BASE/$DST"
    mv "$BASE/$SRC/$REC" "$BASE/$DST/$REC"
    install -o vdr -g vdr -m 0644 "$STAGE/$REC/info"         "$BASE/$DST/$REC/info"
    install -o vdr -g vdr -m 0644 "$STAGE/$REC/info.epg2vdr" "$BASE/$DST/$REC/info.epg2vdr"
done < "$PLAN"

if [ $CHECK -eq 1 ]; then
    echo "==> check only, nothing changed"
    exit 0
fi

# remove episode directories that ended up empty (rmdir refuses non-empty ones)
while IFS=$'\t' read -r REC SRC DST; do
    [ -d "$BASE/$SRC" ] && rmdir "$BASE/$SRC" 2>/dev/null && echo "removed empty $SRC" || true
done < "$PLAN"

# let VDR rescan its recordings
install -o vdr -g vdr -m 0644 /dev/null /srv/vdr/video/.update
echo "==> done"
