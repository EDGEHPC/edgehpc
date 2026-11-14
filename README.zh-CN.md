# EdgeHPC

[English](README.md)

EdgeHPC 用 MoonBit 开发，面向网络不稳定的 ARM Linux 节点。控制端为指定节点排任务，节点主动领取并落盘，再读取本机健康快照和规则。领到的任务断网也能做完；持续过温或磁盘余量不足也在本机判定。

## 本地试用

用 Linux、MoonBit（CI 固定为 `moonc v0.10.20+65efd5b93`）、C 编译器和 Python 3。按[快速开始](README.md#quick-start)编译程序、生成临时凭据和样例快照、启动控制端。待控制端打印 `listening` 后，在同一个终端执行：

```sh
"$BIN" node sync "$LAB/node" examples/policy.json http://127.0.0.1:8420 "$LAB/node-token"
kill "$server"
wait "$server" || true

# 控制端已停止，节点仍能完成已领取的任务。
"$BIN" node sample "$LAB/node" examples/policy.json "$LAB/health.json"
"$BIN" node status "$LAB/node" lab-a
```

重启控制端，再执行 `node sync`，随后用 `controller status "$LAB/controller" lab-a` 查看结果。常驻运行用 `node run STATE_DIR POLICY SNAPSHOT ORIGIN TOKEN_FILE`，采样和网络重试各自运行。首版只接收 `health-check`，不接受任意命令。

## 实现范围

- 巡检返回本地读数和范围判断，缺失读数标记为未知；持续告警按可配置的阈值、连续采样数和最大间隔单独判定。重复读取同一份快照不累加。
- 待回传的任务结果和告警存入本地持久状态，重启可续。告警队列满时保留已有记录，暂缓新告警；任务结果另有一个保留位置。
- 控制端写入后才回执，同 ID 同内容的重传不重复入库。节点收到匹配的回执后才移除待传记录。
- 每个节点单独配凭据。HTTP 只监听环回地址，跨主机用可信证书的 HTTPS 反代。控制端最多保留 512 个任务和 2,048 个告警，目前不自动清理历史。

[ARMHPC 节点部署说明](deploy/README.md)包含健康采集适配、systemd 服务和 HTTPS 接入。板卡固件和签名升级仍由 [armbian-hpc](https://github.com/EDGEHPC/armbian-hpc) 和 [armhpc-ota](https://github.com/EDGEHPC/armhpc-ota) 负责。本仓库暂未发布刷机镜像，也未做实体板验收。

## 验证

```sh
moon fmt --check
moon check -d
moon test
moon test --target native
moon build --target native --release cmd/edgehpc
python3 tests/e2e.py --native-tls "$PWD/_build/native/release/build/cmd/edgehpc/edgehpc.exe"
python3 deploy/test_export.py
```

进程测试只使用环回网络和合成快照。原生 HTTPS 用例需要 OpenSSL。源码采用 [GPL-2.0-only](LICENSE)，提交报告时请移除真实设备身份、日志和凭据，参见[贡献说明](https://github.com/EDGEHPC/.github/blob/main/CONTRIBUTING.zh-CN.md)。
