# kangaroo-infocus-fnos-fix

> 飞牛（fnOS）小主机的硬件问题一键修复脚本。按机型自动识别，只做对应设备的修复，改动前备份、可回滚。

![platform](https://img.shields.io/badge/platform-Linux%20(fnOS%2FDebian)-2f81f7)
![shell](https://img.shields.io/badge/shell-bash-4eaa25)
![devices](https://img.shields.io/badge/devices-Kangaroo%20II%20%7C%20InFocus%20KJ--ONE-8957e5)

---

## 修什么

| 设备 | 平台 | 问题 | 修复方式 |
|---|---|---|---|
| **Foxconn Kangaroo 二代** | Atom x5-Z8500 | 关机/重启卡死、电源灯常亮（短按电源键无反应） | 关机钩子：`poweroff` 直写 ACPI S5，`reboot` 走紧急重启 |
| **Foxconn Kangaroo 二代** | Atom x5-Z8500 | 内置电池不识别为 UPS（飞牛 UPS 页面空白） | 注入 DSDT override（`/boot/acpi_override.cpio`） |
| **InFocus KJ-ONE** | Atom Z3735 | TF/microSD 卡槽只读、不可写 | GRUB 加 `sdhci.debug_quirks=0x10000` |

## 快速开始

```bash
git clone https://github.com/txhtxh11/kangaroo-infocus-fnos-fix.git
cd kangaroo-infocus-fnos-fix

sudo bash kangaroo-infocus-fnos-fix.sh            # 交互菜单
sudo bash kangaroo-infocus-fnos-fix.sh --status   # 只读查看状态
```

菜单：

```
============================================================
  kangaroo-infocus-fnos-fix  v-ds-k-i-fix-1.1
  最后修改: 2026-10-21 16:05
============================================================
  1 = 查询状态（只读）
  2 = 全自动修复
  3 = 卸载/回滚
  0 = 退出
============================================================
```

## 机型识别

两台机器的 `sys_vendor` 都是 `Foxconn`，只能靠 `product_name` 区分：

| 设备 | `sys_vendor` | `product_name` | 工具做的修复 |
|---|---|---|---|
| Kangaroo 二代 | Foxconn | `Kangaroo Mobile Desktop` | 关机/重启钩子 + 电池 UPS |
| InFocus KJ-ONE | Foxconn | `BayTrail` | 仅 TF 卡槽只读 |

查看自己的机器：

```bash
cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name
```

`--status` 会直接告诉你识别成了哪台、哪些项已修/未修：

```
  机型: Foxconn Kangaroo Mobile Desktop (1.0)
  识别: Kangaroo 二代（关机/重启 + 电池 UPS）
  内核参数: reboot=kbd acpi=force
  关机/重启钩子: ✅
  电池 UPS 识别: ✅
```

## 原理

### 1. Kangaroo 关机不断电 / 重启卡死

内核在有序关机的收尾阶段（`device_shutdown()` 这一段）会间歇性挂死，导致：

- 关机时根本没走到 ACPI S5 → 机器停在 halt，**灯亮、断网、短按电源键没反应**；
- 重启时没走到复位 → 同样卡住。

实测证明硬件本身没问题（直接往 FADT 的 `PM1a_CNT` 写 S5 立刻断电；`sysrq-b` 59 秒自动重启成功）。

修复是在 systemd 的关机钩子目录放一个 `/usr/lib/systemd/system-shutdown/zz-s5-poweroff.sh`：

- `poweroff`：把 `SLP_TYP=7 | SLP_EN` 写到 I/O 口 `0x404`（PM1_CNT），立即断电；
- `reboot`：写 `/proc/sysrq-trigger` 的 `b`，走紧急重启，跳过会挂死的 `device_shutdown()`。

钩子在"文件系统全部卸载、sync 之后、`reboot(2)` 之前"执行，等价于"正常关机完成后拔插头"，
不会损坏数据。

### 2. 内置电池不识别为 UPS

Kangaroo 的 DSDT 没有给电池做 ACPI 描述（`No handler for Region [DVEC]`），
飞牛靠 `/sys/class/power_supply/BATC` 识别 UPS，所以页面空白。

修复是把一份改过的 DSDT（`acpi_override.cpio`，OEM Revision 3→4）拼到 initrd 前面，
让内核用覆盖表启动：

```
initrd /boot/acpi_override.cpio /boot/initrd.img-...
```

> 注意：`update-grub` 会覆盖 initrd 行，脚本在 `update-grub` 之后会自动重新拼接。

### 3. InFocus TF 卡槽只读

Bay Trail 的 SDHCI 控制器 WP# 引脚极性接反，内核误判为写保护（`mmcblkX: ... (ro)`）。
修复是在 `GRUB_CMDLINE_LINUX` 里加 `sdhci.debug_quirks=0x10000`。

## 安全性

- **改前备份**：`/etc/default/grub`、`/boot/grub/grub.cfg` 都带 `.bak-时间戳`。
- **只改该改的**：InFocus 只动 `GRUB_CMDLINE_LINUX`，不碰 initrd/关机钩子/UPS；Kangaroo 反之。
- **失败回滚**：`update-grub` 失败会自动恢复备份；卸载入口按 token 移除参数，不清空你原有的其它参数。
- **可逆**：菜单 `3 = 卸载/回滚`；关机钩子就是删一个文件。
- GRUB 改动需要**冷启动**生效；关机钩子可以下次关机直接生效。

## 验证

2026-10-21 在四台 Kangaroo 二代 + 一台 InFocus KJ-ONE 上实测：

| 项目 | 结果 |
|---|---|
| 关机（网页/命令） | 12 次，电源灯全部熄灭，短按电源键秒开 |
| 重启 | 6 次，65～99 秒自动回到系统，不用长按 |
| 电池 UPS | `BATC` / `upower` 正常识别 |
| InFocus TF 参数 | 写入 `GRUB_CMDLINE_LINUX`，保留原有参数，重复执行幂等 |

## 常见问题

<details>
<summary><b>为什么关机后灯还亮，但短按电源键能开机？</b></summary>

这说明其实已经进了 S5，只是灯由充电/待机电路直驱，属于另一类问题；本脚本针对的是"短按没反应"的真 halt。
</details>

<details>
<summary><b>关机钩子会丢数据吗？</b></summary>

不会。systemd-shutdown 的顺序是 `sync` → 杀进程 → 卸载所有文件系统 → **执行钩子** → `reboot(2)`，
切电时文件系统已经卸载干净。反证：改用钩子后开机日志里再没出现过 `uncleanly shut down`。
</details>

<details>
<summary><b>升级飞牛后要重做吗？</b></summary>

三项都可能被系统更新覆盖：

- 关机钩子：`ls /usr/lib/systemd/system-shutdown/zz-s5-poweroff.sh`，没了就重跑修复；
- DSDT override：`update-grub` 后 initrd 行可能被覆盖，重跑修复即可；
- GRUB 参数：`cat /proc/cmdline` 里确认 `reboot=`、`acpi=force`、`sdhci.debug_quirks` 还在。
</details>

<details>
<summary><b>nut-server 显示 failed 是脚本弄坏的吗？</b></summary>

不是。这几台机器 `ups.conf` 里没有定义 UPS，NUT 一直起不来（内建电池走 upower），属于历史现象。
</details>

## 更新日志

见 [CHANGELOG.md](CHANGELOG.md)。
