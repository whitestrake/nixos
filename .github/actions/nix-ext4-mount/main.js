const { execFileSync } = require("node:child_process");
const path = require("node:path");

function input(name) {
  const value = process.env[`INPUT_${name.toUpperCase()}`] ?? process.env[`INPUT_${name.toUpperCase().replaceAll("-", "_")}`];
  if (!value) {
    throw new Error(`Missing required input: ${name}`);
  }
  return value;
}

execFileSync("/bin/bash", [path.join(__dirname, "main.sh")], {
  env: {
    ...process.env,
    ACTION_IMAGE_SIZE: input("image-size"),
    ACTION_SYSTEM: input("system"),
  },
  stdio: "inherit",
});
