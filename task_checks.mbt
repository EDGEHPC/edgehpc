// SPDX-License-Identifier: GPL-2.0-only

///|
/// Evaluate the node's own policy against a snapshot on behalf of a task.
/// This is a point-in-time verdict, not the sustained alert state machine.
fn task_checks(policy : Policy, sample : Snapshot) -> Json {
  let checks = policy.rules.map(rule => {
    let (metric, sensor) : (String, Json) = match rule.metric {
      Temperature(zone) => ("temperature_millicelsius", Json::string(zone))
      DataAvailable => ("data_available_bytes", Json::null())
    }
    let (observed, status) = match rule.reading(sample) {
      Some(value) if rule.violates(value) => (Some(value), "out_of_range")
      Some(value) => (Some(value), "within_range")
      None => (None, "unknown")
    }
    Json::object({
      "rule_id": Json::string(rule.id),
      "metric": Json::string(metric),
      "sensor": sensor,
      "threshold": Json::string(rule.threshold.to_string()),
      "observed": json_ms(observed),
      "status": Json::string(status),
    })
  })
  Json::array(checks)
}

///|
fn validate_task_checks(value : Json, readings : Json) -> Unit raise {
  guard value is Array(entries) &&
    entries.length() <= 32 &&
    readings
    is {
      "temperatures_millicelsius": Object(temperatures),
      "data_available_bytes": disk,
      ..
    } else {
    raise InvalidResult
  }
  let ids : Set[String] = Set([])
  for entry in entries {
    guard entry is Object(fields) &&
      fields.length() == 6 &&
      fields.get("rule_id") is Some(String(id)) &&
      valid_id(id) &&
      !ids.contains(id) &&
      fields.get("metric") is Some(String(metric)) &&
      fields.get("threshold").bind(parse_signed_decimal) is Some(threshold) &&
      fields.get("observed") is Some(observed) &&
      fields.get("status") is Some(String(status)) else {
      raise InvalidResult
    }
    ids.add(id)
    let (reading, above) = match (metric, fields.get("sensor")) {
      ("temperature_millicelsius", Some(String(sensor))) if valid_id(sensor) &&
        threshold >= -2147483648L &&
        threshold <= 2147483647L =>
        (temperatures.get(sensor).bind(integer), true)
      ("data_available_bytes", Some(Null)) if threshold >= 0L =>
        (parse_signed_decimal(disk), false)
      _ => raise InvalidResult
    }
    match reading {
      Some(n) => {
        let outside = if above { n >= threshold } else { n < threshold }
        let expected = if outside { "out_of_range" } else { "within_range" }
        guard parse_signed_decimal(observed) == Some(n) && status == expected else {
          raise InvalidResult
        }
      }
      None => {
        guard observed is Null && status == "unknown" else {
          raise InvalidResult
        }
      }
    }
  }
}
