// SPDX-License-Identifier: GPL-2.0-only

///|
pub(all) struct Replay {
  acknowledged : Int32
  deferred : Bool
}

///|
/// Attempt bounded replay in durable order. send must return only after it
/// validates an ACK for the record. Transport failure leaves the head intact.
pub async fn replay(
  root : String,
  node_id : String,
  send : async (@model.Delivery) -> Unit,
  max_records~ : Int32 = 16,
) -> Replay {
  let mut count = 0
  while count < max_records {
    guard next_delivery(root, node_id) is Some(record) else { break }
    let sent = try {
      send(record)
      true
    } catch {
      _ => false
    }
    if !sent {
      return { acknowledged: count, deferred: true, }
    }
    if confirm(root, node_id, record.id()) {
      count += 1
    } else {
      // Normally impossible under the worker lease. Do not loop on a
      // concurrently changed head or claim it was removed by this call.
      return { acknowledged: count, deferred: true, }
    }
  }
  { acknowledged: count, deferred: false, }
}

///|
pub(all) struct Sync {
  acknowledged : Int32
  task_accepted : Bool
  transport_deferred : Bool
}

///|
/// Persist a pulled task before exposing it to the sampler.
pub async fn pull_work(
  root : String,
  node_id : String,
  pull : async () -> @model.Task?,
) -> (Bool, Bool) {
  if !can_receive(root, node_id) {
    return (false, false)
  }
  let task = pull() catch { _ => return (false, true) }
  match task {
    Some(task) => (accept(root, node_id, task), false)
    None => (false, false)
  }
}

///|
/// Poll before replaying alerts so an undeliverable alert cannot starve new work.
/// When the reserved result slot is occupied, successfully reporting it frees
/// the slot for the next poll. This function never runs the task itself.
pub async fn synchronize(
  root : String,
  node_id : String,
  pull : async () -> @model.Task?,
  send : async (@model.Delivery) -> Unit,
) -> Sync {
  let (task_accepted, pull_failed) = pull_work(root, node_id, pull)
  // If polling already proved the endpoint unavailable, don't repeat the same
  // timeout in the same iteration; the local sampler runs independently.
  if pull_failed {
    return { acknowledged: 0, task_accepted, transport_deferred: true, }
  }
  let result = replay(root, node_id, send)
  {
    acknowledged: result.acknowledged,
    task_accepted,
    transport_deferred: result.deferred,
  }
}
