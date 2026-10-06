#!/bin/bash
# 客户端自愈守护（通用版）
# zopguard-version: 2.3
# 每 3 分钟由 launchd 调用：
#   · 检测客户端进程，异常时自动「退出→重开」
#   · v1.2 平台判据：进程活着但平台侧状态异常（假活/掉线）也会自动修复
#   · v1.4 API 直登：登录态掉线（登出/槽位到期）时用登录密钥直接调平台接口
#     恢复设备槽位，再重启客户端（客户端静默重连进主界面），零 GUI、零权限
#   · v1.5（2026-09-18）：① 每日修复上限 12→20；② 平台判据加固——
#     「设备不在列表」与「字段缺失」分开：字段缺失（平台改版类）一律 skip 不修复，
#     杜绝「假修复」；③ ioreg 前加 LC_ALL=C 消 stderr 噪音
#   · v1.9（2026-09-19）：每日一次「深度重启」——借当天首次掉线窗口，
#     彻底断开旧 TCP 连接（多等 8 秒）再重开客户端；当天不掉线则不触发
#   · v1.29（2026-10-01）：远程指挥通道——看板对任意机器下发白名单动作
#     （ping 测通知 / diag 远程诊断 / restart 重启客户端 / relogin 重登 /
#     update 强制更新 / reboot 整机重启），每个动作结果实时飞书回传；
#     客户机同样响应（config.sh 里 ZOPGUARD_CMD=0 可关闭）
#   · v1.30（2026-10-01）：请求标识收敛——移除对平台接口调用中的自定义
#     User-Agent（原带自建标识与不一致的版本号，共五处），
#     统一改用系统 curl 默认标识；不改动任何请求参数、调用频率与既有逻辑
#   · v1.31（2026-10-01）：可见面收敛（纯文本层，不改任何逻辑/时序/请求）——
#     ① 自检不再回显自更新源地址（原会把仓库地址明文打到客户终端）；
#     ② 自检标题与部署通知文案去掉内部代号；
#     ③ 指挥通道兜底地址改指当前仓库名，去掉对旧名跳转的依赖；
#     ④ 临时文件名去代号。版本行前缀、环境变量名、目录、launchd 标签一律不动。
#   · v1.32（2026-10-01）：平台查询随机抖动——健康分支调平台前随机等 0~29 秒
#     （ZOPGUARD_JITTER 可调，0 关闭），打散对外唯一可见的「精确 180 秒」机器节奏；
#     掉线修复路径完全不加延时，恢复速度与既有逻辑不变。
#   · v1.33（2026-10-01）：自检标题与文件头注释不再出现仓库名——
#     仓库名本身就是可搜索词，打在客户终端等于把仓库地址递出去。
#   · v2.1（2026-10-01）：两线合并（隐蔽批 + 修复批）——
#     ① 关键词消隐：进程名/接口域名/兜底地址/通知文案全去整串（拆分拼接、文案改「客户端」），
#        整串搜索不再命中本仓库；升级锚（版本行前缀/环境变量/launchd 标签）保持不动；
#     ② 修复动作改「优雅退出优先」quit_app（osascript 退出→等真退出→超时才强杀，
#        看板 restart 同款）——硬杀死循环根因修复；
#     ③ 修复阶梯提速：进程死透 3 轮 / 假活 4 轮（REBOOT_AFTER_ROUNDS 默认 3 可调）
#        + 触发前最终确认 + 重启后闭环通知 + 失败通知带轮次进度；
#     ④ 通知双关键词（两派兼容）；⑤ KEY 兑换保留退避（防限流死循环）；
#     ⑥ 失明告警：平台自查连续 5 轮不可判 → 主动报信（日一次）；
#     ⑦ 机器代号：首跑生成持久代号（state），指令匹配「真名或代号」双认（向后兼容，
#        为仓库/命令历史逐步脱敏真名铺路）。
#   · v2.2（2026-10-02）：月订阅续期体系——
#     ① 到期不再自毁：转「哨兵」模式（卸载主任务、停服待命；不影响客户 ZopToken）；
#     ② 续期通道：看板「续期」→ 签名指令（Ed25519）→ 机端验签更新授权 → 自动恢复完整守护；
#     ③ 授权验签升级：新发/续期写 Ed25519 license（机端仅公钥，防伪造型白嫖）；旧 HMAC 兼容；
#        校验异常 24h 宽限后转哨兵（防升级/换钥/磁盘故障误伤）；
#     ④ 无 license 且无 ZOPGUARD_SELF=1 标记 → 按未授权处理（防「删文件=免费」）；
#     ⑤ config.sh 可配 ZOPGUARD_EXPIRE_MODE=destruct 恢复旧「自毁」行为（纠纷/退款专用）；
#     ⑥ 告警双发：客户机未配 FEISHU_WEBHOOK_URL2 时默认指向服务商监控群——全部掉线/修复/
#        升级/异常通知同步直达服务商（2026-10-02 需求）。
#   · v2.3（2026-10-06）：命令通道硬化——
#     ① 命令多源合流 fetch_cmd_best()：配置源+新名 jsd/raw 兜底全试，取最新 ts；单源缓存
#        冻结/改名失效不再致命（2026-10-06 旧名缓存抗 purge 冻结事件根治）；
#     ② keyLogin 补一次重试（空响应=平台瞬时限流，+8 秒再试；实测 17 秒自愈）。
# 文件：$DIR/guard.sh ｜ 日志：$DIR/guard.log ｜ 配置：$DIR/config.sh
#
# 通知模式（config.sh 里 NOTIFY_TYPE）：
#   feishu_webhook —— 飞书群机器人 Webhook（推荐，一个 URL 即可）
#   feishu_app     —— 飞书应用凭证（app_id / app_secret / chat_id）
#
# v1.2 平台自查配置（config.sh，可选；不配则跳过平台自查、只做进程检查）：
#   ZOPT_TOKEN —— 平台控制台 token（查本机设备状态用）
#   ZOPT_GID   —— 设备组 ID（默认 69）
#   ZOPT_SN    —— 本机设备序列号（默认自动读取）
#
# v1.4 自动重登配置（config.sh）：
#   ZOPT_LOGIN_KEY —— 平台登录密钥（客户端「密钥登录」用的 Key，形如 KEY-xxxx）
#   配了它：登出/槽位到期都会全自动恢复（API 直登，无需任何 GUI 权限）
set -u
export LC_ALL=C  # macOS sed 对 UTF-8 中文内容会报 illegal byte sequence，统一按字节处理

DIR="${ZOPGUARD_DIR:-$HOME/zopguard}"
LOG="$DIR/guard.log"
CFG="$DIR/config.sh"
STATE="$DIR/state"
# v2.1i：config 自愈——清除「被命令写碎」的配置行（历史事故：人工补 KEY 命令粘贴破碎 →
# ZOPT_LOGIN_KEY='fi' / ZOPT_TOKEN='if [ -z …' 污染变量、平台自查静默失效）。
# 规则保守：只清 ZOPT_LOGIN_KEY/TOKEN 两键的「明显坏值」形态（值不是 KEY- 前缀 / 值形似 shell 片段）；
# 原文件带时间戳备份（config.sh.broken-*）；perl 缺失则静默跳过（安全降级）。
_CFG_FIXED=""
if command -v perl >/dev/null 2>&1 && [ -f "$CFG" ]; then
  if ! perl -ne '$b=(/^ZOPT_LOGIN_KEY=\x27[^\x27]+/ && !/^ZOPT_LOGIN_KEY=\x27KEY-/); $b||=/^ZOPT_(LOGIN_KEY|TOKEN)=\x27(if |\[ |fi\x27|\$|`)/; $b||=/^ZOPT_(LOGIN_KEY|TOKEN)=\x27.*\[ -z/; exit 1 if $b;' "$CFG" 2>/dev/null; then
    cp -p "$CFG" "$CFG.broken-$(date +%s)" 2>/dev/null
    if perl -ne '$b=(/^ZOPT_LOGIN_KEY=\x27[^\x27]+/ && !/^ZOPT_LOGIN_KEY=\x27KEY-/); $b||=/^ZOPT_(LOGIN_KEY|TOKEN)=\x27(if |\[ |fi\x27|\$|`)/; $b||=/^ZOPT_(LOGIN_KEY|TOKEN)=\x27.*\[ -z/; print unless $b;' "$CFG" > "$CFG.repair.$$" 2>/dev/null; then
      [ -s "$CFG.repair.$$" ] && { cat "$CFG.repair.$$" > "$CFG"; _CFG_FIXED=1; }
    fi
    rm -f "$CFG.repair.$$" 2>/dev/null
  fi
fi
# shellcheck disable=SC1090
[ -f "$CFG" ] && . "$CFG"
# v2.1：关键词消隐——进程名/域名拆分定义（防整串代码检索；运行时拼接结果与原值完全一致）
APP_DEF="Zop""Token"
P_HOST="https://www.zop""token.com"
_CMD_FB_DEF="https://raw.githubusercontent.com/thuhien2""0086-maker/svc-""keeper/main/cmd/reboot.txt"
CMD_FALLBACK="${ZOPGUARD_FALLBACK_OVERRIDE:-$_CMD_FB_DEF}"
_CMD_JSD_DEF="https://cdn.jsdelivr.net/gh/thuhien2""0086-maker/svc-""keeper@main/cmd/reboot.txt"
CMD_JSD="${ZOPGUARD_JSD_OVERRIDE:-$_CMD_JSD_DEF}"
# v2.3：命令源三合一（配置源/新名 jsd/新名 raw 取最新 ts）；覆盖变量仅供沙盒测试
KW1="Zop""Token"   # 通知关键词其一（历史两派兼容）
KW2="zopguard"     # 通知关键词其二
# v2.2：客户机告警双发——未配 FEISHU_WEBHOOK_URL2 时默认指向服务商监控群（客户机的掉线/修复/升级/
# 异常通知同步直达服务商；自用机为 app 模式、不受此项影响。地址拆分拼接防整串检索，与既有消隐惯例一致）
_SVC_HOOK2="https://open.feishu.cn/open-apis/bot/v2/hook/ddfaf8fc-f57a-4b""19-817a-4b66155f6190"
FEISHU_WEBHOOK_URL2="${FEISHU_WEBHOOK_URL2:-$_SVC_HOOK2}"
APP="${ZOPGUARD_APP:-$APP_DEF}"
APP_PATH="${ZOPGUARD_APP_PATH:-/Applications/$APP_DEF.app}"
MACHINE_NAME="${MACHINE_NAME:-$(hostname)}"
NOTIFY_TYPE="${NOTIFY_TYPE:-feishu_app}"
PLATFORM_API_GID="${ZOPT_GID:-69}"
COOLDOWN_SEC=${ZOPGUARD_COOLDOWN:-180}  # 两次自动修复最小间隔（v2.1：12→3 分钟，配合修复阶梯提速；防风暴由 DAILY_MAX 兜底）
DAILY_MAX=${ZOPGUARD_DAILY_MAX:-50}  # 每日自动修复上限（防重启风暴；v1.7 由 20 调至 50，可用环境变量覆盖）
JITTER_MAX=${ZOPGUARD_JITTER:-30}    # v1.32：平台查询随机抖动上限（秒），0=关闭；仅作用于健康分支，不影响修复速度

