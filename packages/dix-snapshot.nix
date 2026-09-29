# Package report glue: dix's closure diff over snapshots built from narinfos.
# No `version` attribute, so update-packages leaves it alone; Cargo.lock pins dix.
{rustPlatform}:
rustPlatform.buildRustPackage {
  name = "dix-snapshot";
  src = ./dix-snapshot;
  cargoLock.lockFile = ./dix-snapshot/Cargo.lock;
  meta.mainProgram = "dix-snapshot";
}
