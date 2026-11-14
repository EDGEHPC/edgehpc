# EdgeHPC

[English](README.md)

EdgeHPC 用 MoonBit 开发，面向外网不稳定的 ARM Linux 边缘设备。板卡固件和恢复由 [armbian-hpc](https://github.com/EDGEHPC/armbian-hpc) 维护，签名升级仍由 [armhpc-ota](https://github.com/EDGEHPC/armhpc-ota) 负责。

## 本地试用

安装 [MoonBit 工具链](https://www.moonbitlang.cn/download)。CI 使用 `moonc v0.10.20+65efd5b93`。

```sh
moon check
moon test
moon run cmd/edgehpc -- inspect fixtures/health-v1.json
```

命令从本地文件读取 ARMHPC 健康快照（schema 1），输出各传感器的毫摄氏度读数和 DATA 剩余字节数。字节数用十进制字符串表示，避免大整数精度丢失；无法读取磁盘数据时返回 `null`。缺失读数不等于通过检查。仓库中的样例为合成数据。

## 开发范围

目前实现了只读快照检查。持续阈值告警、限容持久队列和确认后补传、`systemd` 服务接入是下一阶段工作。本仓库还没有可刷写的镜像，也没有板卡实测记录。

## 贡献

提交前运行 `moon fmt --check` 和 `moon test`，输入行为变化请附合成样例。不要公开含地址、主机名、日志或凭据的真实设备快照。参见[组织贡献说明](https://github.com/EDGEHPC/.github/blob/main/CONTRIBUTING.zh-CN.md)。

本仓库源码使用 [GPL-2.0-only](LICENSE)。EdgeHPC 读取 ARMHPC 健康快照，不打包固件或 OTA 源码。
