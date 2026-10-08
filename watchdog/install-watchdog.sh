#!/bin/bash
# install-watchdog.sh —— 观察台安装器 v1.0（2026-10-08）
# 用途：把「客户机掉线观察 + 打款钱包监控」部署到常开机器（7×24 代值班）。
# 运行环境：macOS（bash 3.2 兼容）。需要 python3 可用。
# 输入：环境变量 ZG_CONF_B64 = base64(config.json)，含客户台账/飞书凭据/GitHub 凭据。
# 可选：ZG_WATCHDOG_DIR（默认 ~/zg-watchdog）；ZG_INSTALL_DRY=1（本地测试：不装 launchd、不试跑、不发消息）
set -u

VERSION="1.0"
DIR="${ZG_WATCHDOG_DIR:-$HOME/zg-watchdog}"
BASES="https://cdn.jsdelivr.net/gh/thuhien20086-maker/svc-keeper@main/watchdog https://raw.githubusercontent.com/thuhien20086-maker/svc-keeper/main/watchdog"

say() { printf '%s\n' "$*"; }

say "== 观察台安装器 v$VERSION =="
say "目录: $DIR"

# 0) python3 检查（存在 ≠ 能用：未装 Command Line Tools 时 /usr/bin/python3 是占位符）
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  say "❌ 未找到 python3。请先运行: xcode-select --install  然后再跑一次本安装。"
  exit 1
fi
if ! "$PY" -c 'import json,sys' >/dev/null 2>&1; then
  say "❌ python3 当前不可用 —— 这台机器还没装命令行开发工具（Command Line Tools）。"
  say "   如果屏幕上有「正在安装软件」窗口：等它装完（约几分钟），再把本命令整行重跑一遍即可。"
  say "   如果没有：先运行  xcode-select --install  装完后再重跑本命令。"
  exit 1
fi
say "python3: $PY ($("$PY" -V 2>&1 | head -1))"

# 1) 解包配置
if [ -z "${ZG_CONF_B64:-}" ]; then
  say "❌ 缺少 ZG_CONF_B64（配置负载）。请用完整的安装命令运行。"
  exit 1
fi
mkdir -p "$DIR/bin" "$DIR/state" "$DIR/logs" || { say "❌ 无法创建 $DIR"; exit 1; }
printf '%s' "$ZG_CONF_B64" | base64 -d > "$DIR/config.json.tmp" 2>/dev/null
if ! "$PY" -c "import json,sys; json.load(open(sys.argv[1],encoding='utf-8'))" "$DIR/config.json.tmp" 2>/dev/null; then
  say "❌ 配置解码/校验失败（ZG_CONF_B64 不完整或损坏）"
  rm -f "$DIR/config.json.tmp"
  exit 1
fi
mv "$DIR/config.json.tmp" "$DIR/config.json"
chmod 600 "$DIR/config.json"
say "✅ 配置已写入（600）"

# 2) 拉取代码（jsDelivr 优先，raw 兜底；先编译再替换，坏了不破坏旧版）
fetch() { # fetch <文件名> <目标路径>
  for b in $BASES; do
    if curl -fsSL --max-time 60 "$b/$1" -o "$2.new" 2>/dev/null; then
      if "$PY" -m py_compile "$2.new" 2>/dev/null; then
        cp -f "$2.new" "$2"; rm -f "$2.new"; return 0
      fi
      say "⚠️ $2 编译未通过（$b），换源重试…"; rm -f "$2.new"
    fi
  done
  return 1
}
cd "$DIR/bin" || exit 1
for f in zgwatch_common.py customer_watch.py chain_watch.py; do
  if fetch "$f" "$DIR/bin/$f"; then
    say "✅ 已就位: $f"
  else
    say "❌ 拉取/校验失败: $f —— 安装中止（旧文件未动）"
    exit 1
  fi
done
"$PY" -m py_compile "$DIR/bin/zgwatch_common.py" "$DIR/bin/customer_watch.py" "$DIR/bin/chain_watch.py" || { say "❌ 代码编译失败"; exit 1; }

# 3) 自检（配置完整性）
if ! ZG_WATCHDOG_DIR="$DIR" "$PY" "$DIR/bin/zgwatch_common.py"; then
  say "❌ 配置自检失败（缺关键键）"
  exit 1
fi

LABEL="$(scutil --get ComputerName 2>/dev/null || hostname)"

if [ "${ZG_INSTALL_DRY:-0}" = "1" ]; then
  say "（DRY）跳过 launchd 安装与首轮试跑。安装完成（测试模式）。"
  exit 0
fi

# 4) LaunchAgents（两份：客户观察 / 打钱钱包；每 180 秒）
mkdir -p "$HOME/Library/LaunchAgents"
gen_plist() { # gen_plist <name> <script> <interval>
  cat > "$HOME/Library/LaunchAgents/$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$1</string>
  <key>ProgramArguments</key><array><string>$PY</string><string>$DIR/bin/$2</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>ZG_WATCHDOG_DIR</key><string>$DIR</string>
    <key>LANG</key><string>zh_CN.UTF-8</string>
    <key>PYTHONIOENCODING</key><string>utf-8</string>
  </dict>
  <key>StartInterval</key><integer>$3</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$DIR/logs/$1.out.log</string>
  <key>StandardErrorPath</key><string>$DIR/logs/$1.err.log</string>
</dict></plist>
PLIST
}
gen_plist com.zgwatch.customer customer_watch.py 180
gen_plist com.zgwatch.chain chain_watch.py 180
UID_="$(id -u)"
for j in com.zgwatch.customer com.zgwatch.chain; do
  launchctl bootout "gui/$UID_/$j" 2>/dev/null
  launchctl bootstrap "gui/$UID_" "$HOME/Library/LaunchAgents/$j.plist" 2>/dev/null \
    || launchctl load -w "$HOME/Library/LaunchAgents/$j.plist" 2>/dev/null
done
say "✅ launchd 已装载:"
launchctl list 2>/dev/null | grep com.zgwatch || say "⚠️ 未在 launchctl list 看到（若机器无图形会话，登录后自动生效）"

# 5) 首轮试跑（首轮只建基线，不发告警）
cd "$DIR/bin" || exit 1
ZG_WATCHDOG_DIR="$DIR" "$PY" customer_watch.py > "$DIR/logs/first_run.log" 2>&1 || true
ZG_WATCHDOG_DIR="$DIR" "$PY" chain_watch.py >> "$DIR/logs/first_run.log" 2>&1 || true
say "✅ 首轮试跑完成（基线已建立）"

# 6) 向龙哥报喜
DM_OK=$(ZG_WATCHDOG_DIR="$DIR" "$PY" -c "
import sys; sys.path.insert(0, '$DIR/bin')
import zgwatch_common as C
print('1' if C.dm(u'✅ 观察台已就位：$LABEL\n客户机掉线兜底 + 打款钱包监控已开始常开运行（每 3 分钟自动检查，这台机器 7×24 代值班）。') else '0')
" 2>/dev/null)
if [ "$DM_OK" = "1" ]; then
  say "✅ 已发送部署回执（飞书私聊）"
else
  say "⚠️ 部署回执发送失败（不影响监控运行；日志: $DIR/logs/）"
fi

say ""
say "===== 部署完成 ====="
say "监控目录: $DIR（bin=代码 config=配置 logs=日志 state=状态）"
say "查看运行: tail -f $DIR/logs/customer_watch.log"
say "停用: launchctl bootout gui/$UID_/com.zgwatch.customer; launchctl bootout gui/$UID_/com.zgwatch.chain"
