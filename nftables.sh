#!/bin/sh
# nftables 管理脚本
# shellcheck shell=bash
# nftables.sh managed script

# 可以用 sh 启动；管理逻辑使用 Bash。
if [ -z "${BASH_VERSION:-}" ]; then
    command -v bash >/dev/null 2>&1 || { printf '请先安装 bash，再运行此脚本\n' >&2; exit 1; }
    exec bash "$0" "$@"
fi

SCRIPT_VERSION=1.0.2
DIR=/root/nftables
CONF=$DIR/nftables.json
RULES=$DIR/nftables.nft
RT=/usr/local/bin/n
UNIT=/etc/systemd/system/nftables.service
LOCK=/run/lock/nftables.lock
SCRIPT_URL=https://raw.githubusercontent.com/haoch1/nftables/main/nftables.sh
MARKER='nftables.sh managed'
BLUE=$'\033[1;36m' GREEN=$'\033[0;32m' RED=$'\033[0;31m' YELLOW=$'\033[0;33m' NC=$'\033[0m'
MENU_CANCELLED=0 INPUT_EOF=0 MENU_IDLE=0

info() { printf '  %s[信息] %s%s\n' "$BLUE" "$*" "$NC"; }
success() { printf '  %s[成功] %s%s\n' "$GREEN" "$*" "$NC"; }
warn() { printf '  %s[注意] %s%s\n' "$YELLOW" "$*" "$NC"; }
fail() { printf '  %s[错误] %s%s\n' "$RED" "$*" "$NC" >&2; return 1; }
read_input() {
    local reply
    read -r -p "  $2" reply || { INPUT_EOF=1; return 1; }
    [[ $reply != [qQ] ]] || { MENU_CANCELLED=1; return 1; }
    printf -v "$1" '%s' "$reply"
}
pause_enter() { read -r -p '  按回车返回主菜单...' _ || INPUT_EOF=1; }
confirm() {
    local answer
    read_input answer '(Y/N): ' || return 1
    [[ $answer == [yY] ]] || { MENU_CANCELLED=1; return 1; }
}

# 只用标准库处理 JSON、地址校验和规则生成，无额外 Python 包。
config_tool() {
    python3 - "$@" <<'PY'
import ipaddress, json, re, signal, socket, sys

def port(value):
    if isinstance(value, bool) or not re.fullmatch(r"[0-9]{1,5}", str(value)) or not 1 <= int(value) <= 65535:
        raise ValueError("端口应为 1–65535")
    return int(value)

def host(value):
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        labels = value.rstrip('.').split('.')
        if len(value) > 253 or not all(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label) for label in labels):
            raise ValueError("请输入有效的 IPv4 地址或域名")
        if re.fullmatch(r"[0-9.]+", value):
            raise ValueError("IPv4 地址无效")
        return value.lower()
    if address.version != 4 or address.is_loopback or address.is_unspecified or address.is_multicast or address.is_link_local or str(address) == '255.255.255.255':
        raise ValueError("目前支持远端 IPv4 转发，不接受 IPv6、回环、链路本地或组播地址")
    return str(address)

