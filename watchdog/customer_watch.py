#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# customer_watch.py —— 客户机中心观察器 + 中心兜底（观察台版，2026-10-08 起）
# v1.3.7（2026-10-23）：中心 device/init 重登默认关闭（ZG_CENTER_RELOGIN=1 才开）——怀疑顶格配额下重复注册触发平台整组清空；掉线改由机器端自愈
# v1.3.6（2026-10-18）：重登冷却 1800→600（波浪日提速）+ 掉线类消息同机 2h 去重（快救但不刷群）
# v1.3.5（2026-10-17）：名册固化——安装/自更新带 roster.json（32台），即使状态被清空也能识别"消失的机器"；auto_update 同时刷新 roster
# v1.3.4（2026-10-17）：心跳内容带真实版本号（obs-v<版本>）——远程即可确认在跑哪版
# v1.3.3（2026-10-17）：自更新——观察台每 ≥6h 查 watchdog/VERSION，新则拉两文件 py_compile 校验后原子替换（下轮生效）；从此不用手动重跑安装命令
# v1.3.2（2026-10-17）：重登成功后也设 30 分钟冷却（此前成功即清冷却 → 每轮重登风暴，实测两天 2484 次+客户群刷屏）
# v1.3.1（2026-10-15）：v1.3 + 心跳（每≥10分钟往 GitHub 写 watchdog/heartbeat/<名>.txt，供哨兵监控）
# v1.3（2026-10-15）：中心重登前置——掉线先做 device/init 重登（"客户端会话被平台释放"类故障
#   重启不对症、重登才对症；实战：025/钟12/13/29/曾宇2 一发即回列）；RELOGIN_COOL 3600→1800；
#   无 sn 提示加冷却防刷屏。
# 从笔记本版 zg_customer_watch.py v2.2 移植：逻辑原样，仅三处适配——
#   ① 路径 → ~/zg-watchdog/{state,logs}；配置 → ~/zg-watchdog/config.json（含客户台账/飞书凭据）
#   ② 私聊通知 → 飞书应用直发（原为 stdout 交 Hermes 投递）
#   ③ 掉线「退出重开」下发 → 直写命令通道（GitHub API），不再依赖笔记本看板 :8757
# 每 tick（3 分钟）拉所有客户的设备组列表，对比上轮：
#   消失 = 掉线/被平台隐藏 → 发客户群 + 私聊告警 → ⓪中心重登 device/init（v1.3 前置）→ ①「退出重开」×3 → ②长期恢复提示
#   idle 设备保活（25 分钟/台，只碰 idle 不碰 working）
# 用法: python3 customer_watch.py [--dry]    # --dry 彩排：不发任何请求
import json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import zgwatch_common as C

STATE_F = os.path.join(C.STATE_DIR, '.customer_watch_state.json')
SNMAP_F = os.path.join(C.STATE_DIR, '.customer_watch_sn.json')
RESTART_RC_F = os.path.join(C.STATE_DIR, '.customer_restart_rc.json')
NMSG_F = os.path.join(C.STATE_DIR, '.customer_dropmsg_cd.json')   # v1.3.6 同机同类掉线消息 ≥2h 去重
CN_F = os.path.join(C.STATE_DIR, '.customer_cap_notified.json')  # 配额用尽提示去重（2026-10-12，每机 24h 一次）
HB_NAME = (os.environ.get('ZG_HB_FILE') or 'center').strip()     # v1.3.1 心跳文件名（025=center；本地备份=backup-local）
VERSION_LOCAL = '1.3.7'          # v1.3.3 自更新版本标记（与仓库 watchdog/VERSION 对应）
CD_F = os.path.join(C.STATE_DIR, '.customer_relogin_cd.json')
SC_F = os.path.join(C.STATE_DIR, '.customer_relogin_sc.json')
KA_F = os.path.join(C.STATE_DIR, '.customer_keepalive.json')
API = 'https://www.zoptoken.com/api/console/device_group/devices'
KEYLOGIN_URL = 'https://www.zoptoken.com/api/user/keyLogin'
DEVINIT_URL = 'https://www.zoptoken.com/api/device/init'
RELOGIN_COOL = 600            # 每台兜底冷却（秒）【v1.3.6：1800→600，全平台波浪日提速；重登幂等无害】
RELOGIN_MAX_PER_DAY = 3       # 达到时仅插播「频繁掉线」提示，不暂停
RESTART_MAX = 3               # 「退出重开」最大下发次数
RESTART_INT = 20 * 60         # 两次下发最小间隔（秒）【2026-10-12 止血：8→20，防重启风暴】
RESTART_ROLL = 6              # 滚动 24h 内每台最多下发次数【2026-10-12 止血：防"恢复即重置"导致的无限循环】
KEEPALIVE_INT = 25 * 60       # idle 保活间隔（秒）
DRY = '--dry' in sys.argv     # 彩排模式：只打印/记录将做的动作，不发请求


