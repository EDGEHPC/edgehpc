// SPDX-License-Identifier: GPL-2.0-only

///|
pub suberror ListenError {
  LoopbackRequired
}

///|
async fn unauthorized(reply : @http.ServerConnection) -> Unit {
  respond(reply, 401, "Unauthorized", { "error": "unauthorized" })
}

///|
async fn respond(
  reply : @http.ServerConnection,
  code : Int32,
  reason : String,
  body : Json,
) -> Unit {
  let data = @utf8.encode(body.stringify())
  reply.send_response(code, reason, extra_headers={
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    "Content-Length": data.length().to_string(),
  })
  reply.write(data[:])
  reply.end_response()
}

///|
async fn read_delivery(reply : @http.ServerConnection) -> @model.Delivery? {
  let source = @store.read_bounded(reply, 32768)
  Some(@model.parse_delivery(source)) catch {
    _ => None
  }
}

///|
async fn route(
  root : String,
  keys : Credentials,
  request : @http.RequestHeader,
  reply : @http.ServerConnection,
) -> Unit {
  let path = request.path
    .split("/")
    .map(segment => segment.to_owned())
    .to_array()
  match (request.meth, path) {
    (Get, ["", "healthz"]) => respond(reply, 200, "OK", { "status": "ready" })
    (Get, ["", "v1", "nodes", node_id, "tasks", "next"]) => {
      if !keys.accepts(node_id, request.headers.get("Authorization")) {
        return unauthorized(reply)
      }
      match @controller.pull(root, node_id) {
        Some(task) => respond(reply, 200, "OK", task.payload())
        None => {
          reply.send_response(204, "No Content", extra_headers={
            "Cache-Control": "no-store",
          })
          reply.end_response()
        }
      }
    }
    (Post, ["", "v1", "nodes", node_id, "deliveries"]) => {
      if !keys.accepts(node_id, request.headers.get("Authorization")) {
        return unauthorized(reply)
      }
      match read_delivery(reply) {
        Some(delivery) => {
          let ack = @controller.receive(root, node_id, delivery)
          respond(reply, 200, "OK", ack)
        }
        None =>
          respond(reply, 400, "Bad Request", { "error": "invalid_delivery" })
      }
    }
    _ => respond(reply, 404, "Not Found", { "error": "not_found" })
  }
}

///|
/// Bind to loopback only and handle at most one request per connection. A TLS
/// reverse proxy can expose this service; admin submit/list are local commands.
pub async fn serve(
  root : String,
  keys : Credentials,
  address : String,
  ready~ : (String) -> Unit = _ => (),
) -> Unit {
  let addr = @socket.Addr::parse(address)
  guard !addr.is_ipv6() && address.has_prefix("127.0.0.1:") else {
    raise LoopbackRequired
  }
  let server = @socket.TcpServer(addr, reuse_addr=true)
  defer server.close()
  ready(server.addr.to_string())
  server.run_forever(allow_failure=true, max_connections=64, (socket, _) => {
    let reply = @http.ServerConnection::new(socket)
    defer reply.close()
    @async.with_timeout(5000, () => {
      let request = reply.read_request()
      route(root, keys, request, reply) catch {
        @controller.Conflict | @controller.UnknownTask =>
          respond(reply, 409, "Conflict", { "error": "conflict" })
        @controller.CapacityReached =>
          respond(reply, 503, "Service Unavailable", {
            "error": "controller_capacity",
          })
        @store.LimitExceeded =>
          respond(reply, 413, "Payload Too Large", {
            "error": "delivery_too_large",
          })
        @utf8.Malformed(_) =>
          respond(reply, 400, "Bad Request", { "error": "invalid_utf8" })
        _ =>
          respond(reply, 500, "Internal Server Error", {
            "error": "controller_storage",
          })
      }
    })
  })
}