try:
    action, *args = sys.argv[1:]
    if action == 'owned':
        data = json.loads(args[0])
        assert any(x.get('table', {}).get('comment') == 'nftables.sh managed' for x in data['nftables']), '同名表不属于本脚本'
        sys.exit(0)
    if action == 'input':
        port(args[0]); host(args[1]); port(args[2])
        sys.exit(0)
    with open(args[0], encoding='utf-8') as file:
        config = json.load(file)
    assert isinstance(config, dict) and config.get('version') == 1 and isinstance(config.get('rules'), list), '配置格式不正确'
    rules = config['rules']
    if action == 'save':
        index, listen, address, target, proto, name = args[1:]
        rule = dict(listen_port=port(listen), host=host(address), target_port=port(target), protocol=proto, name=name or '转发规则-' + str(port(listen)))
        if int(index) == -1: rules.append(rule)
        else: rules[int(index)] = rule
    elif action == 'delete':
        if int(args[1]) == -1: rules.clear()
        else: del rules[int(args[1])]
    occupied = set()
    for rule in rules:
        assert isinstance(rule, dict), '配置包含无效规则'
        listen, target = port(rule['listen_port']), port(rule['target_port'])
        host(rule['host'])
        assert rule['protocol'] in ('tcp', 'udp', 'tcp+udp'), '无效协议'
        assert isinstance(rule['name'], str) and 0 < len(rule['name']) <= 60 and not any(ord(c) < 32 or ord(c) == 127 for c in rule['name']), '备注限 60 字，不能包含控制字符'
        for proto in rule['protocol'].split('+'):
            assert (listen, proto) not in occupied, f'{listen}/{proto} 已有转发规则'
            occupied.add((listen, proto))
    if action == 'count': print(len(rules))
    elif action == 'get':
        rule = rules[int(args[1])]
        for key in ('listen_port', 'host', 'target_port', 'protocol', 'name'): print(rule[key])
    elif action == 'list':
        for i, rule in enumerate(rules, 1):
            print(f"  [{i}] 【{rule['name']}】 本机 :{rule['listen_port']} → {rule['host']}:{rule['target_port']}  [{rule['protocol'].upper()}]")
    elif action in ('save', 'delete'): print(json.dumps(config, ensure_ascii=False, indent=2))
    elif action == 'render':
        if hasattr(signal, 'alarm'): signal.alarm(30)
        pre, post = [], []
        for i, rule in enumerate(rules, 1):
            addresses = socket.getaddrinfo(rule['host'], None, socket.AF_INET, socket.SOCK_STREAM)
            address = host(addresses[0][4][0])
            listen, target = port(rule['listen_port']), port(rule['target_port'])
            print(f"  【{rule['name']}】 {rule['host']} → {address}", file=sys.stderr)
            for proto in rule['protocol'].split('+'):
                pre.append(f'    fib daddr type local {proto} dport {listen} counter dnat to {address}:{target} comment "nftables:{i}"')
                post.append(f'    ct status dnat ct original proto-dst {listen} ip daddr {address} {proto} dport {target} counter masquerade')
        print('table ip nftables {\n  comment "nftables.sh managed"\n  chain prerouting {\n    type nat hook prerouting priority dstnat; policy accept;')
        print('\n'.join(pre))
        print('  }\n  chain postrouting {\n    type nat hook postrouting priority srcnat; policy accept;')
        print('\n'.join(post))
        print('  }\n}')
    elif action != 'validate': raise ValueError('未知配置操作')
except (ValueError, KeyError, IndexError, TypeError, AssertionError, OSError) as error:
    print(f'配置错误：{error}', file=sys.stderr)
    sys.exit(1)
PY
}

