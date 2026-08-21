def isConfiguration:
  (startswith("deploy-health-rollback-script-") or startswith("check-")) | not;

([.results[] | select(.type == "EVAL" and .success) | .attr | select(isConfiguration)] | unique | sort) as $evaluated
| ([
    .results[]
    | select(.type == "BUILD" and .success)
    | select(.attr | isConfiguration)
    | {host: .attr, storePath: .outputs.out}
  ] | sort_by(.host)) as $built
| ($built | group_by(.host) | map(select(length > 1) | .[0].host)) as $duplicates
| ($built | map(select(.storePath | type != "string") | .host)) as $missing_outputs
| if ($duplicates | length) > 0
  then error("duplicate successful BUILD records: \($duplicates | join(", "))")
  elif ($missing_outputs | length) > 0
  then error("successful BUILD records missing outputs.out: \($missing_outputs | join(", "))")
  elif ($evaluated | length) == 0
  then error("no successful EVAL attributes")
  elif $evaluated != ($built | map(.host))
  then error("successful BUILD outputs do not match successful EVAL attributes")
  else $built
  end
