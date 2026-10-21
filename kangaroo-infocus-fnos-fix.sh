#!/bin/bash
# 工具名称: kangaroo-infocus-fnos-fix  v-ds-k-i-fix-1.1
# 最后修改: 2026-10-21 16:05
# 本版改动: 机型识别改为按 product_name（BayTrail=InFocus，Kangaroo=Kangaroo），
#           厂商 Foxconn 不再作为主判据，避免 InFocus 被误判成 Kangaroo
# 功能: Kangaroo 关机/重启卡住、电源灯不灭 + 内置电池 UPS 识别 + InFocus TF 卡槽只读修复
# 用法:
#   sudo bash kangaroo-infocus-fnos-fix.sh            # 交互菜单
#   sudo bash kangaroo-infocus-fnos-fix.sh --status   # 只读查看状态
set -u

TOOL_NAME="kangaroo-infocus-fnos-fix"
TOOL_VERSION="v-ds-k-i-fix-1.1"
TOOL_MODIFIED="2026-10-21 16:05"

HOOK_FILE="/usr/lib/systemd/system-shutdown/zz-s5-poweroff.sh"
STATE_MD5="/etc/kangaroo-fix.md5"
# 手工部署过的等价版本（带注释），视为已修复
KNOWN_MD5="45954b0683962ecb4b07aefdcd0fc83b"
OVERRIDE_FILE="/boot/acpi_override.cpio"
GRUB_DEFAULTS="/etc/default/grub"
GRUB_CFG="/boot/grub/grub.cfg"

DEF_BAK=""
CFG_BAK=""
CMDLINE_CHANGED=0

HOOK_SCRIPT='#!/bin/sh
# Kangaroo: last-step shutdown workaround (installed by kangaroo-infocus-fnos-fix)
set -u
PORT=/dev/port
if [ ! -c "$PORT" ]; then
    for d in /dev /run /tmp; do
        if [ -d "$d" ] && [ -w "$d" ]; then
            mknod "$d/port" c 1 4 2>/dev/null && PORT="$d/port" && break
        fi
    done
fi
case "${1:-}" in
poweroff)
    [ -c "$PORT" ] || exit 0
    python3 - "$PORT" <<'"'"'PY'"'"' || exit 0
import sys, time
p = sys.argv[1]
try: f = open(p, '"'"'r+b'"'"', buffering=0)
except: sys.exit(1)
PM1_CNT = 0x404
f.seek(PM1_CNT)
cur = int.from_bytes(f.read(2), '"'"'little'"'"')
base = cur & ~((7 << 10) | (1 << 13))
def wr(v):
    f.seek(PM1_CNT); f.write(v.to_bytes(2, '"'"'little'"'"')); f.flush()
wr(base | (7 << 10))
time.sleep(0.2)
wr(base | (7 << 10) | (1 << 13))
time.sleep(1.5)
sys.exit(0)
PY
    ;;
reboot)
    [ -w /proc/sysrq-trigger ] || exit 0
    echo b > /proc/sysrq-trigger
    ;;
esac
exit 0'

# ---------- 机型检测 ----------
# Kangaroo 二代 : sys_vendor=Foxconn, product_name=Kangaroo Mobile Desktop
# InFocus KJ-ONE: sys_vendor=Foxconn, product_name=BayTrail
# 两台厂商都是 Foxconn，只能靠 product_name 区分
dmi() { cat "/sys/class/dmi/id/$1" 2>/dev/null || true; }

is_infocus() {
    local m v
    m=$(dmi product_name)
    v=$(dmi product_version)
    echo "$m $v" | grep -qiE 'infocus|kj-?one|bay ?trail'
}

is_kangaroo() {
    local m
    m=$(dmi product_name)
    echo "$m" | grep -qi 'kangaroo' && return 0
    # 兜底：product_name 读不到时，Foxconn 且不是 BayTrail 才当 Kangaroo
    if [ -z "$m" ] && dmi sys_vendor | grep -qi 'foxconn' && ! is_infocus; then
        return 0
    fi
    return 1
}

# ---------- 通用工具 ----------
# 备份文件，成功时把备份路径打到 stdout（调用方负责显示）
mkbak() {
    local f="$1" ts out
    [ -f "$f" ] || return 1
    ts=$(date +%Y%m%d-%H%M%S)
    out="${f}.bak-${ts}"
    cp -a "$f" "$out" 2>/dev/null || return 1
    printf '%s\n' "$out"
}

run_update_grub() {
    local log
    log="/tmp/kangaroo-update-grub.$$"
    echo "  执行 update-grub..."
    if update-grub >"$log" 2>&1; then
        tail -n 3 "$log"
        rm -f "$log"
        return 0
    fi
    echo "  ---- update-grub 输出 ----"
    tail -n 10 "$log"
    echo "  -------------------------"
    rm -f "$log"
    return 1
}