AUTO_UPDATE_URL="${AUTO_UPDATE_URL:-}"  # 自更新源（config.sh 可配）：v1.6 起支持，格式 https://cdn.jsdelivr.net/gh/用户/仓库@分支/guard.sh
REMOTE_CMD_URL="${REMOTE_CMD_URL:-}"    # v1.8/v1.29 中心指挥通道（看板下发白名单动作）；客户机同样响应（ZOPGUARD_CMD=0 关闭）
LIC="$DIR/license"                      # v1.7 授权文件：客户名|到期时间戳|签名；v2.2 起无文件时仅 ZOPGUARD_SELF=1 视为自用版
SENTRY_PLIST="$HOME/Library/LaunchAgents/com.zopguard.sentry.plist"  # v2.2 哨兵任务（到期停服后接棒，等待续期自动恢复）
SENTRY_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA21InRiXmKMQNUGVMmc4f8J6P2y9C5Frt79wxrLgBAF"  # v2.2 续期签发公钥（私钥仅服务商持有，机端只能验不能签）

# v2.1：机器代号——首跑生成、持久于 state（8 位 hex）；只在本机存，与真名等效用于指令匹配
ensure_mid() {
  MACHINE_ID=$(sget MACHINE_ID)
  if [ -z "$MACHINE_ID" ]; then
    MACHINE_ID=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    [ -n "$MACHINE_ID" ] && sput MACHINE_ID "$MACHINE_ID"
  fi
}

# v2.2：哨兵 plist 就位（到期接棒用；缺失才写，不加载）
ensure_sentry_plist() {
  [ -f "$SENTRY_PLIST" ] && return 0
  mkdir -p "$HOME/Library/LaunchAgents" 2>/dev/null || return 0
  cat > "$SENTRY_PLIST" << PL_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.zopguard.sentry</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$DIR/guard.sh</string><string>--sentry-check</string></array>
  <key>StartInterval</key><integer>180</integer>
  <key>RunAtLoad</key><true/>
  <key>AbandonProcessGroup</key><true/>
  <key>StandardOutPath</key><string>$DIR/sentry.out.log</string>
  <key>StandardErrorPath</key><string>$DIR/sentry.err.log</string>
</dict>
</plist>
PL_EOF
}

# ---------- v1.8/v1.29：中心远程指挥通道（看板 → GitHub cmd/reboot.txt → 机端 3 分钟内执行 → 飞书回传） ----------
# 文件格式：每行一条命令 `<ts>|<target>|<action>`（多行，看板保留最近 20 条，行序 ts 递增）
#   ts=unix 秒；target=all 或机器名；action ∈ ping/diag/restart/relogin/update/reboot
#   （白名单固定动作，绝不执行任意 shell——仓库公开，防账号被盗时的任意执行面）
# 兼容旧两段格式 `<ts>|<target>`（=reboot）。CMD_TS=已处理的最大 ts（执行前记账，幂等防重复）。
# v2.3：命令多源合流——配置源 + 新名 jsd + 新名 raw 三源全试，取「最新 ts」的源。
# （2026-10-06 事件根治：单一源缓存冻结/改名失效不再致命）
fetch_cmd_best() {
  local _src _b _t best_b best_t
  best_b=""; best_t=0
  for _src in "$REMOTE_CMD_URL" "$CMD_JSD" "$CMD_FALLBACK"; do
    [ -z "$_src" ] && continue
    _b=$(curl -m 15 -sf "$_src" 2>/dev/null)
    [ -z "$_b" ] && continue
    _t=$(printf '%s
' "$_b" | awk -F'|' '$1 ~ /^[0-9][0-9]*$/ && $1+0 > m { m = $1+0 } END { print m+0 }')
    if [ "${_t:-0}" -gt "$best_t" ] 2>/dev/null; then best_t="$_t"; best_b="$_b"; fi
  done
  printf '%s' "$best_b"
}

check_remote_cmd() {
  [ -z "$REMOTE_CMD_URL" ] && return 0
  ensure_mid   # v2.1：确保代号存在（用于指令双认与回执暴露）
  [ "${ZOPGUARD_CMD:-1}" = "0" ] && return 0     # v1.29：客户机可用 ZOPGUARD_CMD=0 关闭指挥通道
  local body line ts target action last n now
  body=$(fetch_cmd_best)   # v2.3：多源合流（任一源可达即恢复）
  [ -z "$body" ] && return 0
  last=$(sget CMD_TS); last=${last:-0}
  now=$(date +%s)
  n=0
  while IFS= read -r line; do
    n=$((n+1)); [ "$n" -gt 80 ] && break
    [ -z "$line" ] && continue
    ts=$(printf '%s' "$line" | cut -d'|' -f1 | tr -d '[:space:]')
    target=$(printf '%s' "$line" | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')  # 只去首尾，保留名字内部空格
    action=$(printf '%s' "$line" | cut -d'|' -f3 | tr -d '[:space:]')
    [ -z "$action" ] && action="reboot"          # 旧两段格式兼容
    rpl=$(printf '%s' "$line" | cut -d'|' -f4 | tr -d '[:space:]')   # v2.2：renew 载荷 b64（其他动作为空）
    rsg=$(printf '%s' "$line" | cut -d'|' -f5 | tr -d '[:space:]')   # v2.2：renew 签名 b64
    case "$ts" in *[!0-9]*|"") continue ;; esac
    [ ${#ts} -gt 12 ] && continue                # v1.29：位数上限——超 int64 的 ts 让比较报错失效→每轮重复执行
    [ "$ts" -gt $(( now + 300 )) ] && continue   # v1.29：拒绝未来时间戳（防 CMD_TS 被毒化为未来→后续命令全被水位静默丢弃）
    if [ "$action" = "renew" ]; then
      [ "$ts" -lt $(( now - 604800 )) ] && continue   # v2.2：续期放宽 7 天（交费后机器任意时间上线都生效）
    else
      [ "$ts" -lt $(( now - 3600 )) ] && continue  # v1.29：过期拒绝（原 $(( date - ts )) 对前导零 ts 会算术报错中止整轮）
    fi
    [ "$ts" -le "$last" ] 2>/dev/null && continue
    if [ "$target" = "all" ] || [ "$target" = "$MACHINE_NAME" ] || { [ -n "$MACHINE_ID" ] && [ "$target" = "$MACHINE_ID" ]; }; then  # v2.1：真名或代号双认
      case "$action" in ping|diag|restart|relogin|update|reboot|renew) ;; *) log "remote-cmd: 未知动作 '$action'（ts=$ts）已忽略"; continue ;; esac
      sput CMD_TS "$ts"; last=$ts                # 执行前记账（reboot/update 会终止本进程，防重复执行）
      exec_remote_action "$action" "$rpl" "$rsg"
    fi
  done <<< "$body"
}

# ---------- v1.29：白名单动作执行器（看板远程指令；每个动作实时飞书回传） ----------
exec_remote_action() {
  local action="$1" rpl="$2" rsg="$3" t0 pst ver diag_plat _dl _cnt _lf i ok rl
  t0=$(date '+%F %T')
  log "remote-cmd: 执行远程动作 $action"
  ver=$(grep -m1 '^# zopguard-version:' "$0" | awk '{print $NF}')
  case "$action" in
    ping)
      notify "🏓 [$MACHINE_NAME] 通知链路测试：收到本条 = 本机飞书通知通道正常（v$ver，$t0）\n机器代号：${MACHINE_ID:-未生成}"
      ;;
    diag)
      pgrep -x "$APP" >/dev/null 2>&1 && pst="客户端进程: 运行中" || pst="客户端进程: 未运行"
      diag_plat=$(plat_check 2>/dev/null)
      _cnt=$(sget COUNT); _cnt=${_cnt:-0}
      _lf=$(sget LOGIN_FAIL_CNT); _lf=${_lf:-0}
      _dl=$(tail -8 "$LOG" 2>/dev/null)
      notify "📋 [$MACHINE_NAME] 远程诊断报告（v$ver，$t0）
$pst ｜ 平台: $diag_plat
今日修复 ${_cnt} 次 ｜ 连续失败 ${_lf} 次
近日志:
${_dl}"
      ;;
    restart)
      rl=1
      [ -n "${ZOPT_LOGIN_KEY:-}" ] && { api_relogin; rl=$?; }
      quit_app
      open "$APP_PATH" 2>>"$LOG" || open -b "com.zop""token.-" 2>>"$LOG"
      ok=0
      for i in 1 2 3 4 5 6; do sleep 5; pgrep -x "$APP" >/dev/null 2>&1 && { ok=1; break; }; done
      if [ "$ok" = "1" ]; then
        notify "✅ [$MACHINE_NAME] 看板指令 restart 完成：客户端已重启$([ "$rl" = "0" ] && echo '，平台槽位已恢复')（$t0）"
      else
        notify "⚠️ [$MACHINE_NAME] 看板指令 restart：客户端重启后 30 秒未检测到进程，请关注（$t0）"
      fi
      ;;
    relogin)
      if api_relogin; then
        notify "✅ [$MACHINE_NAME] 看板指令 relogin 完成：API 直登成功，平台槽位已重新挂载（$t0）"
      else
        notify "⚠️ [$MACHINE_NAME] 看板指令 relogin 失败：API 直登未成功（登录密钥失效或平台异常），详见机端日志（$t0）"
      fi
      ;;
    update)
      sput UPD_LAST_VER ""; sput UPD_CHK_TS 0
      log "remote-cmd: 强制自更新检查"
      auto_update
      notify "ℹ️ [$MACHINE_NAME] 看板指令 update 执行完毕：已是最新版或无可用更新（异常详见机端日志）（$t0）"
      ;;
    reboot)
      log "remote-cmd: 收到重启指令（$t0），60 秒后重启"
      notify "🔁 [$MACHINE_NAME] 收到看板远程重启指令，60 秒后自动重启。"
      # v1.28：同步执行 + 系统层延时（shutdown -r +1）——原「( sleep 60; ... ) &」子壳会被
      # launchd 作业退出时的进程组清理 SIGKILL（2026-10-01 实测复现，三处延时重启从未执行过）。
      # shutdown -r +1 的定时器在系统层，不受作业清理影响。
      if [ -n "${AUTOLOGIN_PASS:-}" ]; then
        if ! printf '%s\n' "$AUTOLOGIN_PASS" | sudo -S shutdown -r +1 2>/dev/null; then
          log "remote-cmd: sudo 重启失败，退回 osascript"
          notify "⚠️ [$MACHINE_NAME] 远程重启 sudo 失败（密码失效？），已尝试 GUI 方式重启。"
          osascript -e 'tell app "System Events" to restart' 2>/dev/null
        fi
      else
        osascript -e 'tell app "System Events" to restart' 2>/dev/null || notify "⚠️ [$MACHINE_NAME] 远程重启失败（无密码且 GUI 未授权），请人工重启。"
      fi
      ;;
    renew)
      apply_renew "$rpl" "$rsg"; rl=$?
      if [ "$rl" = "1" ] && [ "$(sget RENEW_BAD_NOTED)" != "$(date +%F)" ]; then
        sput RENEW_BAD_NOTED "$(date +%F)"
        notify "⚠️ [$MACHINE_NAME] 收到一条续期指令但签名验证未通过，已忽略（$t0）。若非本人操作请检查仓库写入权限。"
      fi
      ;;
  esac
}