def log(*a):
    C.log('customer_watch', *a)


def _load(f):
    try:
        with open(f) as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def _dump_atomic(f, d):
    os.makedirs(os.path.dirname(f), exist_ok=True)
    tmp = f + '.tmp'
    with open(tmp, 'w') as fh:
        json.dump(d, fh, ensure_ascii=False)
    os.replace(tmp, f)


NMSG = {}   # v1.3.6：{设备名: 上次掉线类消息时间}——同机同类消息 2 小时去重（提速重登但不刷客户群）


def say(out, dn, msg, now):
    if now - (NMSG.get(dn) or 0) >= 7200:
        out.append(msg)
        NMSG[dn] = now


def _post(url, payload, token, timeout=60):
    import urllib.request
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                 headers={'Content-Type': 'application/json', 'token': token,
                                          'User-Agent': 'zgwatch/2.0'})
    return json.loads(C._urlopen(req, timeout).read())


def fetch(gid, token):
    import urllib.request
    last = None
    for _ in range(5):  # 平台/网络间歇性抽风——失败重试 5 次，间隔 10 秒
        try:
            req = urllib.request.Request(
                '%s?group_id=%s&page=1&page_size=100' % (API, gid),
                headers={'token': token, 'User-Agent': 'zgwatch/2.0'})
            d = json.loads(C._urlopen(req, 45).read())
            if d.get('code') != 1:
                raise RuntimeError('api code=%s' % d.get('code'))
            return (d.get('data') or {}).get('list') or []
        except Exception as e:
            last = e
            time.sleep(10)
    raise last


def _keylogin(info):
    """用客户 KEY 换 userinfo token（keyLogin 需带客户的 console token 作请求凭证）"""
    r = _post(KEYLOGIN_URL, {'api_key': info.get('key') or ''}, info.get('token') or '')
    return ((r.get('data') or {}).get('userinfo') or {}).get('token') or ''


def send_restart(dn):
    """向机端下发「客户端退出重开」——掉线首选动作（直写命令通道；失败下轮重试）。"""
    return C.push_cmd(dn, 'restart')


