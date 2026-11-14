// SPDX-License-Identifier: GPL-2.0-only

///|
let usage =
  #|Usage:
  #|  edgehpc inspect SNAPSHOT
  #|  edgehpc controller serve STATE_DIR CREDENTIALS_JSON 127.0.0.1:PORT
  #|  edgehpc controller submit STATE_DIR NODE_ID TASK_ID health-check
  #|  edgehpc controller status STATE_DIR [NODE_ID]
  #|  edgehpc node run STATE_DIR POLICY SNAPSHOT CONTROLLER_ORIGIN TOKEN_FILE
  #|  edgehpc node sample STATE_DIR POLICY SNAPSHOT
  #|  edgehpc node sync STATE_DIR POLICY CONTROLLER_ORIGIN TOKEN_FILE
  #|  edgehpc node status STATE_DIR NODE_ID

///|
fn output(value : Json) -> Unit {
  println(value.stringify(indent=2))
}

///|
async fn dispatch(args : Array[String]) -> Unit {
  match args {
    [_, "inspect", path] =>
      output(@health.inspect_snapshot(@store.read_file(path, snapshot_limit)))
    [_, "controller", "serve", root, config, address] => {
      let keys = @transport.parse_credentials(@store.read_file(config, 65536))
      @transport.serve(root, keys, address, ready=actual => {
        println("listening " + actual)
      })
    }
    [_, "controller", "submit", root, node_id, task_id, "health-check"] =>
      output(
        @controller.submit(root, @health.Task::health_check(task_id, node_id)),
      )
    [_, "controller", "status", root] => output(@controller.status(root))
    [_, "controller", "status", root, node_id] =>
      output(@controller.status(root, node_id~))
    [_, "node", "run", root, policy_path, snapshot, origin, token] => {
      let policy = load_policy(policy_path)
      run_node(
        root,
        policy,
        snapshot,
        load_client(origin, policy.node_id, token),
      )
    }
    [_, "node", "sample", root, policy, snapshot] =>
      output(node_sample(root, policy, snapshot))
    [_, "node", "sync", root, policy, origin, token] =>
      output(node_sync(root, policy, origin, token))
    [_, "node", "status", root, node_id] => output(@edge.status(root, node_id))
    [_, "--help"] | [_, "-h"] => println(usage)
    _ => {
      @stdio.stderr.text.write(usage + "\n")
      @env.exit(2)
    }
  }
}

///|
async fn main {
  dispatch(@env.args()) catch {
    error => {
      report("\{error}")
      @env.exit(1)
    }
  }
}