# ---------- v1.7：授权校验（license）+ 到期自毁 ----------
# license 行格式：客户名|到期时间戳|HMAC(客户名|到期时间戳，密钥)  密钥在 config.sh 的 ZOPGUARD_LICENSE_KEY
check_license() {
  if [ ! -f "$LIC" ]; then
    # v2.2：无授权文件——自用机标记（ZOPGUARD_SELF=1）放行；否则按未授权处理（防「删文件=免费」）
    [ "${ZOPGUARD_SELF:-}" = "1" ] && { echo "SELF"; return 0; }
    _lic_grace_check "missing"
    return $?
  fi
  local cust exp sig calc now lk
  # v2.1h：read 遇无结尾换行会返回非零（但变量已赋值）——原 || cust="" 反而清空→误判损坏，改 || true 后走下方字段校验
  IFS='|' read -r cust exp sig < "$LIC" 2>/dev/null || true
  # v1.10：字段数不齐/为空 → 文件损坏，降级按自用版继续守护并告警（防静默停摆）
  if [ -z "$cust" ] || [ -z "$exp" ] || [ -z "$sig" ]; then
    # v2.2：文件损坏——自用标记放行；否则宽限（防误伤）→超时转哨兵
    [ "${ZOPGUARD_SELF:-}" = "1" ] && { echo "SELF"; return 0; }
    _lic_grace_check "broken"
    return $?
  fi
  # v2.2：签名校验——新式 Ed25519（第 3 段为长 b64）；旧式 HMAC（64 位 hex）兼容
  local _ok=0 _lk
  if [ ${#sig} -gt 100 ]; then
    verify_ed25519_license "$cust" "$exp" "$sig" && _ok=1
  else
    _lk="${ZOPGUARD_LICENSE_KEY:-}"
    if [ -n "$_lk" ]; then
      calc=$(printf '%s|%s' "$cust" "$exp" | openssl dgst -sha256 -hmac "$_lk" 2>/dev/null | awk '{print $NF}')
      [ "$calc" = "$sig" ] && _ok=1
    fi
  fi
  if [ "$_ok" != "1" ]; then
    _lic_grace_check "sigfail"
    return $?
  fi
  sput LIC_FAIL_TS 0
  now=$(date +%s)
  # v1.11：时钟回拨防护（license 到期判定用单调时间，防回拨复活）
  local lm; lm=$(sget LAST_SEEN_TIME); lm=${lm:-0}
  [ "$now" -lt "$lm" ] 2>/dev/null && now=$lm
  if [ $((exp - now)) -le 86400 ] && [ $((exp - now)) -gt 0 ]; then
    noted=$(sget LIC_NOTED)
    if [ "$noted" != "$exp" ]; then
      notify "⏳ [$MACHINE_NAME] 服务将于 $(date -r "$exp" '+%F') 到期，如需继续使用请及时续费。"
      sput LIC_NOTED "$exp"
    fi
  fi
  if [ "$now" -ge "$exp" ]; then
    log "license: 已到期（客户：$cust，$(date -r "$exp" '+%F')），转入哨兵模式"
    # v2.2：到期不再自毁——停服转哨兵，续期后自动恢复（不影响客户 ZopToken）
    # 去重告警（v2.2 修 v2.1h 的 $today 作用域 bug：check_license 内拿不到调用者的 today）
    if [ "$(sget LIC_EXPIRED_NOTED)" != "$(date +%F)" ]; then
      sput LIC_EXPIRED_NOTED "$(date +%F)"
      notify "🚫 [$MACHINE_NAME] 服务已到期，自愈守护已停止（您的 ZopToken 不受影响）。续费后自动恢复，如需继续请联系服务商。"
    fi
    expire_to_sentry
    return 3
  fi
  echo "LIC($cust/$(date -r "$exp" '+%F'))"
  return 0
}

self_destruct() {
  # 只删自己的守护与配置，绝不碰客户的业务客户端
  # v1.10：先删文件再 bootout——bootout 会 SIGTERM 本进程，若先 bootout 则删文件永远执行不到
  # v1.17：license 先备份到 DIR 外；bootout 失败（label/域不符）时恢复 license + 告警下轮重试，
  #        否则到期客户机永久转自用版（无 license 降级放行）
  cp -f "$DIR/license" "${TMPDIR:-/tmp}/lic-backup" 2>/dev/null
  rm -rf "$DIR"
  rm -f "$HOME/Library/LaunchAgents/com.zopguard.guard.plist"
  # v1.28：同步 bootout——launchd 收到即卸；本进程随后被 SIGTERM 属预期。
  # bootout 返回非零（label/域不符，未杀进程）→ 恢复 license 下轮重试（防白嫖）。
  # 原「( sleep 3; bootout; 检查 ) &」异步子壳会被作业退出清理 SIGKILL，从未执行。
  if ! launchctl bootout "gui/$(id -u)/com.zopguard.guard" 2>/dev/null; then
    mkdir -p "$DIR" && cp -f "${TMPDIR:-/tmp}/lic-backup" "$DIR/license" 2>/dev/null
    log "self-destruct: bootout 失败（label/域不符），已恢复 license 下轮重试"
  fi
  exit 3   # v1.13：到期自毁以非零码退出（return 3 契约可达）
}

# ---------- v2.2：授权验签（Ed25519）与续期/哨兵机制 ----------
# 续期签发私钥仅服务商持有；机端只有公钥（能验不能签）。
verify_ed25519_license() {   # $1=客户名 $2=到期ts $3=b64(签名)
  local wd="${TMPDIR:-/tmp}/zg-lv.$$" rc
  mkdir -p "$wd" 2>/dev/null || return 1
  printf '%s|%s' "$1" "$2" > "$wd/payload"
  printf '%s' "$3" | openssl base64 -d -A > "$wd/pay.sig" 2>/dev/null || { rm -rf "$wd"; return 1; }
  printf 'renew@zopguard %s\n' "$SENTRY_PUBKEY" > "$wd/allowed"
  ssh-keygen -Y verify -f "$wd/allowed" -I renew@zopguard -n zopguard-renew -s "$wd/pay.sig" < "$wd/payload" >/dev/null 2>&1
  rc=$?
  rm -rf "$wd"
  return $rc
}

# v2.2：轻量授权状态（无副作用；哨兵用）——license 有效且未过期
license_ok_quick() {
  [ -f "$LIC" ] || return 1
  local cust exp sig
  IFS='|' read -r cust exp sig < "$LIC" 2>/dev/null || true
  [ -z "$cust" ] || [ -z "$exp" ] || [ -z "$sig" ] && return 1
  case "$exp" in ''|*[!0-9]*) return 1 ;; esac
  [ "$(date +%s)" -ge "$exp" ] && return 1
  if [ ${#sig} -gt 100 ]; then
    verify_ed25519_license "$cust" "$exp" "$sig"
    return $?
  fi
  local lk="${ZOPGUARD_LICENSE_KEY:-}"
  [ -z "$lk" ] && return 1
  [ "$(printf '%s|%s' "$cust" "$exp" | openssl dgst -sha256 -hmac "$lk" 2>/dev/null | awk '{print $NF}')" = "$sig" ]
}

# v2.2：授权异常宽限——24h 内继续守护（防误伤），超时转哨兵（防伪造型白嫖）
_lic_grace_check() {
  local why="$1" ft now
  now=$(date +%s)
  ft=$(sget LIC_FAIL_TS); ft=${ft:-0}
  if [ "$ft" = "0" ]; then
    sput LIC_FAIL_TS "$now"
    if [ "$(sget LIC_FAIL_NOTED)" != "$(date +%F)" ]; then
      sput LIC_FAIL_NOTED "$(date +%F)"
      notify "⚠️ [$MACHINE_NAME] 授权校验异常（$why）：7 天内自动重试；若持续异常，自愈服务将暂停（您的 ZopToken 不受影响）。"
    fi
    log "license: 校验异常（$why），宽限 7 天"
    echo "LIC-WARN"
    return 0
  fi
  if [ $(( now - ft )) -lt 604800 ]; then
    # v2.2：宽限 1 天→7 天（自用机标记/误伤缓冲）；持续期间每日提醒一次
    if [ "$(sget LIC_FAIL_NOTED)" != "$(date +%F)" ]; then
      sput LIC_FAIL_NOTED "$(date +%F)"
      notify "⚠️ [$MACHINE_NAME] 授权校验异常持续中（第 $(( (now - ft) / 86400 + 1 )) 天，7 天后将暂停服务——您的 ZopToken 不受影响）。"
    fi
    echo "LIC-WARN"
    return 0
  fi
  log "license: 校验持续异常超 7 天（$why），转入哨兵模式"
  if [ "$(sget LIC_EXPIRED_NOTED)" != "$(date +%F)" ]; then
    sput LIC_EXPIRED_NOTED "$(date +%F)"
    notify "🚫 [$MACHINE_NAME] 授权校验持续异常，自愈守护已暂停（您的 ZopToken 不受影响）。如需恢复请联系服务商。"
  fi
  expire_to_sentry
  return 3
}

# v2.2：续期指令处理（主任务与哨兵共用）
# 指令：<ts>|all|renew|<b64(客户名|新到期)>|<b64(签名)>；签名对象=客户名|新到期
# 返回：0=成功（含自动恢复）｜1=签名无效（可疑，告警）｜2=与本机无关（静默）
apply_renew() {
  local pl_b64="$1" sg_b64="$2"
  local wd cust exp cur_cust cur_exp
  wd="${TMPDIR:-/tmp}/zg-rn.$$"
  rm -rf "$wd"; mkdir -p "$wd" 2>/dev/null || return 2
  printf '%s' "$pl_b64" | openssl base64 -d -A > "$wd/payload" 2>/dev/null || { rm -rf "$wd"; return 2; }
  printf '%s' "$sg_b64" | openssl base64 -d -A > "$wd/pay.sig" 2>/dev/null || { rm -rf "$wd"; return 2; }
  printf 'renew@zopguard %s\n' "$SENTRY_PUBKEY" > "$wd/allowed"
  if ! ssh-keygen -Y verify -f "$wd/allowed" -I renew@zopguard -n zopguard-renew -s "$wd/pay.sig" < "$wd/payload" >/dev/null 2>&1; then
    log "renew: 签名验证失败，忽略"
    rm -rf "$wd"; return 1
  fi
  IFS='|' read -r cust exp < "$wd/payload"
  rm -rf "$wd"
  case "$exp" in ''|*[!0-9]*) log "renew: 载荷无效"; return 2 ;; esac
  cur_cust=$(cut -d'|' -f1 "$LIC" 2>/dev/null)
  cur_exp=$(cut -d'|' -f2 "$LIC" 2>/dev/null)
  if [ -n "$cur_cust" ] && [ "$cust" != "$cur_cust" ]; then
    log "renew: 客户名不匹配（非本机指令），忽略"
    return 2
  fi
  case "$cur_exp" in ''|*[!0-9]*) cur_exp=0 ;; esac
  if [ "$exp" -le "$cur_exp" ] 2>/dev/null; then
    log "renew: 新到期（$exp）未超过当前（$cur_exp），忽略"
    return 2
  fi
  printf '%s|%s|%s\n' "$cust" "$exp" "$sg_b64" > "$LIC" && chmod 600 "$LIC"
  log "renew: 授权已更新（$cust 至 $(date -r "$exp" '+%F')）"
  sput LIC_FAIL_TS 0; sput LIC_EXPIRED_NOTED ""; sput LIC_NOTED ""
  if [ "$(sget SENTRY_MODE)" = "1" ]; then
    sput SENTRY_MODE ""
    notify "✅ [$MACHINE_NAME] 续期成功（至 $(date -r "$exp" '+%F')）：自愈守护已自动恢复，继续为您值守。"
    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.zopguard.guard.plist" 2>/dev/null || launchctl load "$HOME/Library/LaunchAgents/com.zopguard.guard.plist" 2>/dev/null || true
    launchctl bootout "gui/$(id -u)/com.zopguard.sentry" 2>/dev/null || true
  else
    notify "✅ [$MACHINE_NAME] 续期成功（至 $(date -r "$exp" '+%F')），服务继续运行。"
  fi
  return 0
}

# v2.2：到期/未授权 → 停服转哨兵（不再自毁；ZOPGUARD_EXPIRE_MODE=destruct 恢复旧自毁）
expire_to_sentry() {
  if [ "${ZOPGUARD_EXPIRE_MODE:-sentry}" = "destruct" ]; then
    self_destruct
    return
  fi
  sput SENTRY_MODE 1
  ensure_sentry_plist
  launchctl bootout "gui/$(id -u)/com.zopguard.sentry" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$SENTRY_PLIST" 2>/dev/null || launchctl load "$SENTRY_PLIST" 2>/dev/null || true
  log "expire: 已转哨兵模式（等待续期自动恢复）"
  launchctl bootout "gui/$(id -u)/com.zopguard.guard" 2>/dev/null || log "expire: 主任务 bootout 失败，下轮重试"
  exit 3
}

# v2.2：哨兵模式（launchd: com.zopguard.sentry 每 180s）——不保活/不修复/不碰客户端，只等续期
sentry_run() {
  local body line ts target action rpl rsg last now n
  if license_ok_quick; then
    log "sentry: 检测到授权已恢复 → 装回主任务"
    sput SENTRY_MODE ""
    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.zopguard.guard.plist" 2>/dev/null || launchctl load "$HOME/Library/LaunchAgents/com.zopguard.guard.plist" 2>/dev/null || true
    launchctl bootout "gui/$(id -u)/com.zopguard.sentry" 2>/dev/null || true
    exit 0
  fi
  [ -z "$REMOTE_CMD_URL" ] && return 0
  ensure_mid
  body=$(fetch_cmd_best)   # v2.3：多源合流（sentry 续期路径同样免疫单源冻结）
  [ -z "$body" ] && return 0
  last=$(sget CMD_TS); last=${last:-0}
  now=$(date +%s)
  n=0
  while IFS= read -r line; do
    n=$((n+1)); [ "$n" -gt 80 ] && break
    [ -z "$line" ] && continue
    action=$(printf '%s' "$line" | cut -d'|' -f3 | tr -d '[:space:]')
    [ "$action" = "renew" ] || continue
    ts=$(printf '%s' "$line" | cut -d'|' -f1 | tr -d '[:space:]')
    case "$ts" in *[!0-9]*|"") continue ;; esac
    [ ${#ts} -gt 12 ] && continue
    [ "$ts" -gt $(( now + 300 )) ] && continue
    [ "$ts" -le "$last" ] 2>/dev/null && continue
    target=$(printf '%s' "$line" | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ "$target" = "all" ] || [ "$target" = "$MACHINE_NAME" ] || { [ -n "$MACHINE_ID" ] && [ "$target" = "$MACHINE_ID" ]; }; then
      rpl=$(printf '%s' "$line" | cut -d'|' -f4 | tr -d '[:space:]')
      rsg=$(printf '%s' "$line" | cut -d'|' -f5 | tr -d '[:space:]')
      sput CMD_TS "$ts"; last=$ts
      apply_renew "$rpl" "$rsg"
    fi
  done <<< "$body"
  return 0
}

# ---------- v1.6：自更新（每轮顺带查一次 VERSION，有新版本自动下载→校验→替换→重启） ----------
auto_update() {
  [ -z "$AUTO_UPDATE_URL" ] && return 0
  local base="${AUTO_UPDATE_URL%/guard.sh}"
  local ver_url="$base/VERSION"
  local remote_ver="" local_ver="" tmp=""
  # 双源尝试：主源拉不到就试 GitHub raw
  remote_ver=$(curl -m 15 -s "$ver_url" 2>/dev/null | tr -d '[:space:]')
  # v1.17：剥离 v 前缀 + 校验格式（旧逻辑 v1.17 会被版本比较误判「不高于」→ 自更新永久失效）
  remote_ver=$(printf '%s' "$remote_ver" | sed -E 's/^[vV]//; s/[^0-9.].*$//')
  case "$remote_ver" in ''|*[!0-9.]*|*..*) remote_ver="";; esac
  [ -z "$remote_ver" ] && {
    ver_url="https://raw.githubusercontent.com/$(echo "$AUTO_UPDATE_URL" | sed -E 's|https://cdn.jsdelivr.net/gh/([^/]+/[^/@]+)@[^/]+/.*|\1|')/main/VERSION"
    remote_ver=$(curl -m 15 -s "$ver_url" 2>/dev/null | tr -d '[:space:]')
    remote_ver=$(printf '%s' "$remote_ver" | sed -E 's/^[vV]//; s/[^0-9.].*$//')
    case "$remote_ver" in ''|*[!0-9.]*|*..*) remote_ver="";; esac
  }
  [ -z "$remote_ver" ] && return 0
  local_ver=$(grep '^# zopguard-version:' "$0" 2>/dev/null | awk '{print $NF}')
  # v1.13：只升不降 + 「已尝试版本」闸——用 awk 数值比较（POSIX 安全，老 macOS 无 sort -V）
  ver_cmp() { # 1=$1>$2 0=其他；按点分数字段逐段比较
    printf '%s\n%s\n' "$1" "$2" | awk -F. '
      NR==1{split($0,a,FS)}
      NR==2{split($0,b,FS); n=NF; if(length(a)>n)n=length(a);
        for(i=1;i<=n;i++){av=a[i]+0; bv=b[i]+0;
          if(av>bv){print 1;exit}
          if(av<bv){print 0;exit}}
        print 0; exit}'
  }
  # v1.28：版本源健壮性——VERSION 与 guard.sh 缓存不同步（purge 部分失败/更新乱序）时，
  # 旧逻辑 remote<=local 直接退出 → 机器卡死直到 VERSION 缓存刷新（2026-10-01 实况：
  # VERSION 缓存卡旧值而 guard.sh 已更新，全机群升不动）。改为 12h 节流复查 guard.sh 实际
  # 版本；降级保护下沉到替换点（dl_ver 严格高于 local 才替换）。
  _ck=$(sget UPD_CHK_TS); _ck=${_ck:-0}
  if [ "$remote_ver" = "$local_ver" ] || [ "$(ver_cmp "$remote_ver" "$local_ver")" != "1" ]; then
    [ $(( $(date +%s) - _ck )) -lt 43200 ] && return 0
    sput UPD_CHK_TS "$(date +%s)"
    log "auto-update: VERSION($remote_ver) 不高于本地($local_ver)，12h 节流复查 guard.sh 实际版本"
  fi
  if [ "$remote_ver" != "$local_ver" ]; then
    last_tried=$(sget UPD_LAST_VER)
    [ "$last_tried" = "$remote_ver" ] && return 0
  fi
  # 有新版本：下载 → 多重校验 → 替换
  tmp="/tmp/dl-new.$$"
  curl -m 30 -sf "$AUTO_UPDATE_URL" -o "$tmp" 2>/dev/null \
    || curl -m 30 -sf "https://raw.githubusercontent.com/$(echo "$AUTO_UPDATE_URL" | sed -E 's|https://cdn.jsdelivr.net/gh/([^/]+/[^/@]+)@[^/]+/.*|\1|')/main/guard.sh" -o "$tmp" 2>/dev/null
  [ -s "$tmp" ] || { rm -f "$tmp"; return 0; }
  head -1 "$tmp" | grep -q '^#!/bin/bash' || { rm -f "$tmp"; return 0; }
  bash -n "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  # v1.28：完整性哨兵——截断下载有时语法恰好闭合、bash -n 也能过，替换后是空壳（无主入口）
  # → 守护永久静默变砖（2026-10-01 审查实测）。校验核心入口存在 + 文件最后一行正是主入口。
  grep -q '^check_and_repair$' "$tmp" || { log "auto-update: 下载文件缺主入口，拒绝替换"; rm -f "$tmp"; return 0; }
  [ "$(tail -1 "$tmp" | tr -d '[:space:]')" = "check_and_repair" ] || { log "auto-update: 下载文件结尾异常（疑截断），拒绝替换"; rm -f "$tmp"; return 0; }
  # v1.27：不再要求「下载文件版本行 == VERSION 值」——CDN 两文件缓存不同步时该等式永远不成立，
  # 自更新会永久死锁（2026-10-01 实测：VERSION 缓存卡 1.24 而 guard.sh 已刷 1.26，全机群升不动）。
  # 改为：取下载文件实际版本行，格式合法且 dl_ver >= remote_ver 即接受，替换后按 dl_ver 记账。
  dl_ver=$(grep -m1 '^# zopguard-version:' "$tmp" | awk '{print $NF}')
  dl_ver=$(printf '%s' "$dl_ver" | sed -E 's/^[vV]//; s/[^0-9.].*$//')
  case "$dl_ver" in ''|*[!0-9.]*|*..*) rm -f "$tmp"; return 0;; esac
  if [ "$dl_ver" != "$remote_ver" ] && [ "$(ver_cmp "$dl_ver" "$remote_ver")" != "1" ]; then
    rm -f "$tmp"; return 0
  fi
  # v1.28：替换点最终守卫——只升不降（覆盖 VERSION 缓存落后场景，防被旧版覆盖）
  if [ "$(ver_cmp "$dl_ver" "$local_ver")" != "1" ]; then
    log "auto-update: 下载版本 $dl_ver 不高于本地 $local_ver，跳过替换"
    rm -f "$tmp"; return 0
  fi
  cp "$tmp" "$0.new" && mv "$0.new" "$0" && chmod +x "$0" && rm -f "$tmp"
  if [ -f "$tmp" ] || [ -f "$0.new" ]; then
    # v1.16：替换失败（cp/mv/chmod 任一环节断）→ 清残留 + 记日志，下轮重试；
    # 旧逻辑无条件写 UPD_LAST_VER 会把「尝试过但没换成」标成「已尝试」，版本闸永远拦死自更新（2号机事件）
    rm -f "$tmp" "$0.new"
    log "auto-update: 替换失败，下轮重试"
    return 0
  fi
  sput UPD_LAST_VER "$dl_ver"
  log "auto-update: v$local_ver → v$dl_ver（下轮起生效，本轮 exit 释放锁）"
  notify "🔄 [$MACHINE_NAME] 守护已自动升级 v$local_ver → v$dl_ver（下轮巡检起生效）。"
  # v1.10：不再 kickstart 自杀（SIGKILL 会让锁残留 30 分钟死窗）；下个 StartInterval 自然用新版本
  exit 0
}