install_packages() {
    # 只补装缺失的包，不在管理菜单中升级系统 nftables。
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-upgrade "$@"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$@"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$@"
    else
        fail '需要 apt-get、dnf 或 yum；本版适用于 systemd 系统'
    fi
}
ensure_tools() {
    local tool package
    local -a packages=()
    for tool in nft python3 flock ss sysctl; do
        command -v "$tool" >/dev/null 2>&1 && continue
        case $tool in
            nft) package=nftables ;; python3) package=python3 ;; flock) package=util-linux ;;
            ss) package=iproute2; command -v apt-get >/dev/null 2>&1 || package=iproute ;;
            sysctl) package=procps; command -v apt-get >/dev/null 2>&1 || package=procps-ng ;;
        esac
        packages+=("$package")
    done
    ((${#packages[@]} == 0)) || install_packages "${packages[@]}"
}

# 同名系统服务和内核表必须检查归属，不接管正在使用的防火墙。
unit_owned() { [[ -f $UNIT && ! -L $UNIT ]] && grep -qxF "# $MARKER" "$UNIT"; }
check_unit() {
    if [[ -e $UNIT || -L $UNIT ]]; then
        unit_owned || { fail "已有同名服务，未覆盖：$UNIT"; return 1; }
    elif systemctl is-active --quiet nftables || systemctl is-enabled --quiet nftables 2>/dev/null; then
        fail '系统已有启用的 nftables 服务，请先确认其用途；本脚本未接管'
        return 1
    fi
    local dropins
    dropins=$(systemctl show nftables.service -p DropInPaths --value 2>/dev/null) || return 1
    [[ -z $dropins ]] || { fail 'nftables 服务存在额外配置，未接管'; return 1; }
}
table_state() {
    local tables json
    tables=$(nft list tables) || return 2
    grep -qx 'table ip nftables' <<< "$tables" || return 1
    json=$(nft -j list table ip nftables) || return 2
    config_tool owned "$json" || { fail '同名 ip nftables 表不属于本脚本，未修改'; return 2; }
}
kernel_lock() {
    mkdir -p /run/lock || return 1
    exec 8>"$LOCK" || return 1
    flock -w 15 8 || { fail '另一个操作正在应用规则，请稍后重试'; return 1; }
}

# 只接管等待主菜单输入的旧窗口；正在提交配置的窗口不受打断。
acquire_menu_lock() {
    local holder='' state='' command='' attempt
    exec 9>>"$LOCK.menu" || return 1
    if ! flock -n 9; then
        read -r holder state <"$LOCK.menu" || true
        if [[ $holder =~ ^[1-9][0-9]*$ && $state == idle && -r /proc/$holder/cmdline && /proc/$holder/fd/9 -ef $LOCK.menu ]]; then
            command=$(tr '\0' '\n' <"/proc/$holder/cmdline") || return 1
            case $command in
                "bash"$'\n'"$RT" | "/bin/bash"$'\n'"$RT" | "/usr/bin/bash"$'\n'"$RT")
                    info '检测到旧的空闲管理界面，正在自动接管...'
                    kill -TERM "$holder" 2>/dev/null || return 1
                    ;;
                *) fail '管理锁被其他进程占用，未结束任何进程'; return 1 ;;
            esac
        else
            fail "另一个 nftables 管理窗口正在执行操作${holder:+（PID: $holder）}，请稍后重试"
            return 1
        fi
        for ((attempt=0; attempt<30; attempt++)); do
            flock -n 9 && break
            sleep 0.1
        done
        flock -n 9 || { fail '旧窗口尚未释放管理锁，请稍后重试'; return 1; }
    fi
    printf '%s busy\n' "$$" >"$LOCK.menu" || return 1
    # 即使状态检查后用户开始操作，也不因接管信号中断写入。
    trap 'if [[ ${MENU_IDLE:-0} == 1 ]]; then exit 0; fi' TERM HUP
}

nft_version() {
    local output
    if ! command -v nft >/dev/null 2>&1; then printf '未安装'; return; fi
    output=$(nft --version 2>/dev/null) || { printf '未知'; return; }
    if [[ $output =~ ^nftables[[:space:]]+v?([0-9]+(\.[0-9]+)+) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '未知'
    fi
}
load_rules() (
    # 服务调用另持一把短锁；不与菜单的管理锁互相等待。
    kernel_lock || exit 1
    local source=${1:-$RULES} state batch previous=''
    table_state; state=$?
    ((state < 2)) || exit 1
    batch=$(mktemp "$DIR/.nftables.XXXXXX") || exit 1
    trap 'rm -f -- "$batch"' EXIT
    ((state == 0)) && printf 'delete table ip nftables\n' >"$batch"
    cat "$source" >>"$batch" || exit 1
    nft -c -f "$batch" || exit 1
    if [[ $(config_tool count "$CONF") != 0 ]]; then
        previous=$(sysctl -n net.ipv4.ip_forward) || exit 1
        sysctl -q -w net.ipv4.ip_forward=1 || exit 1
    fi
    if ! nft -f "$batch"; then
        [[ -z $previous || $previous == 1 ]] || sysctl -q -w "net.ipv4.ip_forward=$previous"
        exit 1
    fi
)
remove_rules() (
    kernel_lock || exit 1
    local state
    table_state; state=$?
    case $state in
        0) nft delete table ip nftables ;;
        1) return 0 ;;
        *) return 1 ;;
    esac
)

