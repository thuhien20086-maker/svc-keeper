#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# zgwatch_common.py —— 观察台共用件 v1.0（2026-10-08）
# 配置、飞书私聊(DM)、客户群路由、命令通道(GitHub API 直写)、日志。
# 部署在常开机器 ~/zg-watchdog/ 下；ZG_WATCHDOG_DIR 可覆盖目录（测试用）。
import json, os, ssl, sys, time, base64, socket, urllib.request

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

DIR = os.environ.get('ZG_WATCHDOG_DIR') or os.path.expanduser('~/zg-watchdog')
CONF_F = os.path.join(DIR, 'config.json')
STATE_DIR = os.path.join(DIR, 'state')
LOG_DIR = os.path.join(DIR, 'logs')

_GH_REPO = 'thuhien20086-maker/svc-keeper'
_GH_FILE = 'cmd/reboot.txt'


def _proxy_alive():
    try:
        s = socket.socket()
        s.settimeout(0.4)
        ok = s.connect_ex(('127.0.0.1', 7897)) == 0
        s.close()
        return ok
    except Exception:
        return False


_PROXY = None


def _urlopen(req, timeout=20):
    """有本地代理（Clash 7897）就用代理优先，否则直连。"""
    global _PROXY
    if _PROXY is None:
        _PROXY = _proxy_alive()
    try:
        if _PROXY:
            px = urllib.request.ProxyHandler({'https': 'http://127.0.0.1:7897', 'http': 'http://127.0.0.1:7897'})
            opener = urllib.request.build_opener(px, urllib.request.HTTPSHandler(context=CTX))
            return opener.open(req, timeout=timeout)
        return urllib.request.urlopen(req, timeout=timeout, context=CTX)
    except Exception:
        return urllib.request.urlopen(req, timeout=timeout, context=CTX)


_conf_cache = {}


def conf():
    if not _conf_cache:
        with open(CONF_F, encoding='utf-8') as f:
            _conf_cache.update(json.load(f))
    return _conf_cache


def log(name, *a):
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        with open(os.path.join(LOG_DIR, name + '.log'), 'a', encoding='utf-8') as f:
            f.write('[%s] %s\n' % (time.strftime('%F %T'), ' '.join(str(x) for x in a)))
    except Exception:
        pass


# ---------- 飞书 ----------

_fs_tok = {'v': '', 'exp': 0}


def _feishu_token():
    """tenant_access_token，文件缓存 ~90 分钟。"""
    now = time.time()
    if _fs_tok['v'] and now < _fs_tok['exp']:
        return _fs_tok['v']
    cache_f = os.path.join(STATE_DIR, '.fs_token.json')
    try:
        d = json.load(open(cache_f, encoding='utf-8'))
        if d.get('v') and now < float(d.get('exp') or 0):
            _fs_tok.update(d)
            return _fs_tok['v']
    except Exception:
        pass
    env = conf().get('env') or {}
    body = json.dumps({'app_id': env.get('FEISHU_APP_ID', ''), 'app_secret': env.get('FEISHU_APP_SECRET', '')}).encode()
    req = urllib.request.Request('https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal',
                                 data=body, headers={'Content-Type': 'application/json'})
    d = json.loads(_urlopen(req, 20).read().decode())
    tok = d.get('tenant_access_token') or ''
    if tok:
        _fs_tok.update({'v': tok, 'exp': now + int(d.get('expire') or 3600) - 600})
        try:
            os.makedirs(STATE_DIR, exist_ok=True)
            with open(cache_f, 'w', encoding='utf-8') as f:
                json.dump(_fs_tok, f)
        except Exception:
            pass
    return tok


def dm(text):
    """私聊龙哥。失败返回 False（stdout 兜底由调用方处理）。"""
    try:
        tok = _feishu_token()
        if not tok:
            log('common', 'dm fail: 无 tenant_access_token')
            return False
        uid = (conf().get('env') or {}).get('LARK_USER') or 'ou_2c8343067d6cbc1f887a304f373731bf'
        req = urllib.request.Request(
            'https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=open_id',
            data=json.dumps({'receive_id': uid, 'msg_type': 'text',
                             'content': json.dumps({'text': text})}).encode(),
            headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + tok})
        d = json.loads(_urlopen(req, 20).read().decode())
        ok = d.get('code') == 0
        if not ok:
            log('common', 'dm fail: %s %s' % (d.get('code'), d.get('msg')))
        return ok
    except Exception as e:
        log('common', 'dm fail: %s' % e)
        return False


