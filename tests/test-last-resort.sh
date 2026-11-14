#!/usr/bin/env bash
set -Eeuo pipefail
TEST_ROOT=$(cd "$(dirname "$0")/.." && pwd)
export TEST_ROOT QBIT_AUTODELETE_LIBRARY=true
source "$TEST_ROOT/qbit-autodelete.sh"
CONFIG_FILE="$TEST_ROOT/tests/fixtures/test.env"
load_config; validate_config
CRITICAL_WATERMARK_PERCENT=18;LOW_WATERMARK_PERCENT=28;HIGH_WATERMARK_PERCENT=32
YIELD_OVERRIDE_PERCENT_OF_CRITICAL=33;LAST_RESORT_ENABLED=true
free_bytes=59400
filesystem_status(){ printf '1000000 %s\n' "$free_bytes"; }
choose_mode
[[ $(last_resort_active) == false ]]
free_bytes=59399;choose_mode
[[ $(last_resort_active) == true ]]
now=2000000000
rules='{"BJ Filmes":{"retention_hours":24,"emergency_retention_hours":12,"min_ratio":0},"Other":{"retention_hours":24,"emergency_retention_hours":12,"min_ratio":0}}'
input=$(jq -cn --argjson now "$now" '
  {hash:"young",category:"BJ Filmes",progress:1,amount_left:0,
   completion_on:($now-7200),last_activity:($now-7200),size:1073741824,
   ratio:0,upspeed:0,dlspeed:0,state:"stoppedUP",tags:"",force_start:false} as $t
  | [$t,($t+{hash:"older",completion_on:($now-21600),last_activity:($now-21600)}),
     ($t+{hash:"tagged",tags:"keep"}),($t+{hash:"partial",progress:0.5,amount_left:50}),
     ($t+{hash:"active",upspeed:1}),($t+{hash:"forced",force_start:true}),
     ($t+{hash:"other",category:"Other"})]')
LAST_RESORT_ENABLED=false
scored=$(score_torrents "$now" "$rules" '{"torrents":{}}' <<< "$input")
jq -e 'all(.[];.eligible==false)' >/dev/null <<< "$scored"
LAST_RESORT_ENABLED=true;free_bytes=60000;choose_mode
scored=$(score_torrents "$now" "$rules" '{"torrents":{}}' <<< "$input")
jq -e 'all(.[];.eligible==false)' >/dev/null <<< "$scored"
free_bytes=59399;choose_mode
scored=$(score_torrents "$now" "$rules" '{"torrents":{}}' <<< "$input")
jq -e '[.[]|select(.eligible)|.hash]|sort==["older","young"]' >/dev/null <<< "$scored"
EMERGENCY_MAX_DELETE_PER_RUN=1
selected=$(select_candidates "$scored")
jq -e 'length==1 and .[0].hash=="older"' >/dev/null <<< "$selected"
# Recheck must cancel a retention exception after disk recovery, category change,
# a newly protected tag, incomplete state, or newly active transfer.
CURL_COMMON=()
current=$(jq '[.[]|select(.hash=="older")]' <<< "$input")
curl(){ printf '%s' "$current"; }
rechecked=$(reverify_selection "$selected")
jq -e 'length==1' >/dev/null <<< "$rechecked"
for change in '.category="Other"' '.tags="keep"' '.progress=0.5' '.amount_left=1' '.upspeed=1'; do
  current=$(jq --argjson t "$(jq '.[0]' <<< "$selected")" -n "[\$t|$change]")
  [[ $(reverify_selection "$selected") == '[]' ]]
done
current=$(jq '[.[]|select(.hash=="older")]' <<< "$input")
free_bytes=60000
[[ $(reverify_selection "$selected") == '[]' ]]
printf 'OK: threshold, opt-in, BJ-only retention override, oldest-first and preserved protections\n'