prepare_service() {
    check_unit || return 1
    [[ ! -L $RT && (! -e $RT || -f $RT) ]] || { fail "$RT 不是普通管理脚本"; return 1; }
    if [[ -e $RT ]] && ! grep -qxF '# nftables.sh managed script' "$RT"; then
        fail "已有同名命令，未覆盖：$RT"; return 1
    fi
    local self
    self=$(readlink -f -- "${BASH_SOURCE[0]}") || return 1
    [[ $self == "$RT" ]] || install -m 755 -- "$self" "$RT" || return 1
    if ! unit_owned || ! grep -qxF "ExecStart=$RT --service-start" "$UNIT"; then
        cat >"$UNIT" <<EOF
# $MARKER
[Unit]
Description=nftables port forwarding
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$RT --service-start
ExecReload=$RT --service-start
ExecStop=$RT --service-stop
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload || return 1
    fi
}
check_ports() {
    local port protocol sockets
    while read -r port protocol; do
        if [[ $protocol == tcp ]]; then sockets=$(ss -H -ltn "sport = :$port") || return 1
        else sockets=$(ss -H -lun "sport = :$port") || return 1; fi
        [[ -z $sockets ]] || { fail "$port/${protocol^^} 已被本机程序占用，未应用规则"; return 1; }
    done < <(python3 -c 'import json,sys; [(print(r["listen_port"],p)) for r in json.load(open(sys.argv[1]))["rules"] for p in r["protocol"].split("+")]' "$1")
}

# 先生成和检查，再保存；应用失败恢复上次配置，nft 批处理本身是原子的。
apply_config() (
    local candidate=$1 temp active=0 status=0 writing=0
    config_tool validate "$candidate" && check_ports "$candidate" && prepare_service || exit 1
    temp=$(mktemp -d "$DIR/.nftables.XXXXXX") || exit 1
    # EXIT trap 调用此函数。
    # shellcheck disable=SC2329
    cleanup_apply() {
        local failed=0
        if ((writing)); then
            cp -p "$temp/nftables.json" "$CONF" || failed=1
            if [[ -f $temp/previous.nft ]]; then cp -p "$temp/previous.nft" "$RULES" || failed=1; else rm -f -- "$RULES" || failed=1; fi
            if [[ -f $temp/previous-table.nft ]]; then
                load_rules "$temp/previous-table.nft" || failed=1
            else
                ((active)) || systemctl stop nftables || true
                remove_rules || failed=1
            fi
        fi
        if ((failed)); then warn "恢复未完成，恢复文件已保留在 $temp"; else rm -rf -- "$temp"; fi
    }
    trap 'cleanup_apply' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    config_tool render "$candidate" >"$temp/nftables.nft" || exit 1
    local state
    table_state; state=$?
    ((state < 2)) || exit 1
    if ((state == 0)); then nft list table ip nftables >"$temp/previous-table.nft" || exit 1; fi
    ((state != 0)) || printf 'delete table ip nftables\n' >"$temp/check.nft"
    cat "$temp/nftables.nft" >>"$temp/check.nft" || exit 1
    nft -c -f "$temp/check.nft" || exit 1
    systemctl is-active --quiet nftables && active=1
    cp -p "$CONF" "$temp/nftables.json" || exit 1
    [[ ! -f $RULES ]] || cp -p "$RULES" "$temp/previous.nft" || exit 1
    writing=1
    if [[ ! $candidate -ef $CONF ]]; then install -m 600 "$candidate" "$CONF" || status=1; fi
    if ((status == 0)); then install -m 600 "$temp/nftables.nft" "$RULES" || status=1; fi
    if ((status == 0)); then
        if ((active)); then systemctl reload nftables || status=1
        else systemctl start nftables || status=1; fi
    fi
    if ((status)); then
        fail '应用失败，正在恢复原配置与内核规则；请查看 journalctl -u nftables'
        exit 1
    fi
    writing=0
    cp -p "$temp/nftables.json" "$CONF.bak" || warn '无法保存上次配置备份'
    systemctl enable nftables >/dev/null || warn '规则已生效，但开机自启设置失败'
    success '转发规则已保存并生效'
)
start_forwarding() {
    check_unit && ensure_tools || return 1
    apply_config "$CONF"
}
stop_forwarding() {
    check_unit || return 1
    if unit_owned; then systemctl stop nftables || return 1; fi
    command -v nft >/dev/null 2>&1 && remove_rules || return 1
    success '转发已停止，保存的规则仍保留；已有连接可能继续到过期'
}