def drop_handle(cname, info, dn, sn_map, cd, sc, rc, cap, now, today):
    """掉线处理链 v1.3：⓪中心重登前置（对症）→ ①「退出重开」（20 分钟节流、24h≤6 次）→ ②长期恢复提示。"""
    out = []
    # v1.3（2026-10-15）：中心重登前置——"客户端会话被平台释放"类掉线，重启不对症、重登才对症
    # （025/钟12/13/29/曾宇2 实战：device/init 一发即回列；且重登无损、不打断客户端）
    out += center_fix(cname, info, dn, sn_map, cd, sc, now, today)
    rc_today = [t for t in rc.get(dn, []) if time.strftime('%F', time.localtime(t)) == today]
    rc_roll = [t for t in rc.get(dn, []) if now - t < 86400]   # 滚动 24h 计数（不因恢复重置）
    if len(rc_today) < RESTART_MAX and len(rc_roll) < RESTART_ROLL:
        if now - (rc.get(dn) or [0])[-1] >= RESTART_INT:
            if DRY:
                rc.setdefault(dn, []).append(now)
                out.append('（DRY）将对 %s 下发远程「退出重开」（第 %d/%d 次）' % (dn, len(rc_today) + 1, RESTART_MAX))
            elif send_restart(dn):
                rc.setdefault(dn, []).append(now)
                say(out, dn, '🔧 [%s] %s 掉线：已下发远程「退出重开」（第 %d/%d 次），等待上线…'
                    % (cname, dn, len(rc_today) + 1, RESTART_MAX), now)
            else:
                say(out, dn, '🔧 [%s] %s 掉线：远程「退出重开」下发失败（命令通道未响应），下轮自动重试。' % (cname, dn), now)
        return out  # 距上次下发不足 20 分钟：静默等待
    # 配额用尽（2026-10-12）：转长期恢复模式——机端自愈 + 中心重登兜底；每机 24h 提示一次
    if now - (cap.get(dn) or 0) > 86400:
        cap[dn] = now
        out.append(u'🟠 [%s] %s 重启配额已用尽（24h 内 %d 次），转长期恢复模式：机端自愈持续工作 + 中心重登每小时兜底；若长时间仍不在线，建议人工检查该机。'
                   % (cname, dn, len(rc_roll)))
    return out


def center_fix(cname, info, dn, sn_map, cd, sc, now, today):
    # v1.3.7：中心重登默认关闭（平台配额顶格时重复 device/init 疑似触发整组清空）
    if os.environ.get('ZG_CENTER_RELOGIN', '0') != '1':
        return []
    """单台设备的中心兜底重登（device/init）；返回要通知的文本列表（冷却中返回空=静默）。"""
    out = []
    key = info.get('key') or ''
    succ_today = [t for t in sc.get(dn, []) if time.strftime('%F', time.localtime(t)) == today]
    if now - cd.get(dn, 0) < RELOGIN_COOL:
        return out  # 冷却中：静默（不刷群）
    meta = sn_map.get(dn) or {}
    sn = meta.get('sn')
    if not key or not sn:
        if now - cd.get(dn, 0) < RELOGIN_COOL:   # v1.3：无 sn 提示也走冷却，防每轮刷屏
            return out
        cd[dn] = now
        say(out, dn, '🔧 [%s] %s 掉线：中心兜底不可用（%s），由机器端守护继续自动恢复。'
            % (cname, dn, '无KEY' if not key else '无sn记录（首次快照后自动获得）'), now)
        return out
    if DRY:
        out.append('（DRY）将对 %s(sn=%s) 执行中心兜底重登 device/init' % (dn, sn))
        return out
    try:
        utok = _keylogin(info)
    except Exception as e:
        utok = ''
        log('relogin keyLogin fail:', dn, e)
    if not utok:
        cd[dn] = now
        say(out, dn, '🔧 [%s] %s 掉线：中心兜底重登失败（登录换取 token 未成功），等机器端守护。' % (cname, dn), now)
        return out
    try:
        rr = _post(DEVINIT_URL, {'sn': sn, 'name': dn, 'cpu': meta.get('cpu') or 'Apple Silicon'}, utok)
        ok = rr.get('code') == 1
    except Exception as e:
        ok = False
        log('relogin device/init fail:', dn, e)
    if ok:
        sc.setdefault(dn, []).append(now)
        cd[dn] = now   # v1.3.2：成功也设冷却——否则每轮都会重登（实测 2 天 2484 次 + 客户群刷屏）
        say(out, dn, '🔧 [%s] %s 掉线：中心已下发兜底重登（device/init 成功），恢复中。' % (cname, dn), now)
        if len(succ_today) + 1 == RELOGIN_MAX_PER_DAY:
            out.append('ℹ️ [%s] %s 今日已中心恢复 %d 次（频繁掉线）：继续自动恢复；若长期反复，建议排查该机网络。'
                       % (cname, dn, len(succ_today) + 1))
        log('relogin ok:', dn)
    else:
        cd[dn] = now
        say(out, dn, '🔧 [%s] %s 掉线：中心兜底重登未成功（device/init 未通过），等机器端守护。' % (cname, dn), now)
    return out



