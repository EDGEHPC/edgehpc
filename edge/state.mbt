// SPDX-License-Identifier: GPL-2.0-only

///|
pub suberror EdgeError {
  StateMismatch
  InvalidState
  WrongNode
  Busy
}

///|
priv struct State {
  node_id : String
  monitor : @model.Monitor
  inbox : @model.Task?
  result : @model.TaskResult?
  pending_alerts : Array[@model.Event]
  recent_alerts : Array[@model.Event]
}

///|
let state_limit : Int32 = 2 * 1024 * 1024

///|
let recent_capacity = 64

///|
fn State::empty(node_id : String) -> State {
  {
    node_id,
    monitor: @model.Monitor(),
    inbox: None,
    result: None,
    pending_alerts: [],
    recent_alerts: [],
  }
}

///|
fn State::payload(self : State) -> Json {
  Json::object({
    "schema_version": 1,
    "node_id": Json::string(self.node_id),
    "monitor": self.monitor.to_json(),
    "inbox": self.inbox.map(t => t.payload()).unwrap_or(Json::null()),
    "result": self.result.map(r => r.payload()).unwrap_or(Json::null()),
    "pending_alerts": Json::array(self.pending_alerts.map(e => e.payload())),
    "recent_alerts": Json::array(self.recent_alerts.map(e => e.payload())),
  })
}

///|
fn decode_state(source : String) -> State raise {
  let value = @json.parse(
    source,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
    max_nesting_depth=20,
  )
  guard value
    is {
      "schema_version": Number(1.0, ..),
      "node_id": String(node_id),
      "monitor": monitor_json,
      "inbox": inbox_json,
      "result": result_json,
      "pending_alerts": Array(pending),
      "recent_alerts": Array(recent),
      ..
    } &&
    pending.length() <= 1024 &&
    recent.length() <= recent_capacity else {
    raise InvalidState
  }
  let monitor : @model.Monitor = @json.from_json(monitor_json)
  let inbox = if inbox_json is Null {
    None
  } else {
    Some(@model.task_from_json(inbox_json))
  }
  let result = if result_json is Null {
    None
  } else {
    Some(@model.task_result_from_json(result_json))
  }
  guard !(inbox is Some(_) && result is Some(_)) &&
    !(inbox is Some(t) && t.node_id != node_id) &&
    !(result is Some(r) && r.node_id != node_id) else {
    raise InvalidState
  }
  fn alerts(values : Array[Json]) -> Array[@model.Event] raise {
    let records = []
    let ids : Set[String] = Set([])
    for value in values {
      guard @model.delivery_from_json(value) is Alert(event) &&
        event.finding.node_id == node_id &&
        !ids.contains(event.id) else {
        raise InvalidState
      }
      ids.add(event.id)
      records.push(event)
    }
    records
  }
  {
    node_id,
    monitor,
    inbox,
    result,
    pending_alerts: alerts(pending),
    recent_alerts: alerts(recent),
  }
}

///|
async fn @store.Directory::load_state(
  self : @store.Directory,
  node_id : String,
) -> State {
  let state = match self.read("node.json", state_limit) {
    Some(text) => decode_state(text)
    None => State::empty(node_id)
  }
  guard state.node_id == node_id else { raise StateMismatch }
  state
}

///|
async fn @store.Directory::save_state(
  self : @store.Directory,
  state : State,
) -> Unit {
  self.write("node.json", state.payload().stringify(), state_limit)
}

///|
/// Take ownership before running a task. Receiving the same outstanding task is safe.
pub async fn accept(
  root : String,
  node_id : String,
  task : @model.Task,
) -> Bool {
  guard task.node_id == node_id else { raise WrongNode }
  @store.transaction(root, dir => {
    let state = dir.load_state(node_id)
    match (state.inbox, state.result) {
      (Some(existing), _) if existing.id == task.id => false
      (_, Some(existing)) if existing.task_id == task.id => false
      (Some(_), _) | (_, Some(_)) => raise Busy
      _ => {
        dir.save_state({ ..state, inbox: Some(task), })
        true
      }
    }
  })
}