view_rules() { printf '\n'; info '=== 当前端口转发规则 ==='; config_tool list "$CONF"; }
choose_rule() {
    local selection count
    count=$(config_tool count "$CONF") || return 1
    ((count)) || { warn '暂无转发规则'; return 1; }
    view_rules
    read_input selection "请输入要$2的序号 (0 取消): " || return 1
    [[ -n $selection && $selection != 0 ]] || { MENU_CANCELLED=1; return 1; }
    if [[ ! $selection =~ ^[0-9]{1,5}$ ]] || ((10#$selection < 1 || 10#$selection > count)); then fail '无效选择'; return 1; fi
    printf -v "$1" '%d' "$((10#$selection - 1))"
}
edit_rule() {
    local index=${1:--1} port='' host='' target='' protocol=tcp name='' value temp
    local -a old
    if ((index >= 0)); then
        mapfile -t old < <(config_tool get "$CONF" "$index")
        port=${old[0]} host=${old[1]} target=${old[2]} protocol=${old[3]} name=${old[4]}
    fi
    printf '\n'; info '=== 编辑端口转发规则（q 取消）==='; printf '\n'
    read_input value "本机监听端口${port:+ (回车保持 $port)}: " || return 1; port=${value:-$port}
    read_input value "目标 IPv4 或域名${host:+ (回车保持 $host)}: " || return 1; host=${value:-$host}
    read_input value "目标端口${target:+ (回车保持 $target)}: " || return 1; target=${value:-$target}
    config_tool input "$port" "$host" "$target" || return 1
    printf '\n  [1] 仅 TCP   [2] 仅 UDP   [3] TCP+UDP\n'
    read_input value "请选择协议 (回车保持 ${protocol^^}): " || return 1
    case $value in ''|0) ;; 1) protocol=tcp ;; 2) protocol=udp ;; 3) protocol=tcp+udp ;; *) fail '无效协议'; return 1 ;; esac
    read_input value "备注名称 (回车${name:+保持 }${name:-默认 转发规则-$port}): " || return 1; name=${value:-$name}
    check_unit && ensure_tools || return 1
    temp=$(mktemp "$DIR/.nftables.XXXXXX") || return 1
    config_tool save "$CONF" "$index" "$port" "$host" "$target" "$protocol" "$name" >"$temp" && apply_config "$temp"
    local status=$?
    rm -f -- "$temp"
    return "$status"
}
delete_rule() {
    local index=$1 temp status
    [[ $(config_tool count "$CONF") != 0 ]] || { warn '暂无转发规则'; return 0; }
    if ((index == -1)); then warn '确认清空全部转发规则？'; else warn "确认删除第 $((index + 1)) 条转发规则？"; fi
    confirm || return 1
    temp=$(mktemp "$DIR/.nftables.XXXXXX") || return 1
    config_tool delete "$CONF" "$index" >"$temp" && check_unit && ensure_tools && apply_config "$temp"
    status=$?
    rm -f -- "$temp"
    return "$status"
}