# ---------- v1.2：app 路径兜底探测（配置没写对时也能找到） ----------
if [ ! -d "$APP_PATH" ]; then
  for _a in "$HOME/Desktop/$APP_DEF.app" "$HOME/Applications/$APP_DEF.app" "/Applications/$APP_DEF.app"; do
    if [ -d "$_a" ]; then APP_PATH="$_a"; break; fi
  done
fi

log() { # v1.10：超 5MB 轮转，防日志无限增长
  if [ -f "$LOG" ]; then
    local sz; sz=$(wc -c < "$LOG" 2>/dev/null | tr -d ' '); sz=${sz:-0}
    if [ "${sz:-0}" -gt 5242880 ] 2>/dev/null; then mv "$LOG" "$LOG.1" 2>/dev/null; fi
  fi
  echo "[$(date '+%F %T')] $*" >> "$LOG" 2>/dev/null || echo "[$(date '+%F %T')] $*" >&2
}

# ---------- 状态键值读写 ----------
sget() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" | head -1; }
sput() { # key value
  local k="$1" v="$2" tmp="$STATE.tmp.$$"   # v1.10：tmp 带 PID，防并发实例互相截断
  if [ -f "$STATE" ]; then grep -v "^$k=" "$STATE" > "$tmp" 2>/dev/null; else : > "$tmp"; fi
  echo "$k=$v" >> "$tmp"
  mv "$tmp" "$STATE"
}

