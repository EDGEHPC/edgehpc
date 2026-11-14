// SPDX-License-Identifier: GPL-2.0-only

///|
pub(all) enum Delivery {
  Alert(Event)
  Result(TaskResult)
}

///|
pub fn Delivery::id(self : Delivery) -> String {
  match self {
    Alert(event) => event.id
    Result(result) => result.delivery_id()
  }
}

///|
pub fn Delivery::node_id(self : Delivery) -> String {
  match self {
    Alert(event) => event.finding.node_id
    Result(result) => result.node_id
  }
}

///|
pub fn Delivery::payload(self : Delivery) -> Json {
  match self {
    Alert(event) => event.payload()
    Result(result) => result.payload()
  }
}

///|
pub fn delivery_from_json(value : Json) -> Delivery raise {
  if value is { "kind": String("health_check_result"), .. } {
    Result(task_result_from_json(value))
  } else {
    Alert(event_from_json(value))
  }
}

///|
pub fn parse_delivery(source : StringView) -> Delivery raise {
  delivery_from_json(
    @json.parse(
      source,
      reject_duplicate_keys=true,
      preserve_number_repr=true,
      max_nesting_depth=12,
    ),
  )
}