# ---------- 客户群（webhook 路由） ----------

_cust_hooks = {}


def cust_hooks():
    """客户名 → 客户群 webhook（读 config 的 customers）。"""
    if not _cust_hooks:
        for nm, inf in (conf().get('customers') or {}).items():
            hk = (inf.get('webhook') or '').strip()
            if hk:
                _cust_hooks[nm] = hk
    return _cust_hooks


def hook_for(text):
    """按消息里的 [客户名] 路由到各自群；条目 webhook 为空 = 只私聊不进群（如「自用机」）；
    完全无匹配才回退 env 兜底群（历史单群时代）。"""
    for nm, inf in (conf().get('customers') or {}).items():
        if ('[%s]' % nm) in text:
            return (inf.get('webhook') or '').strip()
    return (conf().get('env') or {}).get('CHAIN_WATCH_GROUP_HOOK', '')


def send_hook(hook, text):
    if not hook:
        return True
    if 'zopguard' not in text and 'ZopToken' not in text:
        text = text + '\n[zopguard]'
    try:
        req = urllib.request.Request(hook, data=json.dumps(
            {'msg_type': 'text', 'content': {'text': text}}).encode(),
            headers={'Content-Type': 'application/json'})
        r = json.loads(_urlopen(req, 12).read().decode())
        return r.get('code') == 0
    except Exception as e:
        log('common', 'group push fail: %s' % e)
        return False


def notify(text, dm_too=True):
    """客户群（按路由）+ 私聊。返回 (群ok, 私聊ok)。"""
    hook = hook_for(text)
    gok = send_hook(hook, text) if hook else True
    dok = dm(text) if dm_too else True
    log('common', 'notify:', text)
    return gok, dok


# ---------- 命令通道（GitHub contents API 直写 cmd/reboot.txt） ----------

def push_cmd(device, action):
    """向命令队列追加一行 <epoch>|<设备名>|<动作>（保留最近 50 行）。
    与看板 _push_cmd_file 等价，但走 GitHub API（机端无需 git）。"""
    tok = (conf().get('gh_token') or '').strip()
    if not tok:
        log('common', 'push_cmd fail: 无 gh_token')
        return False
    api = 'https://api.github.com/repos/%s/contents/%s' % (_GH_REPO, _GH_FILE)
    hdrs = {'Authorization': 'token ' + tok, 'User-Agent': 'zgwatch/1.0'}
    last = None
    for _ in range(3):
        try:
            r = json.loads(_urlopen(urllib.request.Request(api, headers=hdrs), 25).read().decode())
            sha = r.get('sha')
            content_b64 = (r.get('content') or '').replace('\n', '')
            lines = [l for l in base64.b64decode(content_b64).decode('utf-8').splitlines() if l.strip()]
            ts = int(time.time())
            lines.append('%d|%s|%s' % (ts, device, action))
            new_c = '\n'.join(lines[-50:]) + '\n'
            body = json.dumps({
                'message': 'cmd: %d|%s' % (ts, action),
                'content': base64.b64encode(new_c.encode('utf-8')).decode(),
                'sha': sha, 'branch': 'main'}).encode()
            req2 = urllib.request.Request(api, data=body, method='PUT',
                                          headers={'Authorization': 'token ' + tok,
                                                   'User-Agent': 'zgwatch/1.0',
                                                   'Content-Type': 'application/json'})
            rr = json.loads(_urlopen(req2, 25).read().decode())
            if (rr.get('content') or {}).get('sha'):
                log('common', 'push_cmd ok: %s|%s' % (device, action))
                return True
            last = rr
        except Exception as e:
            last = e
        time.sleep(2)
    log('common', 'push_cmd fail: %s' % last)
    return False


_self_test_failed = None


def selftest():
    """最小自检：配置可读、关键键齐全（不发任何网络请求）。"""
    c = conf()
    errs = []
    if not (c.get('customers')):
        errs.append('无 customers')
    if not (c.get('env') or {}).get('FEISHU_APP_ID'):
        errs.append('无 FEISHU_APP_ID')
    if not c.get('gh_token'):
        errs.append('无 gh_token')
    print('selftest', 'ok' if not errs else ('FAIL: ' + '; '.join(errs)))
    return not errs


if __name__ == '__main__':
    sys.exit(0 if selftest() else 1)
