#!/usr/bin/env bash
# 实际网络测试只在临时 network namespace 中操作 nft，不触碰宿主防火墙。
set -euo pipefail
[[ $(uname -s) == Linux && $EUID == 0 ]] || { echo '需要 Linux root'; exit 1; }
for tool in ip nft python3; do command -v "$tool" >/dev/null; done
project=$(cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$project/.test-work"
work=$(mktemp -d "$project/.test-work/network.XXXXXX")
client=nftables-$$-c router=nftables-$$-r target=nftables-$$-t server_pid=''
cleanup() {
    if [[ -n $server_pid ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
    for namespace in "$client" "$router" "$target"; do ip netns del "$namespace" 2>/dev/null || true; done
    rm -rf -- "$work"
}
trap cleanup EXIT
for namespace in "$client" "$router" "$target"; do ip netns add "$namespace"; ip -n "$namespace" link set lo up; done
ip -n "$client" link add c0 type veth peer name r0 netns "$router"
ip -n "$router" link add r1 type veth peer name t0 netns "$target"
ip -n "$client" address add 10.200.1.2/24 dev c0
ip -n "$router" address add 10.200.1.1/24 dev r0
ip -n "$router" address add 10.200.2.1/24 dev r1
ip -n "$target" address add 10.200.2.2/24 dev t0
ip -n "$client" link set c0 up
ip -n "$router" link set r0 up
ip -n "$router" link set r1 up
ip -n "$target" link set t0 up
ip -n "$client" route add default via 10.200.1.1
ip -n "$target" route add default via 10.200.2.1
ip netns exec "$router" nft add table inet nftables_test
cat >"$work/server.py" <<'PY'
from pathlib import Path
import socket, sys, threading, time

def serve(port, kind):
    server = socket.socket(socket.AF_INET, kind)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('10.200.2.2', port))
    if kind == socket.SOCK_STREAM:
        server.listen()
        while True:
            conn, peer = server.accept()
            conn.sendall(f'{port} {peer[0]}'.encode())
            conn.close()
    else:
        while True:
            _, peer = server.recvfrom(100)
            server.sendto(f'{port} {peer[0]}'.encode(), peer)

for port in (8080, 8081):
    for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
        threading.Thread(target=serve, args=(port, kind), daemon=True).start()
time.sleep(0.2)
Path(sys.argv[1]).touch()
while True: time.sleep(1)
PY
ip netns exec "$target" python3 "$work/server.py" "$work/ready" &
server_pid=$!
for ((attempt=0; attempt<50; attempt++)); do [[ ! -f $work/ready ]] || break; sleep 0.1; done
[[ -f $work/ready ]]
cat >"$work/client.py" <<'PY'
import socket, sys
for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
    client = socket.socket(socket.AF_INET, kind)
    client.settimeout(1)
    try:
        client.connect(('10.200.1.1', 18080))
        if kind == socket.SOCK_DGRAM: client.send(b'test')
        response = client.recv(100).decode()
    except OSError:
        assert sys.argv[1] == 'stopped', '转发未生效'
    else:
        assert sys.argv[1] != 'stopped', '停止后新连接仍被转发'
        assert response == sys.argv[1] + ' 10.200.2.1', response
    finally:
        client.close()
PY
cat >"$work/nftables.json" <<'JSON'
{"version":1,"rules":[{"listen_port":18080,"host":"10.200.2.2","target_port":8080,"protocol":"tcp+udp","name":"network test"}]}
JSON
apply() {
    # 参数由子 shell 展开。
    # shellcheck disable=SC2016
    ip netns exec "$router" bash -c '
        source "$1/nftables.sh"
        DIR=$2 CONF=$2/nftables.json RULES=$2/nftables.nft LOCK=$2/nftables.lock
        config_tool render "$CONF" >"$RULES" && load_rules
    ' test "$project" "$work"
}
apply
ip netns exec "$client" python3 "$work/client.py" 8080
# shellcheck disable=SC2016
ip netns exec "$router" bash -c '
    source "$1/nftables.sh"; DIR=$2 LOCK=$2/nftables.lock; remove_rules
' test "$project" "$work"
ip netns exec "$client" python3 "$work/client.py" stopped
python3 - "$work/nftables.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as file: data = json.load(file)
data['rules'][0]['target_port'] = 8081
with open(path, 'w') as file: json.dump(data, file)
PY
apply
ip netns exec "$client" python3 "$work/client.py" 8081
ip netns exec "$router" nft list table inet nftables_test >/dev/null
echo 'TCP/UDP 转发、masquerade、停止、重载和无关表保留验证通过'
