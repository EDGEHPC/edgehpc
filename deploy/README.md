# Deploy on an existing ARMHPC node

This installs the EdgeHPC software on an existing Debian Bookworm ARMHPC system. It does not write a bootloader, repartition a disk or build a firmware image. The integration files are not yet verified on a physical OECT/OESP board.

## Controller

Build on a Linux host with the MoonBit toolchain and a C compiler:

```sh
moon build --target native --release cmd/edgehpc
install -Dm755 _build/native/release/build/cmd/edgehpc/edgehpc.exe "$HOME/.local/bin/edgehpc"
```

Run the controller in a private state directory and keep its credentials file readable only by its service account. Use one unique random 32-byte token per node. Register its lowercase hex representation in the controller's JSON and give the same token to that node in a separate file. See the [quick start](../README.md) for a self-contained setup.

The controller HTTP listener only binds to 127.0.0.1. For a remote ARM node, put a TLS reverse proxy in front of it, forwarding request paths, bodies and Authorization headers without rewriting them. Use a certificate trusted by the node's OS; install your organization's CA on the node if required. Do not log authorization headers or delivery bodies. Only the machine running the controller can enqueue work, using the local CLI and its state directory; the remotely exposed API cannot submit tasks or execute shell commands.

## Edge node

Use an ARM64 build of the executable. When building for Bookworm, build in a compatible ARM64 userspace; the Ubuntu CI binaries are for CI, not Bookworm distribution packages. Check the executable on the target before installing it.

On the ARMHPC board, after confirming that armhpc-health.timer exists:

```sh
getent passwd edgehpc >/dev/null ||
  sudo useradd --system --user-group --no-create-home --shell /usr/sbin/nologin edgehpc
sudo install -m755 ./edgehpc /usr/local/bin/edgehpc
sudo install -Dm644 deploy/edgehpc-node.service /etc/systemd/system/edgehpc-node.service
sudo install -Dm644 deploy/armhpc-health.service.d/50-edgehpc.conf \
  /etc/systemd/system/armhpc-health.service.d/50-edgehpc.conf
sudo install -Dm644 deploy/edgehpc-input.conf /etc/tmpfiles.d/edgehpc-input.conf
sudo install -Dm755 deploy/export-armhpc-snapshot.py \
  /usr/local/libexec/edgehpc/export-armhpc-snapshot.py
sudo install -d -m755 /etc/edgehpc
sudo install -m640 -o root -g edgehpc examples/policy.json /etc/edgehpc/policy.json
sudo install -m644 deploy/node.env.example /etc/edgehpc/node.env
```

Set the policy node_id to the name registered in the controller, choose the sensor shown by your board and set CONTROLLER_ORIGIN to the HTTPS endpoint. Place that node's provisioned token in /etc/edgehpc/node-token, owned by root with mode 0600. Do not save it in Git or bake it into an image.

```sh
sudo systemd-tmpfiles --create /etc/tmpfiles.d/edgehpc-input.conf
sudo systemctl daemon-reload
sudo systemctl start armhpc-health.service
sudo systemctl enable --now edgehpc-node.service
sudo systemctl status edgehpc-node.service
sudo -u edgehpc /usr/local/bin/edgehpc node status /var/lib/edgehpc lab-a
```

The ARMHPC collector keeps its 0600 snapshot untouched. The systemd drop-in exports only clocks, boot identity, temperatures and DATA free bytes to /run/edgehpc-input; it is root-owned and read-only to EdgeHPC. The main node process has no root permissions and stores its queue under /var/lib/edgehpc. Keep that filesystem persistent and leave room for the next atomic rewrite, even when the monitored DATA filesystem is short of space.

To remove the integration, disable the node service and remove only the installed EdgeHPC unit and ARMHPC drop-in, then reload systemd. Preserve /var/lib/edgehpc until pending results have been backed up or delivered. Do not remove or alter the original health collector.
