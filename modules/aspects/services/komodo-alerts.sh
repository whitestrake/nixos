# shellcheck shell=bash
# Report Komodo's servers and open alerts as InfluxDB line protocol for
# Telegraf's exec input, in a fixed, small set of series:
#
# - komodo_alert ts, for every enabled server with unreachable alerts on,
#   tagged with its id and current name: the time Komodo opened its oldest
#   open ServerUnreachable alert, or 0 when it has none and Komodo reports it
#   Ok. A healthy server is an explicit 0, so an absent series means the
#   server left the inventory or Komodo stopped watching it, never that it is
#   well. An unreachable server with no open alert fails the run.
# - komodo_alert_open count, for every other open alert older than a minute,
#   in 6 types x 3 levels, all 18 always present (zero when empty).
# - komodo_alert_collection servers and overflow: how many server samples this
#   observation holds, and whether a limit cut it short.
#
# Every sample of a run carries the time the run started, so consumers can
# match an observation's samples to its collection samples exactly.
#
# The monitoring user must see every server, or a server it cannot see would
# read as removed: the run checks that the user holds Read on all servers
# (or is an admin) before trusting ListServers. ListAlerts returns 100 alerts
# a page, newest first, so pages are read until one comes back short.
# The reads are sequential, not one snapshot: alerts are read before the
# inventory, so a server deleted in between drops out rather than reading as
# healthy, and an alert on a server the inventory does not list is ignored.
#
# Output is held until everything is read and checked. A failed request, a
# malformed response, an inventory that disagrees with itself or a monitoring
# user that cannot see every server fails the run with no output, so Telegraf
# never sees a partial observation. When the read cap leaves alerts unread, or
# the inventory is over the series budget, only the collection samples are
# printed, with overflow=1 and servers=-1.
base="${KOMODO_URL:-http://127.0.0.1:9120}"
max_pages="${KOMODO_ALERT_MAX_PAGES:-10}"
# 29 servers + 18 summaries + 2 collection samples + scrape up = 50 series.
max_servers="${KOMODO_ALERT_MAX_SERVERS:-29}"
# Telegraf kills the run at 8s; give up on the reads before that.
deadline=$((SECONDS + ${KOMODO_ALERT_DEADLINE:-7}))
now_ms="${KOMODO_ALERT_NOW_MS:-$(date +%s%3N)}"

# komodo PATH [BODY]: one request to Core, within what is left of the deadline.
# The key and secret reach curl on stdin, never in its arguments, which any
# local user can read from the process list.
komodo() {
  local left=$((deadline - SECONDS))
  if [ "$left" -lt 1 ]; then
    echo "komodo-alerts: out of time before $1" >&2
    return 1
  fi
  if [ "$left" -gt 5 ]; then
    left=5
  fi
  curl --fail --silent --show-error --max-time "$left" \
    --header 'Content-Type: application/json' \
    --header @- \
    ${2:+--data "$2"} \
    "$base$1" <<<"x-api-key: $KOMODO_MONITOR_KEY
x-api-secret: $KOMODO_MONITOR_SECRET"
}

user="$(komodo /user)"
jq --exit-status '
  .admin == true
  or ((.all.Server // "None") | if type == "object" then .level else . end
      | IN("Read", "Execute", "Write"))
' <<<"$user" >/dev/null || {
  echo "komodo-alerts: the monitoring user cannot read all servers" >&2
  exit 1
}

