// SPDX-License-Identifier: GPL-2.0-only

///|
/// An ordered sample from the ARMHPC health collector. Clocks are in milliseconds.
pub(all) struct Snapshot {
  boot_id : String
  monotonic_ms : Int64
  epoch_ms : Int64
  temperatures : Map[String, Int64]
  data_available_bytes : Int64?
}

///|
/// A bounded ASCII identifier used in configs and on-disk records.
fn valid_id(value : String) -> Bool {
  if value.length() == 0 || value.length() > 64 {
    return false
  }
  for ch in value {
    match ch {
      'a'..<='z' | 'A'..<='Z' | '0'..<='9' | '-' | '_' => ()
      _ => return false
    }
  }
  true
}

///|
fn millis(value : Json) -> Int64? {
  guard value is Number(n, ..) && n >= 0.0 && n <= 9000000000000.0 else {
    return None
  }
  Some((n * 1000.0).to_int64())
}

///|
fn integer(value : Json) -> Int64? {
  guard value is Number(_, repr=Some(raw)) else { return None }
  Some(@string.parse_int64(raw)) catch {
    _ => None
  }
}

///|
fn snapshot_fields(source : StringView) -> Map[String, Json] raise {
  let snapshot = @json.parse(
    source,
    max_nesting_depth=32,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  )
  guard snapshot is Object(fields) &&
    fields.get("schema_version") is Some(Number(1.0, ..)) else {
    raise InvalidSnapshot(
      "expected an ARMHPC health snapshot with schema_version 1",
    )
  }
  fields
}

///|
fn snapshot_temperatures(fields : Map[String, Json]) -> Map[String, Int64] {
  let readings : Map[String, Int64] = Map([])
  if fields.get("thermal") is Some(Object(zones)) {
    for name, zone in zones {
      if valid_id(name) &&
        zone is { "temperature_millicelsius": String(raw), .. } {
        let value = Some(@string.parse_int(raw)) catch { _ => None }
        if value is Some(n) {
          readings[name] = n.to_int64()
        }
      }
    }
  }
  readings
}

///|
fn snapshot_available(features : Map[String, Json]) -> Int64? {
  guard features.get("DATA") is Some(Object(data)) &&
    data.get("available_bytes") is Some(value) &&
    integer(value) is Some(n) &&
    n >= 0L else {
    return None
  }
  Some(n)
}

///|
/// Decode a sample for alerting. Unlike inspect, this requires the collector's clocks.
pub fn parse_snapshot(source : StringView) -> Snapshot raise {
  let fields = snapshot_fields(source)
  guard fields.get("boot_id") is Some(String(boot_id)) &&
    valid_id(boot_id) &&
    fields.get("monotonic_seconds") is Some(uptime) &&
    millis(uptime) is Some(monotonic_ms) &&
    fields.get("epoch") is Some(timestamp) &&
    millis(timestamp) is Some(epoch_ms) else {
    raise InvalidSnapshot(
      "missing or invalid boot_id, monotonic_seconds, or epoch",
    )
  }
  {
    boot_id,
    monotonic_ms,
    epoch_ms,
    temperatures: snapshot_temperatures(fields),
    data_available_bytes: snapshot_available(fields),
  }
}