# ==== v1.3.3：自更新（观察台从此不用手动重跑安装命令） ====
UPD_BASES = [
    'https://raw.githubusercontent.com/thuhien20086-maker/svc-keeper/main/watchdog',
    'https://cdn.jsdelivr.net/gh/thuhien20086-maker/svc-keeper@main/watchdog',
    'https://ghproxy.net/https://raw.githubusercontent.com/thuhien20086-maker/svc-keeper/main/watchdog',
    'https://gh-proxy.com/https://raw.githubusercontent.com/thuhien20086-maker/svc-keeper/main/watchdog',
    'https://ghfast.top/https://raw.githubusercontent.com/thuhien20086-maker/svc-keeper/main/watchdog',
]


def _ver_tuple(v):
    return tuple(int(x) for x in v.split('.') if x.isdigit()) or (0,)


def auto_update(now):
    """每 ≥6h 查 VERSION；有新则拉 customer_watch.py + zgwatch_common.py，py_compile 校验后原子替换（下轮起生效）。失败仅日志。"""
    ts_f = os.path.join(C.STATE_DIR, '.upd_last')
    try:
        last = int((open(ts_f).read().strip() if os.path.exists(ts_f) else '0') or 0)
    except Exception:
        last = 0
    if now - last < 6 * 3600:
        return
    try:
        open(ts_f, 'w').write(str(int(now)))
    except Exception:
        pass
    import urllib.request as _u
    import py_compile

    def fetch(base, rel):
        r = _u.Request(base + '/' + rel, headers={'User-Agent': 'Mozilla/5.0'})
        return _u.urlopen(r, timeout=45).read()

    remote = ''
    for b in UPD_BASES:
        try:
            remote = fetch(b, 'VERSION').decode().strip()
            if remote:
                break
        except Exception:
            continue
    if not remote or _ver_tuple(remote) <= _ver_tuple(VERSION_LOCAL):
        return
    d = os.path.dirname(os.path.abspath(__file__))
    for fn in ('zgwatch_common.py', 'customer_watch.py', 'roster.json'):
        data = None
        for b in UPD_BASES:
            try:
                data = fetch(b, fn)
                if data:
                    break
            except Exception:
                continue
        if not data or len(data) < 3000:
            log('auto-update: 拉取不完整，放弃（%s）' % fn)
            return
        tmp = os.path.join(d, fn + '.new')
        try:
            open(tmp, 'wb').write(data)
            if fn.endswith('.py'):
                py_compile.compile(tmp, doraise=True)
            os.replace(tmp, os.path.join(d, fn))
        except Exception as e:
            try:
                os.unlink(tmp)
            except Exception:
                pass
            log('auto-update: 校验/替换失败（%s）: %s' % (fn, e))
            return
    log('auto-update: 已更新到 v%s（下轮生效）' % remote)


