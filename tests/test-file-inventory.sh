#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export QBIT_AUTODELETE_LIBRARY=true
source "$root/qbit-autodelete.sh"
folder=$(mktemp -d)
trap 'rm -f "$folder/a" "$folder/b" "$folder/link"; rmdir "$folder"' EXIT
printf 'a payload' > "$folder/a"
printf 'b payload' > "$folder/b"
DISK_PRESSURE_ENABLED=true;DELETE_FILES=true
fetch_torrent_file_manifest(){ printf '[{"name":"%s","priority":1}]' "$1"; }
input=$(jq -cn --arg path "$folder" '[{hash:"a",save_path:$path,content_path:$path,is_complete:true},{hash:"b",save_path:$path,content_path:$path,is_complete:true}]')
actual=$(enrich_reclaimability "$input")
jq -e '.[0].physical_group_key != .[1].physical_group_key and all(.[];.physical_group_member_count==1 and .physical_group_reclaimable_bytes>0)' >/dev/null <<< "$actual"
ln "$folder/a" "$folder/link"
linked=$(jq '.[1].hash="link"' <<< "$input")
actual=$(enrich_reclaimability "$linked")
jq -e '.[0].physical_group_key == .[1].physical_group_key and all(.[];.physical_group_member_count==2 and .physical_group_complete)' >/dev/null <<< "$actual"
fetch_torrent_file_manifest(){ printf '[{"name":"../escape"}]'; }
if (enrich_reclaimability "$input") >/dev/null 2>&1; then echo 'unsafe traversal accepted';exit 1;fi
fetch_torrent_file_manifest(){ return 1; }
if (enrich_reclaimability "$input") >/dev/null 2>&1; then echo 'failed API accepted';exit 1;fi
fetch_torrent_file_manifest(){ printf '[{"name":"absent"}]'; }
if (enrich_reclaimability "$input") >/dev/null 2>&1; then echo 'missing complete file accepted';exit 1;fi
printf 'OK: shared folder, real hardlinks, API failure, traversal and missing file validated\n'

# Configured ceiling must include the next candidate, not only earlier groups.
RUN_MODE=emergency;EMERGENCY_MIN_SCORE=0;EMERGENCY_MAX_RECLAIM_GB_PER_RUN=800
EMERGENCY_MAX_DELETE_PER_RUN=60;EMERGENCY_WITHOUT_HISTORY=true;BYTES_NEEDED=$((2000*1073741824))
items=$(jq -cn '[{hash:"one",eligible:true,history_ready:true,cleanup_score:95,physical_group_key:"one",physical_reclaim_estimated:true,physical_group_reclaimable_bytes:(500*1073741824)}, {hash:"two",eligible:true,history_ready:true,cleanup_score:90,physical_group_key:"two",physical_reclaim_estimated:true,physical_group_reclaimable_bytes:(400*1073741824)}, {hash:"three",eligible:true,history_ready:true,cleanup_score:85,physical_group_key:"three",physical_reclaim_estimated:true,physical_group_reclaimable_bytes:(250*1073741824)}]')
chosen=$(select_candidates "$items")
jq -e 'length==2 and ([.[].selection_bytes]|add)==(750*1073741824)' >/dev/null <<< "$chosen"
printf 'OK: configured 800 GiB ceiling respected without overshoot\n'

# Only categories in the rules file are managed. A torrent in any other category
# (here "cross-seed-link" and "PTP") is never selected, even when it shares an inode
# with an eligible BJ torrent; that inode keeps a name outside the group and does not
# count as reclaimable space.
export TEST_ROOT=$root; parse_args --config "$root/tests/fixtures/test.env"
load_config
DISK_PRESSURE_ENABLED=true;DELETE_FILES=true;PROTECT_EFFICIENCY_MIB_PER_GIB_DAY=0
shared=$(mktemp -d)
trap 'rm -rf "$shared"; rm -f "$folder/a" "$folder/b" "$folder/link"; rmdir "$folder"' EXIT
mkdir "$shared/bj" "$shared/xs" "$shared/ptp"
head -c 65536 /dev/zero > "$shared/bj/unique.mkv"
head -c 131072 /dev/zero > "$shared/bj/shared.mkv"
ln "$shared/bj/shared.mkv" "$shared/xs/shared.mkv"
ln "$shared/bj/shared.mkv" "$shared/ptp/shared.mkv"
fetch_torrent_file_manifest(){
  case "$1" in
    bj) printf '[{"name":"unique.mkv","priority":1},{"name":"shared.mkv","priority":1}]';;
    xs|ptp) printf '[{"name":"shared.mkv","priority":1}]';;
    *) return 1;;
  esac
}
now=2000000000
rules='{"BJ Filmes":{"retention_hours":48,"emergency_retention_hours":48,"min_ratio":0}}'
raw=$(jq -cn --argjson now "$now" --arg d "$shared" '
  def t($h; $c; $p): {hash:$h, name:$h, category:$c, save_path:($d + "/" + $p),
    content_path:($d + "/" + $p), progress:1, amount_left:0,
    completion_on:($now - 30*86400), added_on:($now - 30*86400),
    last_activity:($now - 30*86400), size:196608, total_size:196608, uploaded:0,
    ratio:5, num_complete:20, num_incomplete:0, upspeed:0, dlspeed:0,
    state:"stalledUP", force_start:false, tags:""};
  [t("bj"; "BJ Filmes"; "bj"), t("xs"; "cross-seed-link"; "xs"), t("ptp"; "PTP"; "ptp")]')
RUN_MODE=emergency;EMERGENCY_MIN_SCORE=0;EMERGENCY_WITHOUT_HISTORY=true
EMERGENCY_MAX_RECLAIM_GB_PER_RUN=800;BYTES_NEEDED=$((10*1073741824))
scored=$(score_torrents "$now" "$rules" '{"version":1,"torrents":{}}' <<< "$raw")
jq -e 'length==1 and .[0].hash=="bj" and .[0].eligible' >/dev/null <<< "$scored"
enriched=$(enrich_reclaimability "$scored")
unique_bytes=$(( $(stat -c %b "$shared/bj/unique.mkv") * 512 ))
jq -e --argjson u "$unique_bytes" '.[0].physical_group_member_count==1
  and (.[0].physical_group_complete|not) and .[0].physical_group_reclaimable_bytes==$u' \
  >/dev/null <<< "$enriched"
chosen=$(select_candidates "$enriched")
jq -e --argjson u "$unique_bytes" 'length==1 and .[0].hash=="bj" and .[0].selection_bytes==$u' \
  >/dev/null <<< "$chosen"
printf 'OK: categories outside the rules never selected; shared inode excluded from reclaim\n'
