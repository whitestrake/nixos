def storePath:
  type == "string"
  and test("^/nix/store/[0123456789abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+$");

def supportedSystem:
  . == "aarch64-darwin" or . == "aarch64-linux" or . == "x86_64-linux";

def configuration:
  type == "string"
  and test("^(nixosConfigurations|darwinConfigurations)\\.[A-Za-z0-9_-]+$");

def record:
  type == "object"
  and ((keys_unsorted | sort) == ["attr", "storePath", "system"])
  and (.attr | configuration)
  and (.system | supportedSystem)
  and (.storePath | storePath);

def namespaceSystem:
  (.attr | split(".")[0]) as $namespace
  | ($namespace != "darwinConfigurations" or .system == "aarch64-darwin")
  and ($namespace != "nixosConfigurations" or .system == "aarch64-linux" or .system == "x86_64-linux");

if type != "object" or ((keys_unsorted | sort) != ["records", "revision"]) then
  error("invalid CI build proof keys")
elif (.revision | (type != "string" or (test("^[0-9a-f]{40}$") | not))) then
  error("invalid CI build proof revision")
elif (.records | type != "array" or length == 0) then
  error("invalid CI build proof records")
elif any(.records[]; (record | not)) then
  error("invalid CI build proof record")
elif any(.records[]; (namespaceSystem | not)) then
  error("CI build proof namespace/system mismatch")
elif ((.records | map(.attr) | unique | length) != (.records | length)) then
  error("duplicate CI build proof attributes")
elif ((["aarch64-darwin", "aarch64-linux", "x86_64-linux"] - (.records | map(.system) | unique) | length) > 0) then
  error("CI build proof does not cover all systems")
else
  {
    revision: .revision,
    records: (.records | sort_by(.system, .attr) | map({attr, system, storePath}))
  }
end