# 取某个 GRUB_CMDLINE_* 变量的当前值（去掉外层引号）
get_cmdline_var() {
    local var="$1" line
    line=$(grep "^${var}=" "$GRUB_DEFAULTS" | head -n 1)
    [ -z "$line" ] && return 1
    printf '%s\n' "$line" | sed "s/^${var}=//; s/^\"//; s/\"$//"
}

# 去掉某个变量里的指定 token（按模式），返回 0 表示有改动
strip_tokens() {
    local var="$1"; shift
    local cur new tok pat
    cur=$(get_cmdline_var "$var") || return 1
    new=""
    for tok in $cur; do
        local drop=0
        for pat in "$@"; do
            case "$tok" in
            $pat) drop=1; break ;;
            esac
        done
        [ "$drop" = "1" ] && continue
        new="${new:+$new }$tok"
    done
    [ "$new" = "$cur" ] && return 1
    sed -i "s|^${var}=.*|${var}=\"$new\"|" "$GRUB_DEFAULTS"
    echo "  ✅ ${var}=\"$new\""
    CMDLINE_CHANGED=1
    return 0
}

# ---------- Kangaroo：内核参数 ----------
fix_kangaroo_cmdline() {
    local cur changed=0
    DEF_BAK=$(mkbak "$GRUB_DEFAULTS") || {
        echo "  ❌ 备份 $GRUB_DEFAULTS 失败，中止"
        return 1
    }
    echo "  备份: $DEF_BAK"

    cur=$(get_cmdline_var "GRUB_CMDLINE_LINUX_DEFAULT") || {
        echo "  ❌ $GRUB_DEFAULTS 里找不到 GRUB_CMDLINE_LINUX_DEFAULT= 行，未修改"
        return 1
    }

    case " $cur " in
    *" reboot="*)
        echo "  已有 $(printf '%s' "$cur" | grep -oE 'reboot=[^ ]+' | head -n 1)，保持不动（已验证的参数不覆盖）"
        ;;
    *)
        local rb="reboot=kbd"
        if grep -qi '^30:0e:d5:e7:83:d6$' /sys/class/net/*/address 2>/dev/null; then
            rb="reboot=acpi"
        fi
        cur="$cur $rb"
        changed=1
        echo "  缺少 reboot 参数，补 $rb"
        ;;
    esac

    case " $cur " in
    *" acpi=force "*) ;;
    *)
        cur="$cur acpi=force"
        changed=1
        ;;
    esac

    if [ "$changed" = "1" ]; then
        sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$cur\"|" "$GRUB_DEFAULTS"
        if ! grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_DEFAULTS"; then
            echo "  ❌ 写入 $GRUB_DEFAULTS 失败"
            return 1
        fi
        echo "  ✅ GRUB_CMDLINE_LINUX_DEFAULT=\"$cur\""
        CMDLINE_CHANGED=1
    else
        echo "  内核参数已正确，无需修改"
    fi
    return 0
}

# ---------- InFocus：内核参数 ----------
fix_infocus_cmdline() {
    local cur
    DEF_BAK=$(mkbak "$GRUB_DEFAULTS") || {
        echo "  ❌ 备份 $GRUB_DEFAULTS 失败，中止"
        return 1
    }
    echo "  备份: $DEF_BAK"

    if grep -q 'sdhci.debug_quirks' "$GRUB_DEFAULTS"; then
        echo "  TF 卡参数已存在，无需修改"
        return 0
    fi
    cur=$(get_cmdline_var "GRUB_CMDLINE_LINUX") || {
        echo "  ❌ 找不到 GRUB_CMDLINE_LINUX= 行，未修改"
        return 1
    }
    cur="$cur sdhci.debug_quirks=0x10000"
    sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$cur\"|" "$GRUB_DEFAULTS"
    echo "  ✅ GRUB_CMDLINE_LINUX=\"$cur\""
    CMDLINE_CHANGED=1
    return 0
}

# ---------- initrd 里补 acpi_override（幂等 + 原子写） ----------
patch_initrd_idempotent() {
    local out rc
    out=$(python3 - "$GRUB_CFG" <<'PY' 2>&1
import re, os, sys
p = sys.argv[1]
try:
    t = open(p).read()
except Exception as e:
    print("OPEN_FAIL: %s" % e)
    sys.exit(3)

count = 0
def repl(m):
    global count
    line = m.group(0)
    if 'acpi_override.cpio' in line:
        return line
    count += 1
    return m.group(1) + '/boot/acpi_override.cpio ' + m.group(2)

t2, n = re.subn(r'^(\s*initrd\s+)(/boot/.*)$', repl, t, flags=re.M)
if n == 0:
    print("NO_INITRD")
    sys.exit(2)
tmp = p + '.tmp'
open(tmp, 'w').write(t2)
os.replace(tmp, p)
print("MODIFIED %d" % count)
PY
)
    rc=$?
    case "$rc" in
    0) echo "  ✅ initrd 行已检查（新拼接 ${out#MODIFIED } 行）" ;;
    2) echo "  ⚠️ $GRUB_CFG 里没有 initrd 行（格式可能变了），未修改" ;;
    *) echo "  ❌ initrd 补丁失败: $out" ;;
    esac
    [ "$rc" = "0" ] || return 1
    return 0
}

# ---------- 关机/重启钩子 ----------
hook_expected_md5() {
    printf '%s\n' "$HOOK_SCRIPT" | md5sum | awk '{print $1}'
}

install_hook() {
    local tmp md5
    echo "  安装关机/重启钩子..."
    tmp="/tmp/zz-s5-poweroff.$$"
    printf '%s\n' "$HOOK_SCRIPT" >"$tmp"
    if ! sh -n "$tmp" 2>/dev/null; then
        echo "  ❌ 钩子脚本语法错误，已放弃安装（未改动现有文件）"
        rm -f "$tmp"
        return 1
    fi
    mkdir -p "$(dirname "$HOOK_FILE")"
    if ! cp -f "$tmp" "$HOOK_FILE"; then
        echo "  ❌ 写入 $HOOK_FILE 失败"
        rm -f "$tmp"
        return 1
    fi
    chmod 755 "$HOOK_FILE"
    rm -f "$tmp"
    md5=$(md5sum "$HOOK_FILE" | awk '{print $1}')
    printf '%s\n' "$md5" >"$STATE_MD5"
    echo "  ✅ 钩子已安装: $HOOK_FILE"
    echo "     MD5: $md5"
    return 0
}

# ---------- 状态 ----------
show_status() {
    local md5 exp
    echo ""
    echo "============================================================"
    echo "  修复状态"
    echo "============================================================"
    echo "  工具: $TOOL_NAME $TOOL_VERSION"
    echo "  最后修改: $TOOL_MODIFIED"
    echo "  机型: $(dmi sys_vendor) $(dmi product_name) ($(dmi product_version))"

    if is_infocus; then
        echo "  识别: InFocus KJ-ONE（只修 TF 卡槽只读）"
        local cmdline
        cmdline=$(cat /proc/cmdline)
        if echo "$cmdline" | grep -q "sdhci.debug_quirks=0x10000"; then
            echo "  TF 卡槽只读修复: ✅ sdhci.debug_quirks=0x10000"
        else
            echo "  TF 卡槽只读修复: ❌ 未设置"
        fi
    elif is_kangaroo; then
        echo "  识别: Kangaroo 二代（关机/重启 + 电池 UPS）"
        local cmdline params=""
        cmdline=$(cat /proc/cmdline)
        echo "$cmdline" | grep -q "reboot=kbd" && params="$params reboot=kbd"
        echo "$cmdline" | grep -q "reboot=acpi" && params="$params reboot=acpi"
        echo "$cmdline" | grep -q "acpi=force" && params="$params acpi=force"
        echo "  内核参数:${params:- （未设置）}"

        if [ -f "$HOOK_FILE" ]; then
            md5=$(md5sum "$HOOK_FILE" | awk '{print $1}')
            exp=$(hook_expected_md5)
            if [ "$md5" = "$exp" ] || [ "$md5" = "$KNOWN_MD5" ]; then
                echo "  关机/重启钩子: ✅"
            else
                echo "  关机/重启钩子: ⚠️ 版本不一致（$md5），建议重新执行修复"
            fi
        else
            echo "  关机/重启钩子: ❌ 未安装"
        fi

        if [ -f "$OVERRIDE_FILE" ] && grep -q "acpi_override" "$GRUB_CFG" 2>/dev/null; then
            echo "  电池 UPS 识别: ✅"
        else
            echo "  电池 UPS 识别: ❌（缺 $OVERRIDE_FILE 或 grub.cfg 少了 acpi_override）"
        fi
    else
        echo "  ⚠️ 未知机型，本工具仅支持 Kangaroo 二代和 InFocus KJ-ONE"
    fi
    echo "============================================================"
}

# ---------- 全自动修复 ----------
auto_fix() {
    echo ""
    echo ">>> 开始全自动修复..."

    if is_infocus; then
        echo "  检测到 InFocus KJ-ONE"
        fix_infocus_cmdline || return 1
    elif is_kangaroo; then
        echo "  检测到 Foxconn Kangaroo 二代"
        fix_kangaroo_cmdline || return 1
    else
        echo "  ❌ 非目标机型，退出"
        return 1
    fi

    if [ "$CMDLINE_CHANGED" = "1" ]; then
        CFG_BAK=$(mkbak "$GRUB_CFG")
        [ -n "$CFG_BAK" ] && echo "  备份: $CFG_BAK"
        if ! run_update_grub; then
            echo "  ❌ update-grub 失败，正在回滚..."
            [ -n "$DEF_BAK" ] && cp -a "$DEF_BAK" "$GRUB_DEFAULTS" && echo "  已恢复 $GRUB_DEFAULTS"
            [ -n "$CFG_BAK" ] && cp -a "$CFG_BAK" "$GRUB_CFG" && echo "  已恢复 $GRUB_CFG"
            return 1
        fi
    else
        echo "  内核参数无变化，跳过 update-grub"
    fi

    if is_kangaroo; then
        if [ -f "$OVERRIDE_FILE" ]; then
            patch_initrd_idempotent || echo "  ⚠️ initrd 补丁未完成，UPS 识别可能受影响"
        else
            echo "  ⚠️ $OVERRIDE_FILE 不存在（需从已修好的机器拷贝），跳过 UPS 部分"
        fi
        install_hook || return 1
    fi

    echo ""
    echo ">>> 修复完成！GRUB 改动需冷启动生效。"
    return 0
}

# ---------- 卸载/回滚 ----------
uninstall() {
    echo ""
    echo ">>> 卸载/回滚..."
    local bak

    if is_kangaroo; then
        if [ -f "$HOOK_FILE" ]; then
            rm -f "$HOOK_FILE"
            echo "  ✅ 已删除关机/重启钩子"
        else
            echo "  钩子本来就不存在"
        fi
        rm -f "$STATE_MD5"

        bak=$(mkbak "$GRUB_DEFAULTS")
        [ -n "$bak" ] && echo "  备份: $bak"
        if ! strip_tokens "GRUB_CMDLINE_LINUX_DEFAULT" 'reboot=*' 'acpi=force'; then
            echo "  内核参数里没有需要移除的项（可能已还原）"
        fi
    elif is_infocus; then
        bak=$(mkbak "$GRUB_DEFAULTS")
        [ -n "$bak" ] && echo "  备份: $bak"
        if ! strip_tokens "GRUB_CMDLINE_LINUX" 'sdhci.debug_quirks=*'; then
            echo "  内核参数里没有需要移除的项（可能已还原）"
        fi
    else
        echo "  ❌ 非目标机型，退出"
        return 1
    fi

    if [ "$CMDLINE_CHANGED" = "1" ]; then
        if ! run_update_grub; then
            echo "  ⚠️ update-grub 失败，请手动检查 $GRUB_DEFAULTS"
            return 1
        fi
    fi

    # 保留 DSDT override：这是电池/UPS 识别用的，删掉会让 UPS 掉
    if [ -f "$OVERRIDE_FILE" ]; then
        patch_initrd_idempotent >/dev/null 2>&1 || true
        echo "  说明: 保留了 $OVERRIDE_FILE 与 grub.cfg 的 initrd 行（电池/UPS 识别需要）"
    fi

    echo ">>> 卸载完成"
    return 0
}

# ---------- 主菜单 ----------
main() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请用 sudo 运行: sudo bash $0"
        exit 1
    fi
    if [ "${1:-}" = "--status" ]; then
        show_status
        exit 0
    fi
    if [ ! -t 0 ]; then
        echo "非交互模式；只读查询请用: sudo bash $0 --status"
        exit 1
    fi

    local sel c
    while true; do
        clear
        echo "============================================================"
        echo "  $TOOL_NAME  $TOOL_VERSION"
        echo "  最后修改: $TOOL_MODIFIED"
        echo "============================================================"
        echo "  Kangaroo 关机/重启卡住、电源灯不灭 + 内置电池 UPS 识别"
        echo "  + InFocus TF 卡槽只读修复"
        echo "============================================================"
        echo "  1 = 查询状态（只读）"
        echo "  2 = 全自动修复"
        echo "  3 = 卸载/回滚"
        echo "  0 = 退出"
        echo ""
        read -r -p "选择: " sel || exit 0
        case "$sel" in
        1) show_status; read -r -p "按回车继续..." _ || true ;;
        2) auto_fix; read -r -p "按回车继续..." _ || true ;;
        3)
            read -r -p "确认卸载? (y/n): " c || exit 0
            [ "$c" = "y" ] && uninstall
            read -r -p "按回车继续..." _ || true
            ;;
        0) echo "再见!"; break ;;
        *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    main "$@"
fi
