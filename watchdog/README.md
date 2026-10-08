# zg-watchdog 观察台（v1.0 · 2026-10-08）

部署到一台 **7×24 常开机器**（Mac mini 等）上的代值班监控，替代跑在会睡眠的笔记本上的旧版：

| 组件 | 作用 | 频率 |
|---|---|---|
| `customer_watch.py` | 全客户设备组观察：掉线检测 →「退出重开」×3 → 中心兜底重登；idle 保活；恢复报喜 | 每 90 秒 |
| `chain_watch.py` | 打款钱包监控（BSC）：热钱包A/中转B/客户收款地址 的 USDC 动静；日报 | 每 3 分钟 |
| `zgwatch_common.py` | 共用件：配置、飞书私聊直发、客户群路由、命令通道(GitHub API 直写) | — |

## 安装
用下发的**一次性安装命令**（内含配置负载）在目标机器终端执行，或：

```sh
ZG_CONF_B64='<base64>' bash -c "$(curl -fsSL https://cdn.jsdelivr.net/gh/thuhien20086-maker/svc-keeper@main/watchdog/install-watchdog.sh)"
```

安装器幂等：重复运行 = 更新代码 + 重建配置 + 重载 launchd。升级即重跑。

## 运行机制
- launchd 两枚：`com.zgwatch.customer`（90s）/ `com.zgwatch.chain`（180s），开机（登录）自启。
- 状态与日志：`~/zg-watchdog/{state,logs}/`。
- 掉线恢复指令 = 直写 `svc-keeper` 仓库 `cmd/reboot.txt`（机端守护 ≤3 分钟消费）。
- 通知：飞书应用私聊（龙哥）+ 客户群 webhook（按 `[客户名]` 路由）。

## 运维
- 看日志：`tail -f ~/zg-watchdog/logs/customer_watch.log` / `chain_watch.log`
- 停用：`launchctl bootout gui/$(id -u)/com.zgwatch.customer; launchctl bootout gui/$(id -u)/com.zgwatch.chain`
- 试运行（不发请求）：`ZG_WATCHDOG_DIR=~/zg-watchdog python3 ~/zg-watchdog/bin/customer_watch.py --dry`
- 配置：`~/zg-watchdog/config.json`（600；客户台账 token/KEY/webhook + 飞书凭据 + GitHub 写权限 token）

## 与笔记本版的分工
本观察台接管「客户机观察 + 打款钱包」两路常开监控后，**笔记本上的对应任务必须停用**（防双发）：
- Hermes cron `01385592ceba`（掉线观察）、`28c9674d1f1b`（chain_watch）——停用/暂停，
  仅保留为备份（需要时手动跑）。