update_script() (
    local temp staged=''
    command -v curl >/dev/null 2>&1 || install_packages curl ca-certificates || exit 1
    temp=$(mktemp "$DIR/.nftables.XXXXXX") || exit 1
    trap 'rm -f -- "$temp"; [[ -z $staged ]] || rm -f -- "$staged"' EXIT
    curl -fLsS --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 60 "$SCRIPT_URL" -o "$temp" || exit 1
    if ! grep -qxF '# nftables.sh managed script' "$temp" || ! bash -n "$temp"; then fail '下载内容无效，原脚本已保留'; exit 1; fi
    [[ ! -e $RT ]] || grep -qxF '# nftables.sh managed script' "$RT" || exit 1
    [[ ! -L $RT ]] || exit 1
    staged=$(mktemp "${RT%/*}/.nftables.XXXXXX") || exit 1
    install -m 755 "$temp" "$staged" && mv -f -- "$staged" "$RT" || exit 1
    success '管理脚本已更新，下次运行 n 时加载'
)
uninstall() {
    warn '卸载仅删除本脚本的转发表、配置、服务和管理命令。'
    warn '保留 Linux 内核、系统 nft 工具、其他防火墙规则及共享转发参数。'
    confirm || return 1
    check_unit || return 1
    if unit_owned; then
        systemctl stop nftables && systemctl disable nftables || return 1
    fi
    if command -v nft >/dev/null 2>&1; then remove_rules || return 1; fi
    if unit_owned; then rm -f -- "$UNIT" && systemctl daemon-reload || return 1; fi
    rm -f -- "$CONF" "$CONF.bak" "$RULES" || return 1
    if [[ -f $RT && ! -L $RT ]] && grep -qxF '# nftables.sh managed script' "$RT"; then rm -f -- "$RT" || return 1; fi
    rmdir -- "$DIR" 2>/dev/null || warn "$DIR 内的未识别文件已保留"
    # 锁文件保留：删除已锁定的 inode 会允许另一个进程绕过互斥。
    success '已卸载本脚本，系统内核和 nft 工具已保留'
}

