# kangaroo-infocus-fnos-fix

飞牛（fnOS）设备的硬件问题一键修复脚本，覆盖两类小主机：

- **Foxconn Kangaroo 二代**（Atom x5-Z8500）
  - 关机/重启卡死、电源灯不灭
  - 内置电池不识别为 UPS
- **InFocus KJ-ONE**（Atom Z3735）
  - TF/microSD 卡槽只读、不可写

## 用法

```bash
sudo bash kangaroo-infocus-fnos-fix.sh            # 交互菜单（查询 / 修复 / 回滚）
sudo bash kangaroo-infocus-fnos-fix.sh --status   # 只读查看修复状态
```

## 说明

- 按 `product_name` 自动识别机型，只做对应设备的修复，不触碰无关配置。
- 所有改动（GRUB 内核参数、关机/重启钩子、initrd 的 DSDT override）都先备份；`update-grub` 失败自动回滚。
- 需要 `sudo` 执行；GRUB 改动需冷启动后生效。
- 脚本内含卸载/回滚入口，可随时撤销。

## 验证

2026-10-21 已在实际设备上验证通过。
