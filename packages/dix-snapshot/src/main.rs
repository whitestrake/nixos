//! Print dix's JSON report for two snapshot files:
//! {"closure": [[path, narSize], ...], "selected": [path, ...]}.
use std::{error::Error, fs, path::PathBuf};

use dix::{
  StorePath, StoreSnapshot, diff_store_snapshots, json::JsonReport, store::StorePathInfo,
};
use serde_json::Value;
use size::Size;

type Result<T> = std::result::Result<T, Box<dyn Error>>;

fn store_path(value: &Value) -> Result<StorePath> {
  let path = value.as_str().ok_or("store path must be a string")?;
  Ok(StorePath::try_from(PathBuf::from(path))?)
}

fn load(file: &str) -> Result<StoreSnapshot> {
  let snapshot: Value = serde_json::from_str(&fs::read_to_string(file)?)?;
  let entries = |key: &str| {
    snapshot[key]
      .as_array()
      .ok_or_else(|| format!("{file}: {key} must be an array"))
  };
  let closure = entries("closure")?
    .iter()
    .map(|entry| {
      let size = entry[1].as_i64().ok_or("narSize must be an integer")?;
      Ok(StorePathInfo::new(store_path(&entry[0])?, Size::from_bytes(size)))
    })
    .collect::<Result<_>>()?;
  let selected = entries("selected")?.iter().map(store_path).collect::<Result<_>>()?;
  Ok(StoreSnapshot { closure, selected })
}

fn main() -> Result<()> {
  let [_, old, new] = <[String; 3]>::try_from(std::env::args().collect::<Vec<_>>())
    .map_err(|_| "usage: dix-snapshot OLD.json NEW.json")?;
  let report = diff_store_snapshots(&load(&old)?, &load(&new)?);
  serde_json::to_writer(std::io::stdout(), &JsonReport::from(&report))?;
  Ok(())
}
