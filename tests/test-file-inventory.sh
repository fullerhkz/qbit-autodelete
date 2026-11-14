#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export QBIT_AUTODELETE_LIBRARY=true
source "$root/qbit-autodelete.sh"
folder=$(mktemp -d)
trap 'rm -f "$folder/a" "$folder/b" "$folder/link"; rmdir "$folder"' EXIT
printf 'a payload' > "$folder/a"
printf 'b payload' > "$folder/b"
DISK_PRESSURE_ENABLED=true;DELETE_FILES=true;FOLLOWERS_JSON='[]'
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
