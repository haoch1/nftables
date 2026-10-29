# nftables

Linux nftables 端口转发管理脚本，提供规则管理、转发启停、脚本更新和卸载功能。

管理脚本版本：`1.0.10`

## 功能

- TCP、UDP 和 TCP+UDP 转发，支持目标 IP 或域名
- 转发规则的添加、查看、修改、删除和清空
- systemd 服务管理及开机自启
- 配置校验、备份和失败恢复

## 安装

适用于采用 systemd 的 Linux 系统，使用 `root` 执行：

```sh
(curl -LfsS https://raw.githubusercontent.com/haoch1/nftables/main/nftables.sh -o /usr/local/bin/n || wget -q https://raw.githubusercontent.com/haoch1/nftables/main/nftables.sh -O /usr/local/bin/n) && chmod +x /usr/local/bin/n && n
```

管理命令为 `n`。缺少的依赖由系统包管理器按需安装。

## 管理菜单

| 编号 | 操作 |
| --- | --- |
| 1 | 添加转发规则 |
| 2 | 查看转发规则 |
| 3 | 修改转发规则 |
| 4 | 删除转发规则 |
| 5 | 清空所有转发规则 |
| 6 | 启动转发 |
| 7 | 停止转发 |
| 8 | 重启转发 |
| 9 | 更新管理脚本 |
| 10 | 一键卸载 |
| 0 | 退出脚本 |

交互输入支持 `q` / `Q` 取消，修改时回车保留原值，清空和卸载确认支持 `Y` / `N`。

## 命令行

```sh
n                    # 打开管理菜单
n --start            # 启动转发
n --stop             # 停止转发，保留配置
n --reload           # 重载转发，重新解析目标域名
n --update-script    # 更新管理脚本
n --uninstall        # 卸载脚本及托管规则
n --version          # 显示管理脚本版本
```

## 卸载

卸载清理本脚本创建的规则、旧转发连接、配置、备份、服务文件、运行锁和管理命令。系统内核、共享依赖、其他防火墙规则及未识别文件保留。
