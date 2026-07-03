const { execFileSync } = require("node:child_process");
const path = require("node:path");

function input(name) {
  return process.env[`INPUT_${name.toUpperCase()}`] ?? process.env[`INPUT_${name.toUpperCase().replaceAll("-", "_")}`] ?? "";
}

execFileSync("/bin/bash", [path.join(__dirname, "post.sh")], {
  env: {
    ...process.env,
    ACTION_SYSTEM: input("system"),
  },
  stdio: "inherit",
});