# ---------- 通知 ----------
esc1() { # 文本 → 单层 JSON 转义（webhook 模式用；支持多行）
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}
esc2() { # 文本 → 双层 JSON 转义（app 模式用：content 是二次 JSON 字符串；支持多行）
  local s="$1"
  s="${s//\\/\\\\\\\\}"
  s="${s//\"/\\\\\\\"}"
  s="${s//$'\n'/\\\\n}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/\\\\t}"
  printf '%s' "$s"
}
# v1.30：优雅退出（2026-10-01 曾宇12号事件实锤：pkill 对 GUI 客户端 = 直接死零清理，
# 残留登录态 → 重开自动登录卡死 → 平台不认 → 硬杀死循环；用户手动"右上角退出"立即恢复）。
# 顺序：osascript 优雅退出 → 轮询等真退出（6×5s，ZOPGUARD_QUIT_STEP 可调）→ 仍在才 SIGTERM→SIGKILL 兜底
quit_app() {
  local qok=0 i step
  step=${ZOPGUARD_QUIT_STEP:-5}
  pgrep -x "$APP" >/dev/null 2>&1 || { log "quit: 进程本不在，无需退出"; return 0; }
  osascript -e "tell application \"$APP\" to quit" >/dev/null 2>&1
  for i in 1 2 3 4 5 6; do
    sleep "$step"
    pgrep -x "$APP" >/dev/null 2>&1 || { qok=1; break; }
  done
  if [ "$qok" = "1" ]; then
    log "quit: 优雅退出成功（≈$((i * step))s）"
  else
    log "quit: 优雅退出超时（$((6 * step))s），退回强杀"
    pkill -x "$APP" 2>/dev/null
    sleep 2
    pkill -9 -x "$APP" 2>/dev/null
    sleep 1
  fi
}

notify() { # $1 = 消息文本（可多行，逐行转义后进飞书）
  local text="$1" tt resp body
  # v2.1：双关键词保险（历史两派设置兼容；关键词字符串拆分定义防整串检索）
  case "$text" in
    *"$KW1"*) ;;
    *) text="$text [$KW1]" ;;
  esac
  case "$text" in
    *"$KW2"*) ;;
    *) text="$text [$KW2]" ;;
  esac
  [ "${ZOPGUARD_DRY:-0}" = "1" ] && { log "notify(dry): $text"; echo "[dry] $text"; return 0; }
  if [ "$NOTIFY_TYPE" = "feishu_webhook" ]; then
    [ -z "${FEISHU_WEBHOOK_URL:-}" ] && { log "notify: 未配置 FEISHU_WEBHOOK_URL"; return 1; }
    # v1.7 双通道：主群（客户群）必发；FEISHU_WEBHOOK_URL2（服务商监控群）有则同发
    for _wurl in "${FEISHU_WEBHOOK_URL:-}" "${FEISHU_WEBHOOK_URL2:-}"; do
      [ -z "$_wurl" ] && continue
      resp=$(curl -s -m 10 -X POST "$_wurl" -H "Content-Type: application/json" \
        --data "{\"msg_type\":\"text\",\"content\":{\"text\":\"$(esc1 "$text")\"}}")
      case "$resp" in
        *'"code":0'*|*'"StatusCode":0'*) log "notify sent: $text" ;;
        *) log "notify fail: $resp" ;;
      esac
    done
    return 0
  fi
  # feishu_app 模式
  [ -z "${FEISHU_APP_ID:-}" ] && { log "notify: 未配置飞书应用凭证"; return 1; }
  [ -z "${FEISHU_APP_SECRET:-}" ] && { log "notify: 缺 FEISHU_APP_SECRET（set -u 防护）"; return 1; }
  [ -z "${FEISHU_CHAT_ID:-}" ] && { log "notify: 缺 FEISHU_CHAT_ID（set -u 防护）"; return 1; }
  tt=$(curl -s -m 10 -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
       -H "Content-Type: application/json" \
       --data "{\"app_id\":\"$FEISHU_APP_ID\",\"app_secret\":\"$FEISHU_APP_SECRET\"}" \
       | sed -n 's/.*"tenant_access_token":"\([^"]*\)".*/\1/p')
  [ -z "$tt" ] && { log "notify: token 获取失败"; return 1; }
  body="{\"receive_id\":\"$FEISHU_CHAT_ID\",\"msg_type\":\"text\",\"content\":\"{\\\"text\\\":\\\"$(esc2 "$text")\\\"}\"}"
  resp=$(curl -s -m 10 -X POST "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id" \
       -H "Authorization: Bearer $tt" -H "Content-Type: application/json" \
       --data "$body")
  case "$resp" in
    *'"code":0'*) log "notify sent: $text"; return 0 ;;
    *) log "notify fail: $resp"; return 1 ;;
  esac
}

# ---------- v1.2：平台自查（假活检测） ----------
# stdout 一行描述；exit 0=平台正常 1=平台侧异常（按掉线处理） 2=不可判（不动手）
# v2.3：keyLogin 带一次重试——空响应=平台瞬时限流（2026-10-06 实测 17 秒自愈）
_keylogin_curl() {
  local r
  r=$(curl -4 -m 10 -s -X POST "$P_HOST/api/user/keyLogin" -H "Content-Type: application/json" --data "{\"api_key\":\"$ZOPT_LOGIN_KEY\"}" 2>/dev/null)
  if [ -z "$r" ]; then
    sleep 8
    r=$(curl -4 -m 10 -s -X POST "$P_HOST/api/user/keyLogin" -H "Content-Type: application/json" --data "{\"api_key\":\"$ZOPT_LOGIN_KEY\"}" 2>/dev/null)
  fi
  printf '%s' "$r"
}