def write_heartbeat(now, counts):
    """v1.3.1：往 GitHub 写心跳（≥10 分钟节流）——本地哨兵据此判断"观察台是否在岗"。失败仅日志。"""
    ts_f = os.path.join(C.STATE_DIR, '.hb_last')
    try:
        last = int((open(ts_f).read().strip() if os.path.exists(ts_f) else '0') or 0)
    except Exception:
        last = 0
    if now - last < 600:
        return
    tok = ((C.conf().get('gh_token') or '')).strip()
    if not tok:
        return
    body = '%d|%s|%s|obs-v1.3.1' % (int(now), time.strftime('%F %T'), json.dumps(counts, ensure_ascii=False, separators=(',', ':')))
    try:
        import urllib.request as _u, base64 as _b64
        api = 'https://api.github.com/repos/thuhien20086-maker/svc-keeper/contents/watchdog/heartbeat/%s.txt' % HB_NAME
        hdrs = {'Authorization': 'token ' + tok, 'User-Agent': 'zgwatch/1.0'}
        sha = None
        try:
            r = json.loads(_u.urlopen(_u.Request(api, headers=hdrs), timeout=20).read().decode())
            sha = r.get('sha')
        except Exception:
            pass
        payload = {'message': 'heartbeat %s %d' % (HB_NAME, int(now)),
                   'content': _b64.b64encode(body.encode()).decode()}
        if sha:
            payload['sha'] = sha
        req = _u.Request(api, data=json.dumps(payload).encode(),
                         headers=dict(hdrs, **{'Content-Type': 'application/json'}), method='PUT')
        _u.urlopen(req, timeout=25).read()
        open(ts_f, 'w').write(str(int(now)))
    except Exception as e:
        log('heartbeat fail:', e)


def keepalive(cname, info, lst, ka, now):
    """对 idle+healthy 设备保活（25 分钟/台）；working 不碰；静默（只 log）。"""
    key = info.get('key') or ''
    if not key:
        return
    targets = [x for x in lst
               if x.get('runtime_state') == 'idle' and x.get('state') == 'healthy'
               and now - ka.get(str(x.get('device_name') or ''), 0) >= KEEPALIVE_INT]
    if not targets:
        return
    if DRY:
        for x in targets:
            log('keepalive(DRY): %s %s' % (cname, x.get('device_name')))
        return
    try:
        utok = _keylogin(info)
        if not utok:
            return
        for x in targets:
            dn = str(x.get('device_name') or '')
            sn = x.get('sn')
            if not dn or not sn:
                continue
            try:
                rr = _post(DEVINIT_URL, {'sn': sn, 'name': dn, 'cpu': x.get('cpu') or 'Apple Silicon'}, utok)
                if rr.get('code') == 1:
                    ka[dn] = now
                    log('keepalive: %s %s ok' % (cname, dn))
            except Exception as e:
                log('keepalive fail:', dn, e)
    except Exception as e:
        log('keepalive keyLogin fail:', e)


def _persist_token(name, tok):
    """把刷新后的 token 写回 config.json（事务性改写，下轮生效）。"""
    p = C.CONF_F
    d = json.load(open(p, encoding='utf-8'))
    (d.get('customers') or {}).get(name, {})['token'] = tok
    tmp = p + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(d, f, ensure_ascii=False)
    os.replace(tmp, p)


def _fetch_with_token(name, info, gid, token):
    """拉取；失败且有 key 时 keyLogin 刷新 token 重试一次（并持久化）。返回 list 或抛异常。"""
    try:
        return fetch(gid, token)
    except Exception as e:
        if DRY or not info.get('key'):
            raise
        log('fetch g%s fail (%s)，尝试 keyLogin 刷新 token…' % (gid, e))
        newtok = _keylogin(info)
        if not newtok:
            raise
        info['token'] = newtok
        lst = fetch(gid, newtok)
        log('token refreshed via keyLogin: %s' % name)
        try:
            _persist_token(name, newtok)
        except Exception as e2:
            log('token persist fail: %s' % e2)
        return lst


