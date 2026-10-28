# nftables

一个简单的 Linux 内核端口转发管理脚本，交互风格参考 [realm](https://github.com/haoch1/realm)。单文件实现，没有常驻转发进程。

管理脚本版本：`1.0.0`。适用于使用 systemd 的 Debian、Ubuntu、RHEL 系 Linux，需 root 权限及内核 nf_tables/NAT 支持。

## 安装

使用 `root` 执行：

```sh
(curl -LfsS https://raw.githubusercontent.com/haoch1/nftables/main/nftables.sh -o /usr/local/bin/nftables || wget -q https://raw.githubusercontent.com/haoch1/nftables/main/nftables.sh -O /usr/local/bin/nftables) && chmod +x /usr/local/bin/nftables && nftables
```

也可以将 `nftables.sh` 复制到服务器后运行：

```sh
sudo bash nftables.sh
```

首次添加规则或启动转发时，自动补装缺失的 `nft` 等工具，并安装 `/usr/local/bin/nftables` 管理命令。以后直接运行：

```sh
sudo nftables
```

支持 IPv4 的 TCP、UDP、TCP+UDP 转发，目标可以填写 IPv4 或域名。域名在添加、修改、启动和重载时解析为一个 IPv4 地址；内核规则使用解析后的地址。开机加载上次保存的地址，不依赖启动时 DNS 可用。域名地址变化后执行重载。当前不提供 IPv6 或 IPv4/IPv6 互转。

## 菜单

```text
基础功能
[1]  添加转发规则
[2]  查看转发规则
[3]  修改转发规则
[4]  删除转发规则
[5]  清空所有转发规则

转发管理
[6]  启动转发
[7]  停止转发
[8]  重载转发

更新与卸载
[9]  更新管理脚本
[10] 一键卸载

[0]  退出脚本
```

输入 `q/Q` 取消，修改规则时回车保留原值，删除、清空和卸载使用 `(Y/N)` 确认。添加、修改和删除成功后立即应用并启用开机加载。

“停止转发”只移除本脚本的内核表，保存的配置仍保留。“启动转发”重新加载；“重载转发”重新解析域名并原子替换规则。停止不会禁用开机加载，也不会清理共享 conntrack，因此已有连接可能继续到记录过期。

## 命令行

```sh
nftables                  # 打开管理菜单
nftables --start          # 启动转发并设置开机加载
nftables --stop           # 停止转发，保留配置
nftables --reload         # 重新解析域名并加载规则
nftables --update-script  # 更新管理脚本
nftables --uninstall      # 确认后卸载本项目
nftables --version        # 查看管理脚本版本
```

没有“安装/更新 nftables”菜单；缺少的工具按需安装，系统工具的后续升级由系统包管理器负责。

管理脚本从本仓库的 `main/nftables.sh` 更新。下载失败会保留当前脚本，更新后下次运行 `nftables` 时加载。

## 文件与规则

| 名称或路径 | 用途 |
| --- | --- |
| `/usr/local/bin/nftables` | 管理脚本 |
| `/root/nftables/nftables.json` | 规则配置 |
| `/root/nftables/nftables.json.bak` | 上次成功应用前的配置 |
| `/root/nftables/nftables.nft` | 开机加载的内核规则 |
| `/etc/systemd/system/nftables.service` | 本脚本创建的 oneshot 服务 |
| `ip nftables` | 本脚本拥有的 nft 表 |
| `/run/lock/nftables.lock`、`.lock.menu` | 应用锁和管理窗口锁 |

服务只在启动、停止或重载时运行命令，没有常驻转发进程。`nft` 是系统命令名，Linux 内核模块仍使用系统原名 `nf_tables`。

脚本只管理带归属标记的 `ip nftables` 表，不执行 `flush ruleset`，不写 `/etc/nftables.conf`。遇到已启用的系统 nftables 服务、其他同名服务、额外服务配置或无归属标记的同名表时拒绝接管。

流量路径是 DNAT → 内核路由 → masquerade；目标看到的来源地址是转发服务器。仅匹配发往本机 IPv4 地址的入站流量，不接管本机主动发起的连接。脚本会检查本机端口占用，但已有防火墙、安全组仍需允许相应转发流量；不会为了放行而更改其他规则。若目标是本机其他端口，请使用专门的本机重定向方案。

NAT 型 VPS 可以使用，但宿主机必须允许 nftables 和 IP 转发。填写“本机监听端口”时使用公网映射后的内部端口：例如商家将公网 `30000` 映射到 VPS 内部 `10000`，脚本填写 `10000`，访问者连接公网 `30000`。脚本不负责创建商家侧的公网映射，也不自动推断内外端口对应关系；该场景尚未实机验证。

启用转发时设置共享参数 `net.ipv4.ip_forward=1`；停止和卸载保留该参数，避免影响 Docker、VPN 等其他使用者。修改规则前进行 `nft -c` 检查，应用使用 nft 原子批处理；失败会尝试恢复此前配置及内核表，并报告恢复失败。

## 卸载

卸载只清理本脚本创建的转发表、配置、备份、服务文件和管理命令。保留 Linux 内核、内核模块、系统 `nft` 工具、Python 等共享依赖、其他防火墙表、共享转发参数及未识别文件。运行目录中的两个小锁文件保留至系统清理 `/run`，防止删除仍持有的锁导致并发绕过。

## 验证

```sh
bash -n nftables.sh
shellcheck nftables.sh
python3 -m unittest discover -s tests -v
sudo bash tests/network.sh
```

单元测试使用临时目录和替身命令，不修改系统防火墙。网络测试需要 Linux root、`iproute2`、`nftables`、Python 3 及 network namespace 权限，在隔离网络命名空间内验证 TCP/UDP 实际转发、停止、重载和无关表保留。