# Pages are read by time, not by offset: each read asks for the alerts no
# newer than the oldest one already read. An offset would shift whenever an
# alert on an earlier page resolved between reads, and the alert at the
# boundary would be skipped; a time bound does not move. The oldest alert of a
# page is read again at the top of the next, so every later read must bring
# at least one alert not yet seen. More than a page of alerts sharing one
# timestamp could never be read past, so that ends the run as an overflow.
cursor=null
pages=0
overflow=0
alerts=""
while :; do
  response="$(komodo /read "$(jq --null-input --compact-output --argjson cursor "$cursor" '
    {type: "ListAlerts", params: {
      query: ({resolved: false} + if $cursor == null then {} else {ts: {"$lte": $cursor}} end),
      page: 0
    }}')")"
  pages=$((pages + 1))
  # One page's alerts per line, kept off the command line: a full collection
  # is far larger than one argument may be.
  page="$(jq --compact-output '
    if (.alerts | type) == "array"
      and (.alerts | all(.[]; type == "object" and (.ts | type == "number")))
      and (.next_page == null or (.next_page | type) == "number")
    then .alerts
    else error("malformed ListAlerts response")
    end
  ' <<<"$response")"
  more="$(jq --raw-output '.next_page != null' <<<"$response")"
  # How many of this page's alerts were not read before, and its oldest time.
  info="$(jq --raw-output --slurp '
    def oid: if type == "object" then .["$oid"] else . end;
    (.[:-1] | map(.[]._id | oid)) as $seen
    | .[-1]
    | "\(map(select(._id | oid | IN($seen[]) | not)) | length) \(map(.ts) | min)"
  ' <<<"$alerts$page")"
  read -r fresh oldest <<<"$info"
  alerts+="$page"$'\n'
  if [ "$more" != true ]; then
    break
  fi
  if [ "$pages" -ge "$max_pages" ] || { [ "$pages" -gt 1 ] && [ "$fresh" -eq 0 ]; }; then
    overflow=1
    break
  fi
  cursor="$oldest"
done

# limit 0 returns every server in one response.
servers="$(komodo /read '{"type":"ListServers","params":{"query":{},"limit":0}}')"

jq --raw-output --slurp \
  --argjson now "$now_ms" \
  --argjson overflow "$overflow" \
  --argjson max_servers "$max_servers" \
  --slurpfile servers <(printf '%s' "$servers") '
  def oid: if type == "object" then .["$oid"] else . end;
  # Komodo ids are MongoDB object ids, which also keeps them clear of the
  # reserved __collection__ id the Grafana rule adds.
  def id: type == "string" and test("^[0-9a-f]{24}$");
  def valid:
    type == "object"
    and (._id | oid | type == "string" and length > 0)
    and (.ts | type == "number")
    and (.level | type == "string")
    and (.target | type == "object")
    and (.target.id | type == "string")
    and (.data | type == "object")
    and (.data.type | type == "string");
  # Telegraf reads a backslash before a space, comma or equals sign as an
  # escape and any other backslash as itself, so only those three are escaped,
  # and a name ending in a backslash, which would escape the space after it,
  # cannot be written at all. Control characters would break the line.
  def named:
    type == "object" and (.id | id)
    and (.name | type == "string" and length > 0
      and (test("[[:cntrl:]]") | not) and (endswith("\\") | not))
    and (.info | type == "object")
    and (.info.state | IN("Ok", "NotOk", "Disabled"))
    and (.info.send_unreachable_alerts | type == "boolean");
  def esc: gsub("(?<c>[ ,=])"; "\\\(.c)");
  def types: ["ServerCpu", "ServerMem", "ServerDisk", "ServerVersionMismatch",
    "ResourceSyncPendingUpdates"];
  def levels: ["WARNING", "CRITICAL"];
  ("\($now)000000") as $ns
  | ($servers | if length == 1 then .[0] else error("malformed ListServers response") end) as $servers
  | add
  | if all(.[]; valid) then . else error("malformed alert") end
  | if ($servers | type) == "array" and ($servers | all(.[]; named)) then .
    else error("malformed ListServers response") end
  # A server listed twice must agree with itself.
  | ($servers
      | map({id, name, state: .info.state, alerts: .info.send_unreachable_alerts})
      | group_by(.id) | map(unique)) as $inventory
  | if all($inventory[]; length == 1) then . else error("ListServers lists a server twice") end
  | ($inventory | map(.[0])) as $inventory
  # Komodo never opens an unreachable alert for a disabled server or one with
  # unreachable alerts turned off, and closes any it had, so those are left
  # out: their series retire as no longer reported, never as recovered.
  | ($inventory | map(select(.state != "Disabled" and .alerts))) as $watched
  # Pages are read one after another, so an alert can show up on two of them.
  | unique_by(._id | oid)
  | if $overflow == 1 or ($inventory | length) > $max_servers then
      "komodo_alert_collection servers=-1i,overflow=1i \($ns)"
    else
      (map(select(.data.type == "ServerUnreachable"))
        | group_by(.target.id)
        | map({key: .[0].target.id, value: (map(.ts) | min | floor)})
        | from_entries) as $down
      | (map(select(.data.type != "ServerUnreachable" and $now - .ts > 60000)
          | {
              type: (.data.type as $t | if types | index($t) then $t else "Other" end),
              level: (.level as $l | if levels | index($l) then $l else "OTHER" end)
            })) as $open
      # A server is reported reachable only when Komodo says it is. Komodo
      # resolves the alerts of a server before deleting it, and opens an alert one
      # monitoring cycle after the server stops answering, so an unreachable
      # server with no open alert is not known to be well: the run fails,
      # before anything is printed.
      | ($watched
          | map(.ts = if $down[.id] then $down[.id]
              elif .state == "Ok" then 0
              else error("server \(.id) is unreachable with no open alert")
              end)) as $watched
      | ($watched[]
          | "komodo_alert,alert_type=ServerUnreachable,target_id=\(.id),target_name=\(.name | esc) ts=\(.ts)i \($ns)"),
        ((types + ["Other"])[] as $t
          | (levels + ["OTHER"])[] as $l
          | "komodo_alert_open,alert_type=\($t),level=\($l) count=\($open
              | map(select(.type == $t and .level == $l)) | length)i \($ns)"),
        "komodo_alert_collection servers=\($watched | length)i,overflow=0i \($ns)"
    end
' <<<"$alerts"