menu() {
    local choice index state version count header_pad core_width core_pad script_pad status
    while true; do
        MENU_CANCELLED=0 INPUT_EOF=0
        [[ ! -t 1 ]] || printf '\033[3J\033[2J\033[H'
        count=$(config_tool count "$CONF") || return 1
        state=已停止
        if ! command -v nft >/dev/null 2>&1; then state=未安装
        elif ((count > 0)) && table_state >/dev/null 2>&1; then state=运行中; fi
        version=$(nft_version)
        header_pad=$((6 - ${#count})); ((header_pad > 0)) || header_pad=1
        case $version in 未安装) core_width=6 ;; 未知) core_width=4 ;; *) core_width=${#version} ;; esac
        core_pad=$((20 - core_width)); ((core_pad > 0)) || core_pad=1
        script_pad=$((25 - ${#SCRIPT_VERSION})); ((script_pad > 0)) || script_pad=1
        printf '\n%s  ╔═══════════════════════════════════════╗\n' "$BLUE"
        printf '  ║    端口转发管理（当前规则：%s%s%s 条）%*s║\n' "$GREEN" "$count" "$BLUE" "$header_pad" ''
        printf '  ║    nftables 状态：%s%s%s%14s║\n' "$GREEN" "$state" "$BLUE" ''
        printf '  ║    nftables 版本：%s%s%s%*s║\n' "$GREEN" "$version" "$BLUE" "$core_pad" ''
        printf '  ║    管理脚本：%s%s%s%*s║\n' "$GREEN" "$SCRIPT_VERSION" "$BLUE" "$script_pad" ''
        printf '  ╠═══════════════════════════════════════╣\n'
        printf '  ║  基础功能%29s║\n' ''
        printf '  ║  %s[1]%s  添加转发规则%20s║\n' "$GREEN" "$BLUE" ''
        printf '  ║  %s[2]%s  查看转发规则%20s║\n' "$GREEN" "$BLUE" ''
        printf '  ║  %s[3]%s  修改转发规则%20s║\n' "$GREEN" "$BLUE" ''
        printf '  ║  %s[4]%s  删除转发规则%20s║\n' "$GREEN" "$BLUE" ''
        printf '  ║  %s[5]%s  清空所有转发规则%16s║\n' "$GREEN" "$BLUE" ''
        printf '  ║%39s║\n' ''
        printf '  ║  服务管理%29s║\n' ''
        printf '  ║  %s[6]%s  启动转发%24s║\n' "$GREEN" "$BLUE" ''
        printf '  ║  %s[7]%s  停止转发%24s║\n' "$GREEN" "$BLUE" ''
        printf '  ║  %s[8]%s  重启转发%24s║\n' "$GREEN" "$BLUE" ''
        printf '  ║%39s║\n' ''
        printf '  ║  更新与卸载%27s║\n' ''
        printf '  ║  %s[9]%s  更新管理脚本%20s║\n' "$GREEN" "$BLUE" ''
        printf '  ║  %s[10]%s 一键卸载%24s║\n' "$GREEN" "$BLUE" ''
        printf '  ║%39s║\n' ''
        printf '  ║  %s[0]%s  退出脚本%24s║\n' "$GREEN" "$BLUE" ''
        printf '  ╚═══════════════════════════════════════╝%s\n\n' "$NC"
        MENU_IDLE=1
        printf '%s idle\n' "$$" >"$LOCK.menu" || return 1
        read_input choice '请输入选项 [0-10]: '; status=$?
        MENU_IDLE=0
        printf '%s busy\n' "$$" >"$LOCK.menu" || return 1
        if ((status)); then ((INPUT_EOF)) && return 0; continue; fi
        case $choice in
            1) edit_rule || true ;;
            2) view_rules || true ;;
            3) choose_rule index 修改 && edit_rule "$index" || true ;;
            4) choose_rule index 删除 && delete_rule "$index" || true ;;
            5) delete_rule -1 || true ;;
            6|8) start_forwarding || true ;;
            7) stop_forwarding || true ;;
            9) update_script || true ;;
            10) uninstall && return 0 ;;
            0) return 0 ;;
            *) fail '无效选项' ;;
        esac
        ((MENU_CANCELLED || INPUT_EOF)) || pause_enter
        ((INPUT_EOF)) && return 0
    done
}
main() {
    case ${1:-} in
        --version|-v) printf 'nftables 管理脚本 v%s\n' "$SCRIPT_VERSION"; return 0 ;;
        --help|-h) printf '用法：n [--start|--stop|--reload|--update-script|--uninstall|--version]\n无参数打开菜单；q/Q 取消输入。\n'; return 0 ;;
        ''|--start|--stop|--reload|--update-script|--uninstall|--service-start|--service-stop) ;;
        *) fail '未知参数，请使用 --help'; return 1 ;;
    esac
    [[ $(uname -s) == Linux && $EUID == 0 ]] || { fail '请在 Linux 上以 root 或 sudo 运行'; return 1; }
    command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] || { fail '本版需要 systemd'; return 1; }
    umask 077
    trap 'exit 130' INT
    if ! command -v python3 >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
        if [[ ${1:-} == --uninstall || ${1:-} == --service-* || ${1:-} == --stop ]]; then fail '请先安装 python3 和 flock (util-linux)'; return 1; fi
        install_packages python3 util-linux || return 1
    fi
    if [[ ${1:-} == --service-start ]]; then load_rules; return $?; fi
    if [[ ${1:-} == --service-stop ]]; then remove_rules; return $?; fi
    [[ ! -L $DIR && ! -L $CONF && ! -L $RULES ]] || { fail '管理目录或配置是符号链接，未修改'; return 1; }
    mkdir -p "$DIR" /run/lock || return 1
    acquire_menu_lock || return 1
    if [[ ! -e $CONF ]]; then printf '{"version":1,"rules":[]}\n' >"$CONF" || return 1; fi
    config_tool validate "$CONF" || return 1
    case ${1:-} in
        --start|--reload) start_forwarding ;;
        --stop) stop_forwarding ;;
        --update-script) update_script ;;
        --uninstall) uninstall ;;
        '') menu ;;
    esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -uo pipefail
    main "$@"
fi