///|
pub(all) struct Tick {
  alerts : Int32
  task_completed : Bool
  queue_full : Bool
}

///|
/// Persist rule progress and new alerts together. Completing a task moves it
/// from the inbox to its reserved delivery slot in the same transaction.
pub async fn tick(
  root : String,
  policy : @model.Policy,
  sample : @model.Snapshot?,
  finished_at_ms : Int64,
) -> Tick {
  @store.transaction(root, dir => {
    let state = dir.load_state(policy.node_id)
    let (monitor, pending_alerts, alerts, queue_full, new_sample) = match
      sample {
      Some(current) => {
        let (next, findings) = state.monitor.advance(policy, current)
        if state.pending_alerts.length() + findings.length() >
          policy.queue_capacity &&
          !findings.is_empty() {
          (state.monitor, state.pending_alerts, 0, true, false)
        } else {
          let pending = state.pending_alerts.copy()
          for finding in findings {
            pending.push(@model.Event::from_finding(finding))
          }
          let new_sample = match state.monitor.cursor {
            Some(last) =>
              last.boot_id != current.boot_id ||
              last.monotonic_ms < current.monotonic_ms
            None => true
          }
          (next, pending, findings.length(), false, new_sample)
        }
      }
      None => (state.monitor, state.pending_alerts, 0, false, false)
    }
    let task_completed = state.inbox is Some(_)
    let result = match state.inbox {
      Some(task) => Some(task.execute(sample, finished_at_ms))
      None => state.result
    }
    if new_sample || task_completed {
      dir.save_state({ ..state, monitor, pending_alerts, inbox: None, result, })
    }
    { alerts, task_completed, queue_full, }
  })
}

///|
pub async fn can_receive(root : String, node_id : String) -> Bool {
  @store.transaction(root, dir => {
    let state = dir.load_state(node_id)
    state.inbox is None && state.result is None
  })
}

///|
/// Prioritize an outstanding task result, then send alerts in FIFO order.
pub async fn next_delivery(root : String, node_id : String) -> @model.Delivery? {
  @store.transaction(root, dir => {
    let state = dir.load_state(node_id)
    match (state.result, state.pending_alerts) {
      (Some(result), _) => Some(@model.Result(result))
      (_, [event, ..]) => Some(@model.Alert(event))
      _ => None
    }
  })
}

///|
/// Only an acknowledgement for a currently queued ID can change the spool.
pub async fn confirm(
  root : String,
  node_id : String,
  delivery_id : String,
) -> Bool {
  @store.transaction(root, dir => {
    let state = dir.load_state(node_id)
    if state.result is Some(result) && result.delivery_id() == delivery_id {
      dir.save_state({ ..state, result: None, })
      true
    } else if state.pending_alerts is [event, .. rest] &&
      event.id == delivery_id {
      let recent = state.recent_alerts.copy()
      if recent.length() == recent_capacity {
        ignore(recent.remove(0))
      }
      recent.push(event)
      dir.save_state({
        ..state,
        pending_alerts: rest.to_owned(),
        recent_alerts: recent,
      })
      true
    } else {
      false
    }
  })
}

///|
pub async fn status(root : String, node_id : String) -> Json {
  @store.transaction(root, dir => {
    let state = dir.load_state(node_id)
    Json::object({
      "node_id": Json::string(node_id),
      "last_sample": state.monitor.cursor
      .map(c => c.to_json())
      .unwrap_or(Json::null()),
      "inbox": state.inbox.map(t => t.payload()).unwrap_or(Json::null()),
      "pending_result": state.result
      .map(r => r.payload())
      .unwrap_or(Json::null()),
      "pending_alerts": Json::array(state.pending_alerts.map(e => e.payload())),
      "recent_alerts": Json::array(state.recent_alerts.map(e => e.payload())),
    })
  })
}
