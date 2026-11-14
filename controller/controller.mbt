// SPDX-License-Identifier: GPL-2.0-only

///|
pub suberror ControllerError {
  InvalidState
  Conflict
  UnknownTask
  CapacityReached
}

///|
priv struct Job {
  task : @model.Task
  offered : Bool
  result : @model.TaskResult?
}

///|
priv struct State {
  jobs : Array[Job]
  alerts : Array[@model.Event]
}

///|
let state_limit : Int32 = 16 * 1024 * 1024

///|
let task_capacity : Int32 = 512

///|
let alert_capacity : Int32 = 2048

///|
fn Job::payload(self : Job) -> Json {
  Json::object({
    "task": self.task.payload(),
    "offered": if self.offered {
      Json::boolean(true)
    } else {
      Json::boolean(false)
    },
    "result": self.result
    .map(result => result.payload())
    .unwrap_or(Json::null()),
  })
}

///|
fn Job::status(self : Job) -> Json {
  let phase = match self.result {
    Some(result) if result.successful => "completed"
    Some(_) => "failed"
    None if self.offered => "dispatched"
    None => "queued"
  }
  Json::object({
    "task": self.task.payload(),
    "status": Json::string(phase),
    "result": self.result
    .map(result => result.payload())
    .unwrap_or(Json::null()),
  })
}

///|
fn State::payload(self : State) -> Json {
  Json::object({
    "schema_version": 1,
    "jobs": Json::array(self.jobs.map(job => job.payload())),
    "alerts": Json::array(self.alerts.map(alert => alert.payload())),
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
      "jobs": Array(entries),
      "alerts": Array(records),
      ..
    } &&
    entries.length() <= task_capacity &&
    records.length() <= alert_capacity else {
    raise InvalidState
  }
  let jobs = []
  let job_ids : Set[String] = Set([])
  for entry in entries {
    guard entry
      is {
        "task": task_json,
        "offered": offered_json,
        "result": result_json,
        ..
      } else {
      raise InvalidState
    }
    let task = @model.task_from_json(task_json)
    let key = "\{task.node_id}:\{task.id}"
    guard !job_ids.contains(key) else { raise InvalidState }
    job_ids.add(key)
    let offered : Bool = @json.from_json(offered_json)
    let result = if result_json is Null {
      None
    } else {
      let value = @model.task_result_from_json(result_json)
      guard offered && value.task_id == task.id && value.node_id == task.node_id else {
        raise InvalidState
      }
      Some(value)
    }
    jobs.push({ task, offered, result, })
  }
  let alerts = []
  let ids : Set[String] = Set([])
  for entry in records {
    guard @model.delivery_from_json(entry) is Alert(alert) &&
      !ids.contains(alert.id) else {
      raise InvalidState
    }
    ids.add(alert.id)
    alerts.push(alert)
  }
  { jobs, alerts, }
}

///|
async fn @store.Directory::load_state(self : @store.Directory) -> State {
  match self.read("controller.json", state_limit) {
    Some(source) => decode_state(source)
    None => { jobs: [], alerts: [], }
  }
}

///|
async fn @store.Directory::save_state(
  self : @store.Directory,
  state : State,
) -> Unit {
  self.write("controller.json", state.payload().stringify(), state_limit)
}

///|
/// Repeating a submission for the same node and task ID returns the recorded status.
pub async fn submit(root : String, task : @model.Task) -> Json {
  @store.transaction(root, dir => {
    let state = dir.load_state()
    for job in state.jobs {
      if job.task.id == task.id && job.task.node_id == task.node_id {
        return job.status()
      }
    }
    guard state.jobs.length() < task_capacity else { raise CapacityReached }
    let job : Job = { task, offered: false, result: None, }
    state.jobs.push(job)
    dir.save_state(state)
    job.status()
  })
}

///|
/// Keep offering the oldest incomplete task until its result is durably recorded.
/// An HTTP response lost before the node accepts the task is safe to retry.
pub async fn pull(root : String, node_id : String) -> @model.Task? {
  @store.transaction(root, dir => {
    let state = dir.load_state()
    for index, job in state.jobs {
      if job.task.node_id == node_id && job.result is None {
        if !job.offered {
          state.jobs[index] = { ..job, offered: true, }
          dir.save_state(state)
        }
        return Some(job.task)
      }
    }
    None
  })
}

///|
/// Acknowledge only after durable storage; an identical retry gets the same ACK.
pub async fn receive(
  root : String,
  node_id : String,
  delivery : @model.Delivery,
) -> Json {
  guard node_id == delivery.node_id() else { raise Conflict }
  @store.transaction(root, dir => {
    let state = dir.load_state()
    match delivery {
      Alert(alert) => {
        for stored in state.alerts {
          if stored.id == alert.id {
            guard stored.payload() == alert.payload() else { raise Conflict }
            return @model.acknowledgement(alert.id)
          }
        }
        guard state.alerts.length() < alert_capacity else {
          raise CapacityReached
        }
        state.alerts.push(alert)
        dir.save_state(state)
      }
      Result(result) => {
        let mut found = false
        for index, job in state.jobs {
          if job.task.node_id == node_id && job.task.id == result.task_id {
            guard job.offered else { raise Conflict }
            found = true
            if job.result is Some(stored) {
              guard stored.payload() == result.payload() else { raise Conflict }
            } else {
              state.jobs[index] = { ..job, result: Some(result), }
              dir.save_state(state)
            }
            break
          }
        }
        guard found else { raise UnknownTask }
      }
    }
    @model.acknowledgement(delivery.id())
  })
}

///|
pub async fn status(root : String, node_id? : String) -> Json {
  @store.transaction(root, dir => {
    let state = dir.load_state()
    let jobs : Array[Json] = []
    let alerts : Array[Json] = []
    for job in state.jobs {
      if node_id is None || node_id == Some(job.task.node_id) {
        jobs.push(job.status())
      }
    }
    for alert in state.alerts {
      if node_id is None || node_id == Some(alert.finding.node_id) {
        alerts.push(alert.payload())
      }
    }
    Json::object({ "tasks": Json::array(jobs), "alerts": Json::array(alerts) })
  })
}
