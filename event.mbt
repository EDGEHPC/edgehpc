// SPDX-License-Identifier: GPL-2.0-only

///|
pub suberror ProtocolError {
  InvalidEvent
  InvalidAcknowledgement
}

///|
/// A trusted alert payload with an identifier stable across replay and restart.
pub struct Event {
  id : String
  finding : Finding
}

///|
pub fn Event::from_finding(finding : Finding) -> Event {
  let { node_id, rule_id, sample, .. } = finding
  {
    finding,
    id: "\{node_id}:\{sample.boot_id}:\{rule_id}:\{sample.monotonic_ms}",
  }
}

///|
pub fn Event::payload(self : Event) -> Json {
  let f = self.finding
  let (metric, sensor) : (String, Json) = match f.metric {
    Temperature(sensor) => ("temperature_millicelsius", Json::string(sensor))
    DataAvailable => ("data_available_bytes", Json::null())
  }
  Json::object({
    "schema_version": 1,
    "event_id": Json::string(self.id),
    "node_id": Json::string(f.node_id),
    "rule_id": Json::string(f.rule_id),
    "metric": Json::string(metric),
    "sensor": sensor,
    "threshold": Json::string(f.threshold.to_string()),
    "observed": Json::string(f.observed.to_string()),
    "consecutive": Json::number(f.consecutive.to_double()),
    "boot_id": Json::string(f.sample.boot_id),
    "first_monotonic_ms": Json::string(f.since_ms.to_string()),
    "last_monotonic_ms": Json::string(f.sample.monotonic_ms.to_string()),
    "occurred_at_ms": Json::string(f.occurred_at_ms.to_string()),
  })
}

///|
fn parse_signed_decimal(value : Json) -> Int64? {
  guard value is String(s) else { return None }
  let n = @string.parse_int64(s) catch { _ => return None }
  if n.to_string() == s {
    Some(n)
  } else {
    None
  }
}

///|
fn event_from_json(value : Json) -> Event raise {
  guard value is Object(f) &&
    f.length() == 13 &&
    f.get("schema_version").bind(integer) is Some(1L) &&
    f.get("event_id") is Some(String(id)) &&
    f.get("node_id") is Some(String(node_id)) &&
    valid_id(node_id) &&
    f.get("rule_id") is Some(String(rule_id)) &&
    valid_id(rule_id) &&
    f.get("boot_id") is Some(String(boot_id)) &&
    valid_id(boot_id) &&
    f.get("metric") is Some(String(name)) &&
    f.get("threshold").bind(parse_signed_decimal) is Some(threshold) &&
    f.get("observed").bind(parse_signed_decimal) is Some(observed) &&
    f.get("consecutive").bind(integer) is Some(consecutive) &&
    consecutive >= 2L &&
    consecutive <= 120L &&
    f.get("first_monotonic_ms").bind(parse_signed_decimal) is Some(since_ms) &&
    f.get("last_monotonic_ms").bind(parse_signed_decimal) is Some(monotonic_ms) &&
    since_ms >= 0L &&
    monotonic_ms > since_ms &&
    f.get("occurred_at_ms").bind(parse_signed_decimal) is Some(occurred_at_ms) &&
    occurred_at_ms >= 0L else {
    raise InvalidEvent
  }
  let metric = match (name, f.get("sensor")) {
    ("temperature_millicelsius", Some(String(sensor))) if valid_id(sensor) &&
      threshold >= -2147483648L &&
      observed <= 2147483647L &&
      observed >= threshold => Temperature(sensor)
    ("data_available_bytes", Some(Null)) if observed >= 0L &&
      observed < threshold => DataAvailable
    _ => raise InvalidEvent
  }
  let event = Event::from_finding({
    node_id,
    rule_id,
    metric,
    threshold,
    observed,
    consecutive: consecutive.to_int(),
    since_ms,
    sample: { boot_id, monotonic_ms, },
    occurred_at_ms,
  })
  guard id == event.id else { raise InvalidEvent }
  event
}

///|
/// Decode a bounded, versioned event without accepting path syntax or mismatched IDs.
pub fn parse_event(source : StringView) -> Event raise {
  event_from_json(
    @json.parse(
      source,
      reject_duplicate_keys=true,
      preserve_number_repr=true,
      max_nesting_depth=8,
    ),
  )
}

///|
pub fn acknowledgement(id : String) -> Json {
  Json::object({ "schema_version": 1, "event_id": Json::string(id) })
}

///|
pub fn verify_acknowledgement(source : StringView, id : String) -> Unit raise {
  let value = @json.parse(
    source,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
    max_nesting_depth=4,
  )
  guard value is Object(fields) &&
    fields.length() == 2 &&
    fields.get("schema_version").bind(integer) is Some(1L) &&
    fields.get("event_id") is Some(String(actual)) &&
    actual == id else {
    raise InvalidAcknowledgement
  }
}
