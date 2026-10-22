# Changelog

## v1.1.0 — 2026-10-21

### 修复

- **机型识别改为按 `product_name`**：
  - `BayTrail` / `InFocus` / `KJ-ONE` → InFocus KJ-ONE（只修 TF 卡槽）
  - `Kangaroo` → Kangaroo 二代（关机/重启 + 电池 UPS）
  - 厂商 `Foxconn` 不再作为主判据（两台机器厂商都是 Foxconn），只在 `product_name` 读不到时兜底并排除 BayTrail。
  修复了 InFocus 被误判为 Kangaroo、状态页显示出关机钩子/UPS ❌ 的问题。
- 状态页增加 `机型: <vendor> <product> (<version>)` 和 `识别: ...` 行，一眼能看出识别结果。

## v1.0.0 — 2026-10-21

- 首个版本：Kangaroo 二代关机/重启修复（systemd-shutdown 钩子）、内置电池 UPS 识别（DSDT override）、
  InFocus KJ-ONE TF 卡槽只读修复（`sdhci.debug_quirks=0x10000`）。
