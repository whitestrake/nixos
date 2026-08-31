def configuration:
  . as $attr
  | split(".") as $path
  | if $path[0] == "check" then
      empty
    elif (
      ($path | length) == 2
      and (
        $path[0] == "nixosConfiguration"
        or $path[0] == "darwinConfiguration"
      )
    ) then
      {
        attr: $attr,
        kind: $path[0],
        host: $path[1]
      }
    else
      error("unexpected nix-fast-build attribute path: \($attr)")
    end;

([.results[]
  | select(.type == "EVAL" and .success)
  | .attr
  | configuration
  ] | unique_by(.attr) | sort_by(.attr)) as $evaluated
| ([.results[]
  | select(.type == "BUILD" and .success)
  | . as $record
  | ($record.attr | configuration) as $configuration
  | $configuration + {storePath: $record.outputs.out}
  ] | sort_by(.attr)) as $built
| ($built | group_by(.attr) | map(select(length > 1) | .[0].attr)) as $built_duplicates
| ($built | map(select(.storePath | type != "string") | .attr)) as $missing_outputs
| if ($built_duplicates | length) > 0
  then error("duplicate successful BUILD records: \($built_duplicates | join(", "))")
  elif ($missing_outputs | length) > 0
  then error("successful BUILD records missing outputs.out: \($missing_outputs | join(", "))")
  elif ($evaluated | length) == 0
  then error("no successful EVAL attributes")
  elif ($evaluated | map(.attr)) != ($built | map(.attr))
  then error("successful BUILD outputs do not match successful EVAL attributes")
  else $built | map(del(.attr))
  end
