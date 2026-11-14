// SPDX-License-Identifier: GPL-2.0-only

///|
let snapshot_limit : Int32 = 1024 * 1024

///|
async fn load_policy(path : String) -> @health.Policy {
  @health.parse_policy(@store.read_file(path, 128 * 1024))
}

///|
async fn load_client(
  origin : String,
  node_id : String,
  token_file : String,
) -> @transport.Client {
  let secret = @store.read_file(token_file, 128).trim().to_owned()
  @transport.Client(origin, node_id, secret)
}

///|
async fn load_sample(path : String) -> @health.Snapshot? {
  Some(@health.parse_snapshot(@store.read_file(path, snapshot_limit))) catch {
    _ => None
  }
}

///|
fn current_ms() -> Int64 {
  @env.now().reinterpret_as_int64()
}

///|
fn sample_is_fresh(sample : @health.Snapshot, now : Int64) -> Bool {
  // Production mode should not claim a successful inspection from an old file.
  // Allow a small wall-clock correction, but fail closed after a large jump.
  sample.epoch_ms <= now + 5000L && now - sample.epoch_ms <= 180000L
}

///|
async fn report(message : String) -> Unit {
  @stdio.stderr.text.write("edgehpc: " + message + "\n")
}

///|
async fn sample_loop(
  root : String,
  policy : @health.Policy,
  snapshot : String,
) -> Unit {
  let mut unavailable = false
  let mut saturated = false
  for ;; {
    let now = current_ms()
    let sample = match load_sample(snapshot) {
      Some(s) if sample_is_fresh(s, now) => Some(s)
      _ => None
    }
    let missing = sample is None
    if missing && !unavailable {
      report("no fresh health snapshot; check the host collector and its clock")
    }
    unavailable = missing
    let tick = @edge.tick(root, policy, sample, now)
    if tick.queue_full && !saturated {
      report("outbox full; retained pending alerts and deferred the new sample")
    }
    saturated = tick.queue_full
    @async.sleep(2000)
  }
}

///|
async fn sync_loop(root : String, client : @transport.Client) -> Unit {
  let mut wait_ms = 2000
  let mut failing = false
  for ;; {
    let outcome = @edge.synchronize(root, client.node_id, () => client.pull(), item => {
      client.send(item)
    })
    if outcome.transport_deferred {
      if !failing {
        report(
          "controller request not confirmed; retrying without dropping queued records",
        )
      }
      failing = true
      @async.sleep(wait_ms)
      wait_ms = if wait_ms < 16000 { wait_ms * 2 } else { 30000 }
    } else {
      if failing {
        report("controller reachable again")
      }
      failing = false
      wait_ms = 2000
      @async.sleep(wait_ms)
    }
  }
}

///|
async fn run_node(
  root : String,
  policy : @health.Policy,
  snapshot : String,
  client : @transport.Client,
) -> Unit {
  @store.with_worker(root, () => {
    @async.with_task_group(group => {
      group.spawn_bg(() => sample_loop(root, policy, snapshot))
      group.spawn_bg(() => sync_loop(root, client))
    })
  })
}

///|
async fn node_sample(
  root : String,
  policy_path : String,
  snapshot_path : String,
) -> Json {
  let policy = load_policy(policy_path)
  // The manual command accepts archived samples for reproducible replay.
  let snapshot = @health.parse_snapshot(
    @store.read_file(snapshot_path, snapshot_limit),
  )
  let outcome = @store.with_worker(root, () => {
    @edge.tick(root, policy, Some(snapshot), current_ms())
  })
  Json::object({
    "alerts": Json::number(outcome.alerts.to_double()),
    "task_completed": if outcome.task_completed {
      true
    } else {
      false
    },
    "queue_full": if outcome.queue_full {
      true
    } else {
      false
    },
  })
}

///|
async fn node_sync(
  root : String,
  policy_path : String,
  origin : String,
  token_path : String,
) -> Json {
  let policy = load_policy(policy_path)
  let client = load_client(origin, policy.node_id, token_path)
  let outcome = @store.with_worker(root, () => {
    @edge.synchronize(root, policy.node_id, () => client.pull(), item => {
      client.send(item)
    })
  })
  Json::object({
    "acknowledged": Json::number(outcome.acknowledged.to_double()),
    "task_accepted": if outcome.task_accepted {
      true
    } else {
      false
    },
    "transport_deferred": if outcome.transport_deferred {
      true
    } else {
      false
    },
  })
}
