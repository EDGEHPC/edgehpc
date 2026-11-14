// SPDX-License-Identifier: GPL-2.0-only

///|
test "parse ARMHPC sample identity, clocks and readings" {
  let sample = parse_snapshot(
    (
      #|{"schema_version":1,"boot_id":"aabc-0123","monotonic_seconds":121.25,"epoch":1760000000.5,"thermal":{"thermal_zone0":{"temperature_millicelsius":"-250"}},"DATA":{"available_bytes":9007199254740993}}
    ),
  )
  assert_eq(sample.boot_id, "aabc-0123")
  assert_eq(sample.monotonic_ms, 121250L)
  assert_eq(sample.epoch_ms, 1760000000500L)
  assert_eq(sample.temperatures.get("thermal_zone0"), Some(-250L))
  assert_eq(sample.data_available_bytes, Some(9007199254740993L))
}

///|
test "missing sensors are not reported as normal readings" {
  let sample = parse_snapshot(
    (
      #|{"schema_version":1,"boot_id":"boot-a","monotonic_seconds":1,"epoch":1760000000,"thermal":{"missing":{"temperature_millicelsius":null},"invalid.key":{"temperature_millicelsius":"90000"}},"DATA":{"error":"unmounted"}}
    ),
  )
  assert_true(sample.temperatures.is_empty())
  assert_eq(sample.data_available_bytes, None)
}

///|
test "alerting rejects missing and invalid time or boot identifiers" {
  for
    sample in [
      (
        #|{"schema_version":1,"boot_id":"boot-a","epoch":1760000000}
      ),
      (
        #|{"schema_version":1,"boot_id":"../a","monotonic_seconds":1,"epoch":1760000000}
      ),
      (
        #|{"schema_version":1,"boot_id":"boot-a","monotonic_seconds":-1,"epoch":1760000000}
      ),
      (
        #|{"schema_version":1,"boot_id":"boot-a","monotonic_seconds":1,"epoch":1e90}
      ),
    ] {
    let result = Some(parse_snapshot(sample)) catch { _ => None }
    assert_true(result is None)
  }
}
