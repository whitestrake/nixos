# shellcheck shell=bash
# Print Komodo's open alerts as InfluxDB line protocol for Telegraf's exec
# input: one komodo_alert per alert, valued with the time Komodo opened it, and
# one komodo_alert_collection with the pages read and whether the page cap cut
# the list short. ListAlerts returns 100 alerts a page, newest first, so every
# page is followed until next_page is null. Output is held until every page is
# read, and any failed request fails the run, so Telegraf never sees a partial
# list.
url="${KOMODO_READ_URL:-http://127.0.0.1:9120/read}"
max_pages="${KOMODO_ALERT_MAX_PAGES:-10}"

page=0
pages=0
overflow=0
lines=""
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
  # Tags identify each alert: its id, and the disk path for disk alerts, which
  # Komodo opens per path. Tag values escape spaces, commas and equals signs.
  lines+="$(jq --raw-output '
    def esc: tostring | gsub("(?<c>[ ,=\\\\])"; "\\\(.c)");
    .alerts[] as $alert
    | $alert
    | [
        ["id", (._id | if type == "object" then .["$oid"] else . end)],
        ["level", .level],
        ["target_type", .target.type],
        ["target_id", .target.id],
        ["alert_type", .data.type],
        ["name", (.data.data | objects | .name)],
        ["path", (.data.data | objects | .path)]
      ]
    | map(select(.[1] != null and .[1] != "") | "\(.[0])=\(.[1] | esc)")
    | "komodo_alert,\(join(",")) ts=\($alert.ts)i"
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
printf '%s' "$lines"
printf 'komodo_alert_collection pages=%di,overflow=%di\n' "$pages" "$overflow"
