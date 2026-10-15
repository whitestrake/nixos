# shellcheck shell=bash
# Summarise Komodo's open alerts as InfluxDB line protocol for Telegraf's exec
# input, in a fixed, small set of series:
#
# - komodo_alert ts, per server with an open ServerUnreachable alert, valued
#   with the time Komodo opened it. A new outage on the same server reuses the
#   series with a new value.
# - komodo_alert_open count, for every other open alert older than a minute,
#   in 6 types x 3 levels, all 18 always present (zero when empty).
# - komodo_alert_collection pages and overflow.
#
# ListAlerts returns 100 alerts a page, newest first, so every page is followed
# until next_page is null. Output is held until every page is read, and any
# failed request or malformed response fails the run with no output, so
# Telegraf never sees a partial list. When the page cap leaves alerts unread,
# or more servers are unreachable than the series budget allows, only the
# collection samples are printed, with overflow=1. Every sample carries the
# time the run started.
url="${KOMODO_READ_URL:-http://127.0.0.1:9120/read}"
max_pages="${KOMODO_ALERT_MAX_PAGES:-10}"
# 29 servers + 18 summaries + 2 collection samples + scrape up = 50 series.
max_targets="${KOMODO_ALERT_MAX_TARGETS:-29}"
now_ms="${KOMODO_ALERT_NOW_MS:-$(date +%s%3N)}"

page=0
pages=0
overflow=0
alerts=""
while :; do
  # The key and secret reach curl on stdin, never in its arguments, which any
  # local user can read from the process list.
  response="$(curl --fail --silent --show-error --max-time 5 \
    --header 'Content-Type: application/json' \
    --header @- \
    --data "$(jq --null-input --compact-output --argjson page "$page" \
      '{type: "ListAlerts", params: {query: {resolved: false}, page: $page}}')" \
    "$url" <<<"x-api-key: $KOMODO_MONITOR_KEY
x-api-secret: $KOMODO_MONITOR_SECRET")"
  pages=$((pages + 1))
  # One page's alerts per line, kept off the command line: a full collection
  # is far larger than one argument may be.
  alerts+="$(jq --compact-output '
    if (.alerts | type) == "array"
      and (.next_page == null or (.next_page | type) == "number")
    then .alerts
    else error("malformed ListAlerts response")
    end
  ' <<<"$response")"$'\n'
  next="$(jq --raw-output '.next_page // empty' <<<"$response")"
  if [ -z "$next" ]; then
    break
  fi
  if [ "$pages" -ge "$max_pages" ]; then
    overflow=1
    break
  fi
  page="$next"
done

jq --raw-output --slurp \
  --argjson now "$now_ms" \
  --argjson pages "$pages" \
  --argjson overflow "$overflow" \
  --argjson max_targets "$max_targets" '
  def oid: if type == "object" then .["$oid"] else . end;
  def valid:
    type == "object"
    and (._id | oid | type == "string" and length > 0)
    and (.ts | type == "number")
    and (.level | type == "string")
    and (.target | type == "object")
    and (.target.id | type == "string" and test("^[A-Za-z0-9_-]{1,64}$"))
    and (.data | type == "object")
    and (.data.type | type == "string");
  def types: ["ServerCpu", "ServerMem", "ServerDisk", "ServerVersionMismatch",
    "ResourceSyncPendingUpdates"];
  def levels: ["WARNING", "CRITICAL"];
  ("\($now)000000") as $ns
  | add
  | if all(.[]; valid) then . else error("malformed alert") end
  # Pages are read one after another, so an alert can show up on two of them.
  | unique_by(._id | oid)
  | (map(select(.data.type == "ServerUnreachable"))
      | group_by(.target.id)
      | map({target: .[0].target.id, ts: (map(.ts) | min | floor)})) as $down
  | if $overflow == 1 or ($down | length) > $max_targets then
      "komodo_alert_collection pages=\($pages)i,overflow=1i \($ns)"
    else
      (map(select(.data.type != "ServerUnreachable" and $now - .ts > 60000)
        | {
            type: (.data.type as $t | if types | index($t) then $t else "Other" end),
            level: (.level as $l | if levels | index($l) then $l else "OTHER" end)
          })) as $open
      | ($down[]
          | "komodo_alert,alert_type=ServerUnreachable,target_id=\(.target) ts=\(.ts)i \($ns)"),
        ((types + ["Other"])[] as $t
          | (levels + ["OTHER"])[] as $l
          | "komodo_alert_open,alert_type=\($t),level=\($l) count=\($open
              | map(select(.type == $t and .level == $l)) | length)i \($ns)"),
        "komodo_alert_collection pages=\($pages)i,overflow=0i \($ns)"
    end
' <<<"$alerts"