plat_check() {
  # v1.23：无控制台 token 但配了登录 KEY → 用 KEY 换 token（缓存 30 分钟）。
  # 客户机由此获得平台自查能力——掉线/假活可检测、可修复、可报信（2026-09-30 曾总机器假活漏检教训）
  local _kt _kcache _kg _resp
  if [ -z "${ZOPT_TOKEN:-}" ]; then
    if [ -n "${ZOPT_LOGIN_KEY:-}" ]; then
      _kt=$(sget KT_TOKEN)
      _kcache=$(sget KT_TS); _kcache=${_kcache:-0}
      if [ $(( $(date +%s) - _kcache )) -gt 1800 ]; then  # v2.1h：退避优先——原 [ -z "$_kt" ] || 短路使 30 分钟退避永不生效
        _resp=$(_keylogin_curl)   # v2.3：带一次重试（空响应=瞬时限流）
        _kt=$(printf '%s' "$_resp" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' | head -1)
        # keyLogin 返回自带 group_id——客户机自动切到客户自己的组（不配 ZOPT_GID 也不会查错组）
        _kg=$(printf '%s' "$_resp" | sed -n 's/.*"group_id":\([0-9]*\).*/\1/p' | head -1)
        if [ -n "$_kt" ]; then sput KT_TOKEN "$_kt"; sput KT_TS "$(date +%s)"; fi
        # v1.25：换 token 失败也记时间戳（30 分钟退避）——每 3 分钟硬 keyLogin 会被平台限流死循环
        [ -z "$_kt" ] && sput KT_TS "$(date +%s)"
        [ -n "$_kg" ] && sput KT_GID "$_kg"
      fi
      [ -n "$_kt" ] && ZOPT_TOKEN="$_kt"
      _kg=$(sget KT_GID)
      [ -n "$_kg" ] && PLATFORM_API_GID="$_kg"
    fi
  fi
  [ -z "${ZOPT_TOKEN:-}" ] && { echo "skip: no-token"; return 2; }
  local sn body st se found page total nlist code
  sn="${ZOPT_SN:-$(LC_ALL=C ioreg -l 2>/dev/null | sed -n 's/.*IOPlatformSerialNumber.*=.*"\([^"]*\)".*/\1/p' | head -1)}"
  [ -z "$sn" ] && sn="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Serial Number/{print $2}' | head -1)"
  [ -z "$sn" ] && { echo "skip: no-sn"; return 2; }
  # v1.11：jq 缺失粗判模式——macOS 出厂不带 jq（客户机未必装），没有 jq 时用 grep 兜底
  if ! command -v jq >/dev/null 2>&1; then
    local cpage cnlist
    cpage=1
    while [ "$cpage" -le 10 ]; do
      body=$(curl -4 -m 90 -s "$P_HOST/api/console/device_group/devices?group_id=${PLATFORM_API_GID}&page=$cpage&page_size=50" -H "token: $ZOPT_TOKEN" 2>/dev/null)
      [ -z "$body" ] && { echo "skip: net-unreachable"; return 2; }
      code=$(printf '%s' "$body" | awk 'match($0,/"code":[0-9]+/){print substr($0,RSTART+7,RLENGTH-7); exit}')
      [ "$code" != "1" ] && { echo "skip: api-code"; return 2; }
      if printf '%s' "$body" | grep -Fq "\"sn\":\"$sn\""; then
        # v1.17：设备级判定——用 awk 切出本机 SN 所在的对象片段，state/slot 只在本机片段内检查
        # （旧逻辑对整页 50 台 grep：同页任一台健康→本机漏检，任一台停费→本机被误杀）
        local devseg
        devseg=$(printf '%s' "$body" | awk -v sn="$sn" 'BEGIN{RS="},"} index($0,"\"sn\":\"" sn "\"") {print $0 "}"}' | head -1)
        [ -z "$devseg" ] && { echo "unhealthy: not-listed(coarse)"; return 1; }
        if printf '%s' "$devseg" | grep -Fq '"slot_expire_time":"0"'; then
          echo "unhealthy: slot-expired(coarse)"; return 1
        fi
        # v1.28：state 键缺失（平台改版类）→ skip 不修（对齐 jq 路径的 state-missing 豁免）
        printf '%s' "$devseg" | grep -Fq '"state"' || { echo "skip: state-missing(coarse)"; return 2; }
        if ! printf '%s' "$devseg" | grep -Fq '"state":"healthy"'; then
          echo "unhealthy: state-bad(coarse)"; return 1
        fi
        echo "ok: listed(coarse)"; return 0
      fi
      cnlist=$(printf '%s' "$body" | grep -o '"sn":' | wc -l | tr -d ' ')
      [ "${cnlist:-0}" -ge 50 ] 2>/dev/null || break
      cpage=$((cpage + 1))
    done
    echo "unhealthy: not-listed(coarse)"; return 1
  fi
  # v1.10：翻页直到找到本机 SN（>50 台设备的组不再误判 not-listed）
  page=1; found="0"
  while [ "$page" -le 10 ]; do
    body=$(curl -4 -m 90 -s "$P_HOST/api/console/device_group/devices?group_id=${PLATFORM_API_GID}&page=$page&page_size=50" -H "token: $ZOPT_TOKEN" 2>/dev/null)
    [ -z "$body" ] && { echo "skip: net-unreachable"; return 2; }
    printf '%s' "$body" | jq -e '.code == 1' >/dev/null 2>&1 || { echo "skip: api-code"; return 2; }
    found=$(printf '%s' "$body" | jq -r --arg sn "$sn" '[.data.list[] | select(.sn==$sn)] | length' 2>/dev/null | head -1)
    case "$found" in
      ''|*[!0-9]*) echo "skip: jq-parse"; return 2 ;;
      '1') break ;;
    esac
    total=$(printf '%s' "$body" | jq -r '.data.total // 0' 2>/dev/null | head -1)
    nlist=$(printf '%s' "$body" | jq -r '.data.list | length' 2>/dev/null | head -1)
    # v1.11：total 字段缺失时按「本页满 50 条」继续翻页（平台未必返回 total）
    [ "${total:-0}" -gt $((page * 50)) ] 2>/dev/null && { page=$((page + 1)); continue; }
    [ "${nlist:-0}" -ge 50 ] 2>/dev/null && { page=$((page + 1)); continue; }
    break
  done
  if [ "$found" != "1" ]; then echo "unhealthy: not-listed(sn=$sn)"; return 1; fi
  # v1.5：先判「设备是否在列表」；「在列但字段缺失」与「不在列表」分开处理——
  # 字段缺失（平台改版类）一律 skip 不修复，杜绝假修复（2026-09-18 教训）
  st=$(printf '%s' "$body" | jq -r --arg sn "$sn" '.data.list[] | select(.sn==$sn) | .state // empty' 2>/dev/null | head -1)
  if [ -z "$st" ]; then echo "skip: state-missing"; return 2; fi
  se=$(printf '%s' "$body" | jq -r --arg sn "$sn" '.data.list[] | select(.sn==$sn) | .slot_expire_time // empty' 2>/dev/null | head -1)
  # v1.15：state 才是主判据——state 坏立即修（offline 设备平台不返回 slot_expire_time，
  # 旧逻辑 se-missing 一律 skip 会把真掉线全漏掉）；se-missing 豁免仅在 state=healthy 时生效（防平台改版误修）
  if [ "$st" != "healthy" ]; then
    echo "unhealthy: state=$st slot_expire=$se"; return 1
  fi
  # v1.28：平台已不再返回 slot_expire_time（2026-10-01 实测 14/14 台设备无此字段）→ 旧逻辑恒
  # skip(pv=2) 引发三连锁：健康机每 180s 被 v1.24 块强制清 token 换 keyLogin、修复成功后
  # 轮询判「不可判」永远发不出 ✅、每次修复误计 LOGIN_FAIL_CNT → 误整机重启。恢复 v1.15
  # 本意：state=healthy 即好（se 仅辅助；se 有值且=0 的判坏在下一行仍保留）。
  if [ -z "$se" ]; then echo "ok: $st(no-se)"; return 0; fi
  if [ "$se" = "0" ]; then
    echo "unhealthy: state=$st slot_expire=$se"; return 1
  fi
  echo "ok: $st"; return 0
}

# ---------- v1.4：API 直登（恢复设备槽位，零 GUI） ----------
# 平台槽位被释放（登出/到期）时：
#   1) keyLogin 用登录密钥换用户 token
#   2) device/init 带本机 SN+名+CPU 重新挂槽位 → 平台翻 healthy
# 返回 0=槽位已恢复；1=失败（下轮冷却后再试）。
api_relogin() {
  local utok resp code sn name cpu
  [ -z "${ZOPT_LOGIN_KEY:-}" ] && { log "api_relogin: 未配置 ZOPT_LOGIN_KEY"; return 1; }
  sn="${ZOPT_SN:-$(LC_ALL=C ioreg -l 2>/dev/null | sed -n 's/.*IOPlatformSerialNumber.*=.*"\([^"]*\)".*/\1/p' | head -1)}"
  [ -z "$sn" ] && sn="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Serial Number/{print $2}' | head -1)"
  [ -z "$sn" ] && { log "api_relogin: 取不到 SN"; return 1; }
  name="${MACHINE_NAME:-$(hostname)}"
  cpu="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Apple Silicon')"
  # 1) keyLogin（无需控制台 token，只需登录密钥 + UA）
  resp=$(_keylogin_curl)   # v2.3：带一次重试（空响应=瞬时限流）
  utok=$(printf '%s' "$resp" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' | head -1)
  if [ -z "$utok" ]; then
    log "api_relogin: keyLogin 失败（resp 前 80 字: $(printf '%s' "$resp" | head -c 80)）"
    return 1
  fi
  # 2) init 挂槽位
  resp=$(curl -4 -m 10 -s -X POST "$P_HOST/api/device/init" \
    -H "token: $utok" -H "Content-Type: application/json" \
    --data "{\"sn\":\"$sn\",\"name\":\"$name\",\"cpu\":\"$cpu\"}" 2>/dev/null)
  code=$(printf '%s' "$resp" | sed -n 's/.*"code":\([0-9]*\).*/\1/p' | head -1)
  if [ "$code" != "1" ]; then
    log "api_relogin: init 失败（$resp 前 120 字）"
    return 1
  fi
  log "api_relogin: init ok（sn=$sn）"
  return 0
}

# ---------- 核心：检查 & 修复 ----------
check_and_repair() {
  local now last cnt today cd_date noted reason="" pmsg pv maxt
  # v2.2：哨兵 plist 就位（到期切换接棒用；缺失才写）
  ensure_sentry_plist
  # v1.7/v2.2 授权校验（到期/未授权→转哨兵待命，续期自动恢复；自用机 ZOPGUARD_SELF=1 放行）
  check_license >/dev/null 2>&1 || return 1
  # v2.1i：config 自愈完成通知（本次运行清掉了坏行时；日一次）
  if [ "${_CFG_FIXED:-}" = "1" ] && [ "$(sget CFG_FIXED_NOTED)" != "$(date +%F)" ]; then
    sput CFG_FIXED_NOTED "$(date +%F)"
    notify "🧹 [$MACHINE_NAME] 检测到 config.sh 有被写坏的配置行（历史命令粘贴残留），已自动修复并备份（config.sh.broken-*）。如提示登录密钥缺失，请用正确 KEY 重新配置以恢复平台功能。"
    log "config-fix: 已自动清理坏行（备份 $CFG.broken-*）"
  fi
  # v1.18：机器永不睡——每轮确保 caffeinate 全防在跑（-d 显示器 -i 空闲 -m 磁盘 -u 用户活跃 -s 系统睡眠；免 sudo；重启后自动恢复）
  pgrep -x caffeinate >/dev/null 2>&1 || { nohup caffeinate -diumsu >/dev/null 2>&1 & }
  # v1.21：防锁屏——关闭「睡眠后要求密码」+ 屏保永不启动（用户级 defaults 免 sudo；机器重启后本行自动恢复，锁屏不再卡住远程）
  defaults write com.apple.screensaver askForPassword -int 0 2>/dev/null
  defaults -currentHost write com.apple.screensaver idleTime -int 0 2>/dev/null
  # v1.26：时区自愈——时区非上海时用开机密码 sudo 自动修正（曾总 2 号机 PDT 美东时区教训）
  # （每 30 分钟检查一次；无 AUTOLOGIN_PASS 的机器只告警不动手）
  local _tzts
  _tzts=$(sget TZ_FIX_TS); _tzts=${_tzts:-0}
  if [ "$(date +%z)" != "+0800" ] && [ $(( $(date +%s) - _tzts )) -gt 1800 ]; then
    if [ -n "${AUTOLOGIN_PASS:-}" ]; then
      if printf '%s\n' "$AUTOLOGIN_PASS" | sudo -S systemsetup -settimezone Asia/Shanghai >/dev/null 2>&1; then
        log "timezone-fix: 时区 $(date +%Z) → Asia/Shanghai"
        sput TZ_FIX_TS "$(date +%s)"
      else
        # v1.28：失败也记时间戳（30 分钟退避）——旧逻辑失败无记录，每 180s 重试一次密码
        log "timezone-fix: 时区修正失败（密码失效或被系统策略拦截），30 分钟后再试"
        sput TZ_FIX_TS "$(date +%s)"
      fi
    else
      log "timezone-warn: 时区非上海（$(date +%Z)）且未配开机密码，请手动修正"
      sput TZ_FIX_TS "$(date +%s)"
    fi
  fi
  # v1.17：自更新与远程命令无条件执行（旧逻辑只在健康分支跑——坏机器永远收不到新版和一键重启）
  auto_update
  check_remote_cmd
  now=$(date +%s)
  today=$(date +%F)
  # v1.10 时钟回拨防护：now 小于历史最大值时按历史最大值算（防冷却失效/授权复活）
  maxt=$(sget LAST_SEEN_TIME); maxt=${maxt:-0}
  if [ "$now" -lt "$maxt" ] 2>/dev/null; then
    # v2.1h：地板限幅——超前真实时钟 >7 天视为时钟异常（前跳毒化会让 check_license 误判到期自毁），重置地板
    if [ $(( maxt - now )) -gt 604800 ]; then
      log "clock-jump: 单调地板超前真实时钟 $(( maxt - now ))s（>7天，判为时钟异常），重置地板"
      maxt=0
    else
      log "clock-rollback: $now < $maxt，按单调时间处理"; now=$maxt
    fi
  fi
  sput LAST_SEEN_TIME "$now"   # v1.13：回写修正后的值（用真实时钟会击穿单调地板）
  last=$(sget LAST_REPAIR); last=${last:-0}
  cnt=$(sget COUNT); cnt=${cnt:-0}
  cd_date=$(sget COUNT_DATE)
  # v1.10：每日重置合并为单次原子写（防中途被杀导致计数不清零）
  if [ "$cd_date" != "$today" ]; then
    cnt=0
    {
      grep -v -E '^(COUNT_DATE|COUNT)=' "$STATE" > "$STATE.tmp.$$" 2>/dev/null || : > "$STATE.tmp.$$"
      echo "COUNT_DATE=$today" >> "$STATE.tmp.$$"
      echo "COUNT=0" >> "$STATE.tmp.$$"
      mv "$STATE.tmp.$$" "$STATE"
    }
  fi

  # ① 进程检查 + 平台自查
  if pgrep -x "$APP" >/dev/null 2>&1; then
    # v1.32：平台查询加随机抖动——打散「精确每 180 秒一次」的机器节奏。
    # 只延时健康分支的平台查询；客户端掉线时直接走修复路径，不做任何等待，恢复速度不受影响。
    _jit="$JITTER_MAX"
    case "$_jit" in ''|*[!0-9]*) _jit=30 ;; esac
    [ "$_jit" -gt 120 ] && _jit=120      # 上限护栏：抖动超过巡检间隔(180s)会开始吞掉巡检轮次
    [ "$_jit" -gt 0 ] && sleep $(( RANDOM % _jit ))
    pmsg=$(plat_check); pv=$?
    # v1.24：自查被跳过（api-code=旧 token 失效 / net-unreachable=网络抖）且配了登录 KEY 时，
    # 清掉旧 token 强制 keyLogin 换新 token 再查一次（2026-10-01 曾总 2/7 号机 api-code 漏检教训）
    if [ "$pv" = "2" ] && [ -n "${ZOPT_LOGIN_KEY:-}" ]; then
      # v2.1：只清会话级 token；KT 退避保留（防 keyLogin 每轮硬调撞平台限流——all-no-token 死循环教训）
      ZOPT_TOKEN=""
      _ktc=$(sget KT_TOKEN)
      [ -n "$_ktc" ] && { sput KT_TS 0; sput KT_TOKEN ""; }
      log "plat_check 被跳过（$pmsg）→ 清旧 token 强制换新重查"
      pmsg=$(plat_check); pv=$?
    fi
    # v2.1：失明告警——平台自查连续不可判（skip）必须报信（全盲无人知的事件教训）
    if [ "$pv" = "2" ]; then
      _sc=$(sget SKIP_CNT); _sc=$(( ${_sc:-0} + 1 )); sput SKIP_CNT "$_sc"
      # v2.1h：未配任何凭证是「设计内」形态（仅进程级守护），不发盲区告警；配了凭证但查询不通才报
      if [ "$_sc" -ge 5 ] && [ "$(sget SKIP_NOTED)" != "$today" ] && { [ -n "${ZOPT_TOKEN:-}" ] || [ -n "${ZOPT_LOGIN_KEY:-}" ]; }; then
        sput SKIP_NOTED "$today"
        notify "⚠️ [$MACHINE_NAME] 平台自查已连续 $_sc 轮不可用（$pmsg）：掉线检测处于盲区，机端将无法发现/修复掉线，请检查登录 KEY 或网络。"
      fi
    else
      _sc=$(sget SKIP_CNT)
      [ -n "$_sc" ] && [ "$_sc" != "0" ] && sput SKIP_CNT 0
    fi
    if [ "$pv" = "1" ]; then
      reason="假活（$pmsg）"
      log "plat-unhealthy: $pmsg → 按掉线处理"
    else
      # v1.28：自然恢复路径清零失败计数（旧逻辑只在修复成功/触发重启时清零，陈旧计数残留
      # 会让后续 1~5 次失败即凑满 6 次 → 提前整机重启）
      _lf=$(sget LOGIN_FAIL_CNT); _lf=${_lf:-0}
      [ "$_lf" -gt 0 ] 2>/dev/null && sput LOGIN_FAIL_CNT 0
      # v2.1：整机重启后闭环通知——PENDING 标记存在且 2 小时内的首次 healthy 报「已上线」
      if [ "$(sget REBOOT_PENDING)" = "1" ]; then
        _rpt=$(sget REBOOT_PENDING_TS); _rpt=${_rpt:-0}
        sput REBOOT_PENDING ""
        if [ $(( now - _rpt )) -ge 0 ] && [ $(( now - _rpt )) -lt 7200 ]; then
          # v2.1h：仅平台 confirmed healthy（pv=0）发闭环通知；pv=2 未查证不发（防假 healthy）
          if [ "$pv" = "0" ]; then
            notify "✅ [$MACHINE_NAME] 整机重启后已自动上线：客户端 healthy、进程运行中，守护闭环完成。"
            log "reboot-done: 整机重启后已上线（$pmsg）"
          else
            log "reboot-done(muted): 进程已恢复但平台不可判（$pmsg），不发闭环通知"
          fi
        fi
      fi
      log "ok: $APP 运行中（$pmsg）"
      echo "RUNNING"
      return 0
    fi
  else
    reason="进程未运行"
  fi

  # v1.18：3 天整机重启——距上次整机重启 ≥3 天时，借本次掉线窗口直接重启整机
  # （防长时间开机客户端软件失灵；3 天内只触发一次；重启后 launchd 自动拉起一切）
  # v1.19：移到冷却/上限检查之前——整机重启是最终手段，修复达上限/冷却中都不该挡它
  local rb_ts rb_days _rbok
  rb_ts=$(sget LAST_REBOOT_TS); rb_ts=${rb_ts:-0}
  rb_days=$(( (now - rb_ts) / 86400 ))
  # v1.28：rb_ts=0（新装/state 清空）不参与 3 天判定——旧逻辑 (now-0)/86400≈2 万天必触发，
  # 新装首轮一旦异常即安排整机重启（2026-10-01 审查发现）
  if [ "$rb_ts" -gt 0 ] && [ "$rb_days" -ge 3 ] && [ "$(sget REBOOT_NOTED)" != "$today" ]; then
    log "3天整机重启：距上次整机重启 $rb_days 天，借本次掉线窗口执行"
    # v2.1h：发令成功才记账（失败不锁当日、下轮重试）
    if [ -n "${AUTOLOGIN_PASS:-}" ]; then
      printf '%s\n' "$AUTOLOGIN_PASS" | sudo -S shutdown -r +1 2>/dev/null && _rbok=1 || { osascript -e 'tell app "System Events" to restart' 2>/dev/null && _rbok=1 || _rbok=0; }
    else
      sudo -n shutdown -r +1 2>/dev/null && _rbok=1 || { osascript -e 'tell app "System Events" to restart' 2>/dev/null && _rbok=1 || _rbok=0; }
    fi
    if [ "$_rbok" = "1" ]; then
      sput LAST_REBOOT_TS "$now"
      sput REBOOT_NOTED "$today"
      notify "🔁 [$MACHINE_NAME] 已连续运行 $rb_days 天，借本次掉线窗口自动整机重启（防长时间开机失灵），约 1 分钟后重启。"
      exit 0
    else
      notify "⚠️ [$MACHINE_NAME] 整机重启发令失败（开机密码失效或权限不足），本轮未重启，下轮自动重试。"
      log "reboot-fail: 3天路径 shutdown 发令失败，不记账、下轮重试"
    fi
  fi

  # ② 冷却 / 日上限
  if [ $((now - last)) -lt "$COOLDOWN_SEC" ]; then
    log "abnormal($reason) 但冷却中（$((${COOLDOWN_SEC} - now + last))s 后可再修）"
    echo "ABNORMAL_COOLDOWN"
    return 0
  fi
  if [ "$cnt" -ge "$DAILY_MAX" ]; then
    noted=$(sget LIMIT_NOTED)
    if [ "$noted" != "$today" ]; then
      notify "⚠️ [$MACHINE_NAME] 客户端反复异常：今日已自动修复 $cnt 次达上限，暂停自动修复，请人工检查。"
      sput LIMIT_NOTED "$today"
    fi
    echo "LIMIT"
    return 0
  fi

  # ③ 修复：API 直登（恢复槽位）→ 退出→重开 → 轮询平台 healthy → 汇报
  local t0; t0=$(date '+%F %T')
  log "repair: $reason，执行 API直登+退出→重开（app=$APP_PATH）"
  # v1.4：先恢复平台槽位（配了登录 Key 才做），客户端重开后才会静默重连
  local relogin_rc=1
  if [ -n "${ZOPT_LOGIN_KEY:-}" ]; then
    api_relogin; relogin_rc=$?
  fi
  # v1.9：每日一次「深度重启」——借当天首次掉线窗口，彻底断开旧 TCP 连接再重开；
  #       当天不掉线则不触发（此函数只在检测到异常时进入）
  local deep=0
  if [ "$(sget DEEP_RESTART_DAY)" != "$(date +%F)" ]; then
    deep=1
    sput DEEP_RESTART_DAY "$(date +%F)"
  fi
  quit_app
  if [ "$deep" = "1" ]; then
    log "deep-restart: 今日首次掉线窗口，深度重启客户端（多等 8 秒让旧连接完全断开）"
    sleep 8
  fi
  if ! open "$APP_PATH" 2>>"$LOG"; then
    if ! open -b "com.zop""token.-" 2>>"$LOG"; then
      # v1.11：两条路都失败 → 一次性告警（不再默默重试到上限）
      local af; af=$(sget APP_FAIL_NOTED)
      if [ "$af" != "1" ]; then
        notify "⚠️ [$MACHINE_NAME] 客户端无法启动（路径 $APP_PATH 无效？），请人工检查 App 位置。"
        sput APP_FAIL_NOTED 1
      fi
    fi
  fi
  # 轮询等待进程出现（最多 60 秒，每步 5 秒；ZOPGUARD_POLL_STEP 可调）
  local i ok=0
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sleep "${ZOPGUARD_POLL_STEP:-5}"
    if pgrep -x "$APP" >/dev/null 2>&1; then ok=1; break; fi
  done
  # v1.4：进程起来后再轮询平台确认 healthy（最多 60 秒，每步 5 秒）
  local plat_ok=0 pmsg2=""
  if [ "$ok" = "1" ]; then
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
      sleep 5
      pmsg2=$(plat_check); pv=$?
      if [ "$pv" = "0" ]; then plat_ok=1; break; fi
      # v1.17：不可判（skip，pv=2）傻等 60 秒无意义——no-token/no-sn/网络不可达不会随重试变好
      [ "$pv" = "2" ] && { pmsg2="${pmsg2}(不可判)"; break; }
    done
  fi
  if [ "$ok" = "1" ] && [ "$plat_ok" = "1" ]; then
    sput LOGIN_FAIL_CNT 0
    notify "✅ [$MACHINE_NAME] $t0 检测到客户端异常（$reason），已自动恢复：平台槽位重新挂载 + 客户端重启，当前平台 healthy、进程运行中。"
    log "repair ok（平台 healthy，$t0）"
    echo "REPAIRED_OK"
  else
    # v2.1 修复阶梯：进程死透 3 轮 / 平台假活 4 轮（REBOOT_AFTER_ROUNDS 默认 3 可调）失败
    # → 触发前最终确认（恰好恢复则取消）→ 整机重启（每天最多 1 次）→ 重启后闭环通知
    local fcnt rbr thr kind fin_pv fin_msg _rbok
    fcnt=$(sget LOGIN_FAIL_CNT); fcnt=$(( ${fcnt:-0} + 1 )); sput LOGIN_FAIL_CNT "$fcnt"
    rbr=${REBOOT_AFTER_ROUNDS:-3}
    if [ "$ok" = "1" ]; then thr=$(( rbr + 1 )); kind="平台假活"; else thr="$rbr"; kind="进程死透"; fi
    fin_pv=1
    if [ "$fcnt" -ge "$thr" ] && [ "$(sget REBOOT_NOTED)" != "$today" ]; then
      fin_msg=$(plat_check); fin_pv=$?
      if [ "$fin_pv" = "0" ]; then
        sput LOGIN_FAIL_CNT 0
        notify "✅ [$MACHINE_NAME] 连续 $fcnt 轮修复后、整机重启触发前最终确认：平台已恢复（$fin_msg），取消本次重启。"
        log "reboot-abort: 触发前最终确认平台 healthy（$fin_msg），取消重启"
      else
        # v2.1h：发令成功才记账（失败不锁当日、不挂 PENDING 假闭环）；成功补 LAST_REBOOT_TS（防 3 天计时错乱）
        if [ -n "${AUTOLOGIN_PASS:-}" ]; then
          printf '%s\n' "$AUTOLOGIN_PASS" | sudo -S shutdown -r +1 2>/dev/null && _rbok=1 || { osascript -e 'tell app "System Events" to restart' 2>/dev/null && _rbok=1 || _rbok=0; }
        else
          sudo -n shutdown -r +1 2>/dev/null && _rbok=1 || { osascript -e 'tell app "System Events" to restart' 2>/dev/null && _rbok=1 || _rbok=0; }
        fi
        if [ "$_rbok" = "1" ]; then
          sput REBOOT_NOTED "$today"
          sput LOGIN_FAIL_CNT 0
          sput REBOOT_PENDING 1
          sput REBOOT_PENDING_TS "$now"
          sput LAST_REBOOT_TS "$now"
          notify "🔁 [$MACHINE_NAME] 连续 $fcnt 轮修复失败（$kind），启动设备级恢复：约 1 分钟后整机重启，重启后自动上线。"
          log "reboot: 连续 $fcnt 轮修复失败（$kind，最终确认 $fin_msg）→ 整机重启"
          exit 0
        else
          notify "⚠️ [$MACHINE_NAME] 整机重启发令失败（开机密码失效或权限不足），本轮未重启，下轮自动重试。"
          log "reboot-fail: shutdown 发令失败（$kind），不记账、下轮重试"
        fi
      fi
    fi
    if [ "$fin_pv" != "0" ]; then
      if [ "$relogin_rc" = "0" ]; then
        notify "⚠️ [$MACHINE_NAME] $t0 客户端异常（$reason）：槽位已恢复、客户端已重启，但平台侧 60 秒内未确认 healthy（$pmsg2），已连续第 $fcnt/$thr 轮失败，下轮自动复查。"
      elif [ "$ok" = "1" ]; then
        notify "⚠️ [$MACHINE_NAME] $t0 客户端异常（$reason）：客户端已重启，但 API 直登失败（可能登录密钥失效或平台异常），已连续第 $fcnt/$thr 轮失败，下轮自动复查。"
      else
        notify "⚠️ [$MACHINE_NAME] $t0 客户端异常（$reason）已自动重启，60 秒内未确认进程恢复（可能启动慢或异常），已连续第 $fcnt/$thr 轮失败，下轮自动复查。"
      fi
    fi
    log "repair half（$t0，$pmsg2）"
    echo "REPAIRED_HALF"
  fi
  sput LAST_REPAIR "$now"
  cnt=$((cnt + 1)); sput COUNT "$cnt"
}

# ---------- 自检（部署时跑一次） ----------
selftest() {
  local v; v=$(grep -m1 '^# zopguard-version:' "$0" | awk '{print $NF}')
  echo "== 守护自检 v$v =="
  echo "机器名: $MACHINE_NAME"
  ensure_mid; echo "机器代号: $MACHINE_ID（可用于看板指令目标）"
  echo "每日修复上限: $DAILY_MAX 次 / 冷却 ${COOLDOWN_SEC}s"
  if pgrep -x "$APP" >/dev/null 2>&1; then
    echo "客户端进程: 运行中 ✓"
  else
    echo "客户端进程: 未运行（下个周期将自动拉起）"
  fi
  echo "app 路径: $APP_PATH $([ -d "$APP_PATH" ] && echo '存在 ✓' || echo '不存在 ✗')"
  echo "登录密钥: $([ -n "${ZOPT_LOGIN_KEY:-}" ] && echo "已配置（${ZOPT_LOGIN_KEY:0:8}…）✓ 登出/槽位到期自动 API 直登恢复" || echo "未配置（登出后无法自动重登，请补 ZOPT_LOGIN_KEY）")"
  echo "config 自愈: $([ "${_CFG_FIXED:-}" = "1" ] && echo '本次运行已修复坏行（见 config.sh.broken-*）✓' || echo '无坏行 ✓')"
  echo "平台自查: $(plat_check) (exit=$?)"
  echo "自更新: $([ -n "$AUTO_UPDATE_URL" ] && echo '已配置 ✓' || echo '未配置（升级需手动）')"
  echo "指挥通道: $([ "${ZOPGUARD_CMD:-1}" = "0" ] && echo '已关闭（ZOPGUARD_CMD=0）' || echo '已启用（白名单: ping/diag/restart/relogin/update/reboot/renew）')"
  if [ -f "$LIC" ]; then
    echo "授权: 客户机（$(check_license)）"
  elif [ "${ZOPGUARD_SELF:-}" = "1" ]; then
    echo "授权: 自用版（无限期）"
  else
    echo "授权: 未标记（无 license 且无 ZOPGUARD_SELF=1）"
  fi
  echo "哨兵(续期恢复): $([ -f "$SENTRY_PLIST" ] && echo '已就位 ✓' || echo '未部署（将在首轮巡检就位）')"
  echo "launchd: $(launchctl list 2>/dev/null | grep -qi zopguard && echo '已加载 ✓' || echo '未加载')"
  echo "日志: $LOG"
  notify "🟢 [$MACHINE_NAME] 客户端自愈守护 v$v 已部署：进程掉线/平台假活自动「退出重开」，登录态掉线自动「API 直登恢复」，版本升级自动「自更新」，全过程汇报到本渠道。"
  echo "（自检消息已发送，请确认收到）"
}

if [ "${1:-run}" = "--selftest" ]; then
  # v2.1h：selftest 也走单实例锁——防与 RunAtLoad 首轮并发（sput 非原子 RMW 会互相覆盖丢键）
  mkdir -p "$DIR" 2>/dev/null
  LOCK="$DIR/.lock"
  if ! mkdir "$LOCK" 2>/dev/null; then
    _lp=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$_lp" ] && kill -0 "$_lp" 2>/dev/null; then
      echo "另一实例巡检中（pid $_lp），跳过自检避免并发写状态，稍后重试"; exit 0
    fi
    rm -rf "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || { echo "锁竞争，稍后重试"; exit 0; }
  fi
  echo "$$" > "$LOCK/pid" 2>/dev/null
  trap 'if [ -f "$LOCK/pid" ] && [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ]; then rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null; fi' EXIT
  selftest
  exit 0
fi

# ---------- 单实例锁（仅 run 模式；macOS 无 flock，用 mkdir 原子性） ----------
mkdir -p "$DIR" 2>/dev/null
LOCK="$DIR/.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  # v1.28：抢锁前先验活——锁内 pid 进程仍活着则绝不抢（防误杀长巡检实例，30 分钟阈值
  # 在平台慢响应叠加时可能不足）；pid 已死或锁残留 >30 分钟才清理重试。
  _lp=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$_lp" ] && kill -0 "$_lp" 2>/dev/null; then
    exit 0
  fi
  # v2.1h：pid 已死（SIGKILL/强杀，trap 未跑）→ 立即回收；pid 不可读才用 30 分钟窗口兜底
  if [ -n "$_lp" ] && ! kill -0 "$_lp" 2>/dev/null; then
    log "lock: 陈旧锁（pid $_lp 已死）立即回收"
    rm -rf "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || exit 0
  elif [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    log "lock: pid 不可读且锁残留 >30 分钟，清理"
    rm -rf "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
# v1.17：锁内写 pid 文件——EXIT trap 只删自己创建的锁（防睡眠>30min 后旧实例醒来误删新实例锁 → 双实例风暴）
echo "$$" > "$LOCK/pid" 2>/dev/null
trap 'if [ -f "$LOCK/pid" ] && [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ]; then rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null; fi' EXIT

# ---------- v2.2：哨兵入口（到期停服态；launchd: com.zopguard.sentry） ----------
if [ "${1:-run}" = "--sentry-check" ]; then
  sentry_run
  exit $?
fi

check_and_repair
