# EdgeHPC

[简体中文](README.zh-CN.md)

EdgeHPC is a MoonBit project for ARM Linux devices that need to keep working when the uplink is unreliable. Firmware and recovery stay in [armbian-hpc](https://github.com/EDGEHPC/armbian-hpc); signed updates stay in [armhpc-ota](https://github.com/EDGEHPC/armhpc-ota).

## Try it

Install [MoonBit](https://www.moonbitlang.com/download). CI uses `moonc v0.10.20+65efd5b93`.

```sh
moon check
moon test
moon run cmd/edgehpc -- inspect fixtures/health-v1.json
```

The command reads an ARMHPC health snapshot (schema 1) from a local file. It prints available thermal readings in millidegrees Celsius and the available DATA bytes. Byte counts are decimal strings to preserve precision; unavailable storage is `null`. A missing reading is not treated as a passing check. The fixture is synthetic.

## Scope

The current code is a read-only snapshot inspector. Next steps are sustained-threshold rules, a bounded persistent event queue with acknowledged replay, and systemd integration on one ARM64 board. No flashable image or board validation is available from this repository yet.

## Contributing

Open a focused PR, run `moon fmt --check` and `moon test`, and include a synthetic fixture for any new input behavior. Do not publish real device snapshots containing addresses, host names, logs or credentials. See the [organization contribution guide](https://github.com/EDGEHPC/.github/blob/main/CONTRIBUTING.md).

EdgeHPC source is licensed under [GPL-2.0-only](LICENSE). It reads the documented ARMHPC snapshot format; it does not bundle the firmware or OTA code.
