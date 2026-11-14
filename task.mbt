// SPDX-License-Identifier: GPL-2.0-only

///|
pub suberror TaskError {
  InvalidTask
  InvalidResult
}

///|
/// New task kinds must be implemented on the node. Commands are never sent as code.
pub struct Task {
  id : String
  node_id : String
}

///|
pub fn Task::health_check(id : String, node_id : String) -> Task raise {
  guard valid_id(id) && valid_id(node_id) else { raise InvalidTask }
  { id, node_id, }
}

///|
pub fn Task::payload(self : Task) -> Json {
  Json::object({
    "schema_version": 1,
    "task_id": Json::string(self.id),
    "node_id": Json::string(self.node_id),
    "kind": "health_check",
  })
}

///|
pub fn task_from_json(value : Json) -> Task raise {
  guard value is Object(fields) &&
    fields.length() == 4 &&
    fields.get("schema_version") is Some(Number(1.0, ..)) &&
    fields.get("task_id") is Some(String(id)) &&
    fields.get("node_id") is Some(String(node_id)) &&
    fields.get("kind") is Some(String("health_check")) else {
    raise InvalidTask
  }
  Task::health_check(id, node_id)
}

///|
pub fn parse_task(source : StringView) -> Task raise {
  task_from_json(
    @json.parse(source, reject_duplicate_keys=true, max_nesting_depth=8),
  )
}

///|
pub struct TaskResult {
  task_id : String
  node_id : String
  successful : Bool
  sample : Cursor?
  collected_at_ms : Int64?
  finished_at_ms : Int64
  readings : Json
  checks : Json
}

///|
/// Execute an allowlisted task using a sample read on the edge node.
pub fn Task::execute(
  self : Task,
  snapshot : Snapshot?,
  finished_at_ms : Int64,
  policy? : Policy,
) -> TaskResult {
  match snapshot {
    Some(s) =>
      {
        task_id: self.id,
        node_id: self.node_id,
        successful: true,
        sample: Some({ boot_id: s.boot_id, monotonic_ms: s.monotonic_ms, }),
        collected_at_ms: Some(s.epoch_ms),
        finished_at_ms,
        readings: readings_json(s.temperatures, s.data_available_bytes),
        checks: policy.map(p => task_checks(p, s)).unwrap_or(Json::array([])),
      }
    None =>
      {
        task_id: self.id,
        node_id: self.node_id,
        successful: false,
        sample: None,
        collected_at_ms: None,
        finished_at_ms,
        readings: Json::null(),
        checks: Json::array([]),
      }
  }
}

///|
fn json_ms(value : Int64?) -> Json {
  match value {
    Some(ms) => Json::string(ms.to_string())
    None => Json::null()
  }
}

///|
pub fn TaskResult::delivery_id(self : TaskResult) -> String {
  "task:\{self.node_id}:\{self.task_id}"
}

///|
pub fn TaskResult::payload(self : TaskResult) -> Json {
  Json::object({
    "schema_version": 1,
    "event_id": Json::string(self.delivery_id()),
    "task_id": Json::string(self.task_id),
    "node_id": Json::string(self.node_id),
    "kind": "health_check_result",
    "status": if self.successful {
      "completed"
    } else {
      "failed"
    },
    "finished_at_ms": Json::string(self.finished_at_ms.to_string()),
    "collected_at_ms": json_ms(self.collected_at_ms),
    "sample": match self.sample {
      Some(cursor) => cursor.to_json()
      None => Json::null()
    },
    "readings": self.readings,
    "checks": self.checks,
    "error": if self.successful {
      Json::null()
    } else {
      "snapshot_unavailable"
    },
  })
}

///|
fn validate_readings(value : Json) -> Unit raise {
  guard value is Object(fields) &&
    fields.length() == 2 &&
    fields.get("temperatures_millicelsius") is Some(Object(temps)) &&
    temps.length() <= 256 else {
    raise InvalidResult
  }
  for zone, reading in temps {
    guard valid_id(zone) &&
      integer(reading) is Some(n) &&
      n >= -2147483648L &&
      n <= 2147483647L else {
      raise InvalidResult
    }
  }
  match fields.get("data_available_bytes") {
    Some(Null) => ()
    Some(value) if parse_signed_decimal(value) is Some(n) && n >= 0L => ()
    _ => raise InvalidResult
  }
}

///|
pub fn task_result_from_json(value : Json) -> TaskResult raise {
  guard value is Object(fields) &&
    fields.length() == 12 &&
    fields.get("schema_version") is Some(Number(1.0, ..)) &&
    fields.get("event_id") is Some(String(id)) &&
    fields.get("task_id") is Some(String(task_id)) &&
    fields.get("node_id") is Some(String(node_id)) &&
    valid_id(task_id) &&
    valid_id(node_id) &&
    fields.get("kind") is Some(String("health_check_result")) &&
    fields.get("status") is Some(String(status)) &&
    fields.get("checks") is Some(checks) &&
    fields.get("finished_at_ms").bind(parse_signed_decimal)
    is Some(finished_at_ms) &&
    finished_at_ms >= 0L &&
    id == "task:\{node_id}:\{task_id}" else {
    raise InvalidResult
  }
  match
    (status, fields.get("sample"), fields.get("readings"), fields.get("error")) {
    ("completed", Some(Object(cursor)), Some(readings), Some(Null)) => {
      guard cursor.length() == 2 &&
        cursor.get("boot_id") is Some(String(boot_id)) &&
        valid_id(boot_id) &&
        cursor.get("monotonic_ms").bind(parse_signed_decimal)
        is Some(monotonic_ms) &&
        monotonic_ms >= 0L &&
        fields.get("collected_at_ms").bind(parse_signed_decimal)
        is Some(collected_at_ms) &&
        collected_at_ms >= 0L else {
        raise InvalidResult
      }
      validate_readings(readings)
      validate_task_checks(checks, readings)
      {
        task_id,
        node_id,
        successful: true,
        sample: Some({ boot_id, monotonic_ms, }),
        collected_at_ms: Some(collected_at_ms),
        finished_at_ms,
        readings,
        checks,
      }
    }
    ("failed", Some(Null), Some(Null), Some(String("snapshot_unavailable"))) if fields.get(
        "collected_at_ms",
      )
      is Some(Null) &&
      checks is Array([]) =>
      {
        task_id,
        node_id,
        successful: false,
        sample: None,
        collected_at_ms: None,
        finished_at_ms,
        readings: Json::null(),
        checks,
      }
    _ => raise InvalidResult
  }
}

///|
pub fn parse_task_result(source : StringView) -> TaskResult raise {
  task_result_from_json(
    @json.parse(
      source,
      reject_duplicate_keys=true,
      preserve_number_repr=true,
      max_nesting_depth=12,
    ),
  )
}
