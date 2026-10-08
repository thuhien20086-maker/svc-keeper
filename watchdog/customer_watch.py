#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# customer_watch.py —— 客户机中心观察器 + 中心兜底（观察台版 v1.0，2026-10-08）
# 从笔记本版 zg_customer_watch.py v2.2 移植：逻辑原样，仅三处适配——
#   ① 路径 → ~/zg-watchdog/{state,logs}；配置 → ~/zg-watchdog/config.json（含客户台账/飞书凭据）
#   ② 私聊通知 → 飞书应用直发（原为 stdout 交 Hermes 投递）
#   ③ 掉线「退出重开」下发 → 直写命令通道（GitHub API），不再依赖笔记本看板 :8757
# 每 tick（3 分钟）拉所有客户的设备组列表，对比上轮：
#   消失 = 掉线/被平台隐藏 → 发客户群 + 私聊告警 → ①「退出重开」×3（间隔 ≥8 分钟）→ ②中心兜底 device/init
#   idle 设备保活（25 分钟/台，只碰 idle 不碰 working）
# 用法: python3 customer_watch.py [--dry]    # --dry 彩排：不发任何请求
import json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import zgwatch_common as C

STATE_F = os.path.join(C.STATE_DIR, '.customer_watch_state.json')
SNMAP_F = os.path.join(C.STATE_DIR, '.customer_watch_sn.json')
RESTART_RC_F = os.path.join(C.STATE_DIR, '.customer_restart_rc.json')
CD_F = os.path.join(C.STATE_DIR, '.customer_relogin_cd.json')
SC_F = os.path.join(C.STATE_DIR, '.customer_relogin_sc.json')
KA_F = os.path.join(C.STATE_DIR, '.customer_keepalive.json')
API = 'https://www.zoptoken.com/api/console/device_group/devices'
KEYLOGIN_URL = 'https://www.zoptoken.com/api/user/keyLogin'
DEVINIT_URL = 'https://www.zoptoken.com/api/device/init'
RELOGIN_COOL = 3600           # 每台兜底冷却（秒）
RELOGIN_MAX_PER_DAY = 3       # 达到时仅插播「频繁掉线」提示，不暂停
RESTART_MAX = 3               # 「退出重开」最大下发次数
RESTART_INT = 8 * 60          # 两次下发最小间隔（秒）
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


def drop_handle(cname, info, dn, sn_map, cd, sc, rc, now, today):
    """掉线处理链：①「退出重开」×3（间隔 8 分钟）→ ②其他兜底 center_fix(device/init)。"""
    out = []
    rc_today = [t for t in rc.get(dn, []) if time.strftime('%F', time.localtime(t)) == today]
    if len(rc_today) < RESTART_MAX:
        if now - (rc.get(dn) or [0])[-1] >= RESTART_INT:
            if DRY:
                rc.setdefault(dn, []).append(now)
                out.append('（DRY）将对 %s 下发远程「退出重开」（第 %d/%d 次）' % (dn, len(rc_today) + 1, RESTART_MAX))
            elif send_restart(dn):
                rc.setdefault(dn, []).append(now)
                out.append('🔧 [%s] %s 掉线：已下发远程「退出重开」（第 %d/%d 次），等待上线…'
                           % (cname, dn, len(rc_today) + 1, RESTART_MAX))
            else:
                out.append('🔧 [%s] %s 掉线：远程「退出重开」下发失败（命令通道未响应），下轮自动重试。' % (cname, dn))
        return out  # 距上次下发不足 8 分钟：静默等待
    return center_fix(cname, info, dn, sn_map, cd, sc, now, today)


def center_fix(cname, info, dn, sn_map, cd, sc, now, today):
    """单台设备的中心兜底重登（device/init）；返回要通知的文本列表（冷却中返回空=静默）。"""
    out = []
    key = info.get('key') or ''
    succ_today = [t for t in sc.get(dn, []) if time.strftime('%F', time.localtime(t)) == today]
    if now - cd.get(dn, 0) < RELOGIN_COOL:
        return out  # 冷却中：静默（不刷群）
    meta = sn_map.get(dn) or {}
    sn = meta.get('sn')
    if not key or not sn:
        out.append('🔧 [%s] %s 掉线：中心兜底不可用（%s），由机器端守护继续自动恢复。'
                   % (cname, dn, '无KEY' if not key else '无sn记录（首次快照后自动获得）'))
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
        out.append('🔧 [%s] %s 掉线：中心兜底重登失败（登录换取 token 未成功），等机器端守护。' % (cname, dn))
        return out
    try:
        rr = _post(DEVINIT_URL, {'sn': sn, 'name': dn, 'cpu': meta.get('cpu') or 'Apple Silicon'}, utok)
        ok = rr.get('code') == 1
    except Exception as e:
        ok = False
        log('relogin device/init fail:', dn, e)
    if ok:
        sc.setdefault(dn, []).append(now)
        cd.pop(dn, None)
        out.append('🔧 [%s] %s 掉线：中心已下发兜底重登（device/init 成功），恢复中。' % (cname, dn))
        if len(succ_today) + 1 == RELOGIN_MAX_PER_DAY:
            out.append('ℹ️ [%s] %s 今日已中心恢复 %d 次（频繁掉线）：继续自动恢复；若长期反复，建议排查该机网络。'
                       % (cname, dn, len(succ_today) + 1))
        log('relogin ok:', dn)
    else:
        cd[dn] = now
        out.append('🔧 [%s] %s 掉线：中心兜底重登未成功（device/init 未通过），等机器端守护。' % (cname, dn))
    return out


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


def main():
    customers = (C.conf().get('customers') or {})
    state = _load(STATE_F)
    sn_map = _load(SNMAP_F)
    rc = _load(RESTART_RC_F)
    cd = _load(CD_F)
    sc = _load(SC_F)
    ka = _load(KA_F)
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
            lst = fetch(gid, token)
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
                msgs.append('⚠️ [%s] 机器 %s 掉线了（平台列表已消失），守护正在自动恢复…' % (name, dn))
                msgs += drop_handle(name, info, dn, sn_map, cd, sc, rc, now, today)
        # ②b 持续缺席也推进兜底链（动作自带节流；按 'cust' 归属过滤防串）
        for dn in list(sn_map):
            if (sn_map.get(dn) or {}).get('cust') == name and dn not in cur and dn not in prev:
                msgs += drop_handle(name, info, dn, sn_map, cd, sc, rc, now, today)
        # ③ 在线但 state 异常（非 working 才兜底）
        for dn, st in cur.items():
            if st != 'healthy' and str((full.get(dn) or {}).get('runtime_state') or '') != 'working':
                msgs.append('⚠️ [%s] 机器 %s 状态异常（%s），处理中…' % (name, dn, st))
                msgs += drop_handle(name, info, dn, sn_map, cd, sc, rc, now, today)
        # ④ 恢复报喜
        for dn in cur:
            if cur[dn] == 'healthy':
                rc.pop(dn, None)   # 上线即重置「退出重开」名额
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
    for f, d in ((STATE_F, new_state), (SNMAP_F, sn_map), (RESTART_RC_F, rc), (CD_F, cd), (SC_F, sc), (KA_F, ka)):
        _dump_atomic(f, d)
    if not msgs:
        print('NOOP')


if __name__ == '__main__':
    main()