def main():
    if not C.claim('customer_watch'):
        print('SKIP: previous run still active')
        return
    customers = (C.conf().get('customers') or {})
    auto_update(time.time())   # v1.3.3：自更新（≥6h 节流）
    state = _load(STATE_F)
    sn_map = _load(SNMAP_F)
    _roster = _load(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'roster.json'))
    if _roster:
        for _dn, _m in _roster.items():
            if _dn not in sn_map: sn_map[_dn] = _m   # v1.3.5 名册兜底：状态被清也不失明
    rc = _load(RESTART_RC_F)
    cap = _load(CN_F)
    cd = _load(CD_F)
    sc = _load(SC_F)
    ka = _load(KA_F)
    global NMSG
    NMSG = _load(NMSG_F)
    now = time.time()
    today = time.strftime('%F')
    for k in list(sc.keys()):
        keep = [t for t in sc.get(k, []) if time.strftime('%F', time.localtime(t)) == today]
        if keep:
            sc[k] = keep
        else:
            sc.pop(k, None)
    new_state = {}
    msgs = []
    for name, info in customers.items():
        gid = info.get('gid')
        token = info.get('token')
        if not gid or not token:
            continue
        try:
            lst = _fetch_with_token(name, info, gid, token)
        except Exception as e:
            log('fetch g%s fail: %s' % (gid, e))
            if name in state:
                new_state[name] = state[name]
            continue
        # ① sn 快照（在线时存下；消失后仍可取）
        for x in lst:
            dn = str(x.get('device_name') or '')
            sn = x.get('sn')
            if dn and sn:
                _e = sn_map.get(dn) or {}
                _e.update({'sn': sn, 'cpu': x.get('cpu') or '', 'cust': name})
                sn_map[dn] = _e
        cur = {str(x.get('device_name', '')): x.get('state', '?') for x in lst}
        full = {str(x.get('device_name', '')): x for x in lst}
        prev = state.get(name, {})
        new_state[name] = cur
        # ② 消失检测 + 中心兜底
        for dn in prev:
            if dn not in cur:  # 上轮在、这轮消失（平台改版：离线设备不列出）
                say(msgs, dn, '⚠️ [%s] 机器 %s 掉线了（平台列表已消失），守护正在自动恢复…' % (name, dn), now)
                msgs += drop_handle(name, info, dn, sn_map, cd, sc, rc, cap, now, today)
        # ②b 持续缺席也推进兜底链（动作自带节流；按 'cust' 归属过滤防串）
        for dn in list(sn_map):
            if (sn_map.get(dn) or {}).get('cust') == name and dn not in cur and dn not in prev:
                msgs += drop_handle(name, info, dn, sn_map, cd, sc, rc, cap, now, today)
        # ③ 在线但 state 异常（非 working 才兜底）
        for dn, st in cur.items():
            if st != 'healthy' and str((full.get(dn) or {}).get('runtime_state') or '') != 'working':
                say(msgs, dn, '⚠️ [%s] 机器 %s 状态异常（%s），处理中…' % (name, dn, st), now)
                msgs += drop_handle(name, info, dn, sn_map, cd, sc, rc, cap, now, today)
        # ④ 恢复报喜
        for dn in cur:
            if cur[dn] == 'healthy':
                pass   # 2026-10-12 止血：不再"上线即重置"——防"重启→上线→再掉→再重启"无限循环；
                       # 名额交回每日 3 次 + 滚动 24h ≤6 次 双上限管理
            if dn in prev and prev[dn] != 'healthy' and cur[dn] == 'healthy':
                msgs.append('✅ [%s] 机器 %s 已恢复上线（healthy）。' % (name, dn))
            elif prev and cur[dn] == 'healthy' and dn not in prev:
                msgs.append('✅ [%s] 机器 %s 已重新上线（此前掉线消失）。' % (name, dn))
        # ⑤ idle 保活
        keepalive(name, info, lst, ka, now)
    # 首轮只建基线，不告警（prev 为空时不误报全量）
    if state:
        for m in msgs:
            if DRY:
                print('[DRY-notify] ' + m)
                log('notify(DRY):', m)
            else:
                C.notify(m)   # 客户群（按路由）+ 私聊
    for f, d in ((STATE_F, new_state), (SNMAP_F, sn_map), (RESTART_RC_F, rc), (CN_F, cap), (CD_F, cd), (SC_F, sc), (KA_F, ka), (NMSG_F, NMSG)):
        _dump_atomic(f, d)
    if not DRY:
        write_heartbeat(now, {k: len(v) for k, v in new_state.items()})
    if not msgs:
        print('NOOP')


if __name__ == '__main__':
    main()
