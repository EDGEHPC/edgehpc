// SPDX-License-Identifier: GPL-2.0-only

///|
pub suberror PolicyError {
  InvalidPolicy(String)
}

///|
#derive(Eq)
pub(all) enum Metric {
  Temperature(String)
  DataAvailable
}

///|
pub extend Metric with Eq::{not_equal, equal}

///|
#derive(Eq)
pub(all) struct Rule {
  id : String
  metric : Metric
  threshold : Int64
  consecutive : Int32
  max_gap_ms : Int64
}

///|
pub extend Rule with Eq::{not_equal, equal}

///|
pub(all) struct Policy {
  node_id : String
  queue_capacity : Int32
  rules : Array[Rule]
}

///|
fn only_keys(fields : Map[String, Json], names : Array[String]) -> Bool {
  for key, _ in fields {
    if !names.contains(key) {
      return false
    }
  }
  true
}

///|
fn parse_rule(entry : Json) -> Rule raise {
  guard entry is Object(fields) &&
    only_keys(fields, [
      "id", "metric", "sensor", "threshold", "consecutive", "max_gap_seconds",
    ]) &&
    fields.get("id") is Some(String(id)) &&
    valid_id(id) &&
    fields.get("metric") is Some(String(name)) &&
    fields.get("threshold").bind(integer) is Some(threshold) &&
    fields.get("consecutive").bind(integer) is Some(consecutive) &&
    consecutive >= 2L &&
    consecutive <= 120L &&
    fields.get("max_gap_seconds").bind(integer) is Some(gap) &&
    gap >= 1L &&
    gap <= 3600L else {
    raise InvalidPolicy(
      "invalid rule: check id, metric, threshold, consecutive (2–120), and max_gap_seconds (1–3600)",
    )
  }
  let metric = match (name, fields.get("sensor")) {
    ("temperature_millicelsius", Some(String(sensor))) if valid_id(sensor) &&
      threshold >= -2147483648L &&
      threshold <= 2147483647L => Temperature(sensor)
    ("data_available_bytes", None) if threshold >= 0L => DataAvailable
    _ =>
      raise InvalidPolicy("invalid metric, sensor or threshold for rule \{id}")
  }
  {
    id,
    metric,
    threshold,
    consecutive: consecutive.to_int(),
    max_gap_ms: gap * 1000L,
  }
}

///|
/// Parse a version-1 EdgeHPC alert policy. Sizes and thresholds are exact integers.
pub fn parse_policy(source : StringView) -> Policy raise {
  let value = @json.parse(
    source,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
    max_nesting_depth=16,
  )
  guard value is Object(fields) &&
    only_keys(fields, ["schema_version", "node_id", "queue_capacity", "rules"]) &&
    fields.get("schema_version").bind(integer) is Some(1L) &&
    fields.get("node_id") is Some(String(node_id)) &&
    valid_id(node_id) &&
    fields.get("queue_capacity").bind(integer) is Some(capacity) &&
    capacity >= 1L &&
    capacity <= 1024L &&
    fields.get("rules") is Some(Array(entries)) &&
    entries.length() >= 1 &&
    entries.length() <= 32 &&
    entries.length().to_int64() <= capacity else {
    raise InvalidPolicy(
      "expected node_id, 1–32 rules, and queue_capacity between the rule count and 1024",
    )
  }
  let rules = []
  let ids : Map[String, Bool] = Map([])
  for entry in entries {
    let rule = parse_rule(entry)
    if ids.contains(rule.id) {
      raise InvalidPolicy("duplicate rule id: \{rule.id}")
    }
    ids[rule.id] = true
    rules.push(rule)
  }
  { node_id, queue_capacity: capacity.to_int(), rules, }
}
