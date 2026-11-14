// SPDX-License-Identifier: GPL-2.0-only

///|
pub suberror SnapshotError {
  InvalidSnapshot(String)
}

///|
fn temperature(entry : Json) -> Int32? {
  guard entry is { "temperature_millicelsius": String(value), .. } else {
    return None
  }
  Some(@string.parse_int(value)) catch {
    _ => None
  }
}

///|
fn available_bytes(report : Map[String, Json]) -> Json {
  guard report.get("DATA") is Some(Object(data)) &&
    data.get("available_bytes") is Some(Number(_, repr=Some(raw))) else {
    return Json::null()
  }
  let count = @string.parse_int64(raw) catch { _ => return Json::null() }
  if count < 0L {
    Json::null()
  } else {
    // Keep large byte counts exact even in consumers that parse JSON numbers as doubles.
    Json::string(count.to_string())
  }
}

///|
/// Extract the readings used by EdgeHPC from an ARMHPC health snapshot (schema 1).
/// This reports what was recorded; it does not infer health from missing readings.
pub fn inspect_snapshot(source : StringView) -> Json raise {
  let snapshot = @json.parse(
    source,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  )
  guard snapshot is Object(fields) &&
    fields.get("schema_version") is Some(Number(1.0, ..)) else {
    raise InvalidSnapshot(
      "expected an ARMHPC health snapshot with schema_version 1",
    )
  }
  let temperatures : Map[String, Json] = Map([])
  match fields.get("thermal") {
    Some(Object(zones)) =>
      for name, zone in zones {
        if temperature(zone) is Some(value) {
          temperatures[name] = Json::number(value.to_double())
        }
      }
    _ => ()
  }
  Json::object({
    "temperatures_millicelsius": Json::object(temperatures),
    "data_available_bytes": available_bytes(fields),
  })
}
