// SPDX-License-Identifier: GPL-2.0-only

///|
pub suberror SnapshotError {
  InvalidSnapshot(String)
}

///|
fn readings_json(
  readings : Map[String, Int64],
  data_available_bytes : Int64?,
) -> Json {
  let temperatures : Map[String, Json] = Map([])
  for name, value in readings {
    temperatures[name] = Json::number(value.to_double())
  }
  Json::object({
    "temperatures_millicelsius": Json::object(temperatures),
    "data_available_bytes": match data_available_bytes {
      Some(bytes) => Json::string(bytes.to_string())
      None => Json::null()
    },
  })
}

///|
/// Extract the readings used by EdgeHPC from an ARMHPC health snapshot (schema 1).
/// This reports what was recorded; it does not infer health from missing readings.
pub fn inspect_snapshot(source : StringView) -> Json raise {
  let fields = snapshot_fields(source)
  readings_json(snapshot_temperatures(fields), snapshot_available(fields))
}
