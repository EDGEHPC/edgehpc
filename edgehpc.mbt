// SPDX-License-Identifier: GPL-2.0-only

///|
pub suberror SnapshotError {
  InvalidSnapshot(String)
}

///|
/// Extract the readings used by EdgeHPC from an ARMHPC health snapshot (schema 1).
/// This reports what was recorded; it does not infer health from missing readings.
pub fn inspect_snapshot(source : StringView) -> Json raise {
  let fields = snapshot_fields(source)
  let temperatures : Map[String, Json] = Map([])
  for name, value in snapshot_temperatures(fields) {
    temperatures[name] = Json::number(value.to_double())
  }
  Json::object({
    "temperatures_millicelsius": Json::object(temperatures),
    "data_available_bytes": match snapshot_available(fields) {
      Some(bytes) => Json::string(bytes.to_string())
      None => Json::null()
    },
  })
}
