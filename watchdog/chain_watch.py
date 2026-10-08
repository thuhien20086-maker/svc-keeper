#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# chain_watch.py —— 打款钱包监控(观察台版 v1.0，2026-10-08)
# 从笔记本版移植：逻辑原样，仅两处适配——
#   ① 路径 → ~/zg-watchdog/{state,logs}；群 hook/客户路由 → config.json
#   ② 私聊 → 飞书应用直发（原为 lark-cli）
# 打款钱包监控(BSC):热钱包A + 中转钱包B + 客户收款地址 的 USDC 进出
# tick:扫上次检查以来的新区块 → 有事件→推飞书私聊+群;无事件→静默(空输出)
# 用法: python3 chain_watch.py [--announce|--selftest|--status|--force-once]
import os, sys, json, datetime, time, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import zgwatch_common as C

os.environ.pop("PYTHONPATH", None)  # venv 污染防护

STATE_F = os.path.join(C.STATE_DIR, '.chain_watch_state.json')

USDC = "0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d"
XFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
A = "0xc75b15c638d3bbc7f673ee400e8eb9d90515a331"   # 平台热钱包
B = "0xa037c2b473a3fd2a7394b6c2c0a17f1abdd76a8d"   # 中转(一次性)钱包
USER = "0xf703aec39b43660ad1c62be902a13d5f8d702aae"  # 龙哥的币安充值地址
# v2：客户收款钱包监控（客户名 -> 提现地址，小写归一比较；任何来源打款进客户地址都提醒）
CUSTOMERS = {"长沙曾总": "0x311e2b3fb5f69ee73b733961449651374e2f0a86",
             "湖南钟总": "0x0840e25f63b062c2b9386e0f192495562467fed4"}
DUST = 1.0          # 热钱包A 到账低于 1 USDC 视为灰尘,不提醒
MAX_SPAN = 400000   # 单次最多补扫区块数(约50小时),超长缺口才截断;内部按 50k 分块请求

RPCS = [
    "https://bsc-mainnet.nodereal.io/v1/64a9df0874fb4a93b9d0a3849de012d3",
    "https://bsc-dataseed.binance.org",
    "https://bsc.publicnode.com",
    "https://rpc.48.club",
    "https://bsc.rpc.blxrbdn.com",
]
PROXY = "http://127.0.0.1:7897"


def log(msg):
    C.log('chain_watch', msg)


def _post(url, payload, proxy=None, t=12):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    if proxy:
        op = urllib.request.build_opener(urllib.request.ProxyHandler({"https": proxy, "http": proxy}))
        r = op.open(req, timeout=t)
    else:
        r = urllib.request.urlopen(req, timeout=t)
    return json.loads(r.read().decode())


class Rpc(object):
    def __init__(self, state):
        self.state = state
        self.best = (state.get("rpc") or [RPCS[0], False]) if state else [RPCS[0], False]

    def logs(self, address, lo, hi, topics):
        """getLogs 自动分块;端点限 5k 时自动缩小步长"""
        out, step, h = [], 49999, hi
        while h >= lo:
            clo = max(lo, h - step + 1)
            while True:
                try:
                    res = self.call("eth_getLogs", [{"address": address, "fromBlock": hex(clo),
                                                     "toBlock": hex(h), "topics": topics}])
                    break
                except RuntimeError as e:
                    if step > 4999 and "block range" in str(e):
                        step = 4999
                        clo = max(lo, h - step + 1)
                        continue
                    raise
            out += res
            h = clo - 1
        return out

    def call(self, method, params):
        cands = [(self.best[0], self.best[1])]
        for u in RPCS:
            cands.append((u, False))
            cands.append((u, True))
        last = None
        for url, prox in cands:
            for proxy in ([PROXY] if prox else [None]):
                try:
                    out = _post(url, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, proxy)
                    if "result" in out:
                        self.best = [url, prox]
                        return out["result"]
                    last = out.get("error")
                except Exception as e:
                    last = e
        raise RuntimeError("all RPC failed: %s" % last)


def topic(a):
    return "0x" + "0" * 24 + a[2:].lower()


def short(a):
    return a[:6] + "…" + a[-4:]


def evs_from_logs(logs, inflag):
    out = []
    for lg in logs:
        frm = "0x" + lg["topics"][1][-40:].lower()
        to = "0x" + lg["topics"][2][-40:].lower()
        amt = int(lg["data"], 16) / 1e18
        out.append({"in": inflag, "from": frm, "to": to, "amt": amt,
                    "tx": lg["transactionHash"]})
    return out


def compose(transfers, bnb_b_delta, batch_cool=False):
    evs, act = [], False
    dust = 0
    for t in transfers:
        amt, frm, to = t["amt"], t["from"], t["to"]
        # v2：客户收款监控——任何来源打款进客户提现地址都提醒（含平台批量放款）
        for cname, caddr in CUSTOMERS.items():
            if t["in"] and to == caddr.lower() and amt >= 0.1:
                evs.append(u"👤 客户%s 到账 +%s USDC(来自 %s)" % (cname, fmt(amt), short(frm))); act = True
        # 兜底锚点：任何地址直接给你的币安地址打 USDC 都提醒
        if t["in"] and to == USER and amt >= DUST:
            evs.append(u"💎 直接到账你的币安地址 +%s USDC(来自 %s)" % (fmt(amt), short(frm))); act = True
        if t["in"] and to == A:
            if amt >= DUST:
                evs.append(u"💰 热钱包A 到账 +%s USDC(来自 %s)" % (fmt(amt), short(frm))); act = True
            else:
                dust += 1
        elif t["in"] and to == B:
            evs.append(u"🔔 中转钱包B 到账 +%s USDC(来自 %s)" % (fmt(amt), short(frm))); act = True
        elif not t["in"] and frm == A:
            if to == USER:
                evs.append(u"🎉 热钱包A 给你打款 %s USDC!" % fmt(amt))
            elif to == B:
                evs.append(u"🔔 热钱包A 给中转B 备款 %s USDC(可能要给你打款)" % fmt(amt)); act = True
        elif not t["in"] and frm == B:
            if to == USER:
                evs.append(u"🎉 中转B 给你转出 %s USDC,快去币安看看到账没" % fmt(amt))
            else:
                evs.append(u"➡️ 中转B 转出 %s USDC → %s" % (fmt(amt), short(to)))
    others = [t for t in transfers if not t["in"] and t["from"] == A and t["to"] not in (USER, B)]
    batch = False
    if len(others) >= 3 and not batch_cool:
        ssum = sum(t["amt"] for t in others)
        evs.append(u"🚀 热钱包A 批量打款启动:%d 笔 / 合计 %s USDC(放款通道开了)" % (len(others), fmt(ssum)))
        batch = True
    if bnb_b_delta > 0.0005:
        evs.append(u"⛽ 中转B 收到 gas 充值(+%.6f BNB)" % bnb_b_delta)
    if dust:
        log("A 收到 %d 笔灰尘转账(已过滤)" % dust)
    return evs, act, batch


def fmt(x):
    return ("%.2f" % x).rstrip("0").rstrip(".") if 0 < x < 1 else "{:,.2f}".format(x)


def push_lark(msg):
    """群优先（按路由分流）；群发送失败才私聊兜底（防刷屏又防丢）。"""
    if push_group(msg):
        return True
    return C.dm(msg)


def push_group(msg):
    """多客户路由：「👤 客户X」行 → X 自己的群（若与兜底群不同）；其余行 → 兜底群。"""
    env = (C.conf().get('env') or {}).get('CHAIN_WATCH_GROUP_HOOK', '')
    cust = {c: h for c, h in C.cust_hooks().items() if h and h != env}
    lines = msg.split("\n")
    matched = set()
    ok = True
    sent = False
    for cname, hook in cust.items():
        mine = [l for l in lines if l.startswith(u"👤") and (u"客户%s" % cname) in l]
        if mine:
            matched.update(mine)
            sent = True
            ok = C.send_hook(hook, "\n".join(mine + [u"（客户收款监控 · 自动提醒）[ZopToken] [zopguard]"])) and ok
    rest = [l for l in lines if l not in matched]
    if any(l.strip() for l in rest):
        sent = True
        ok = C.send_hook(env, "\n".join(rest)) and ok
    return ok and sent


def load_state():
    try:
        with open(STATE_F, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_state(st):
    os.makedirs(C.STATE_DIR, exist_ok=True)
    tmp = STATE_F + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(st, f)
    os.replace(tmp, STATE_F)


def bnb_of(rpc, a):
    return int(rpc.call("eth_getBalance", [a, "latest"]), 16) / 1e18


def usdc_of(rpc, a):
    r = rpc.call("eth_call", [{"to": USDC, "data": "0x70a08231" + "0" * 24 + a[2:].lower()}, "latest"])
    return int(r, 16) / 1e18 if r and r != "0x" else 0.0


def selftest():
    ts = [
        {"in": True, "from": "0x" + "1" * 40, "to": A, "amt": 500.0, "tx": "0xa"},
        {"in": True, "from": "0x" + "2" * 40, "to": A, "amt": 0.0001, "tx": "0xb"},
        {"in": True, "from": A, "to": B, "amt": 7.5, "tx": "0xc"},
        {"in": False, "from": A, "to": USER, "amt": 49.7, "tx": "0xd"},
        {"in": False, "from": B, "to": USER, "amt": 9.94, "tx": "0xe"},
    ]
    evs, act, _b = compose(ts, 0.001)
    joined = "\n".join(evs)
    assert any(u"到账" in e and "500" in e for e in evs), joined
    assert "0.0001" not in joined, joined
    assert any(u"给你打款" in e for e in evs), joined
    assert any(u"给你转出" in e for e in evs), joined
    assert act, "有到账事件应建议提现"
    evs2, act2, _b2 = compose([{"in": True, "from": "0x" + "3" * 40, "to": A, "amt": 0.3, "tx": "0xf"}], 0.0)
    evs3, act3, b3 = compose([{"in": False, "from": A, "to": "0x" + "9" * 40, "amt": 30.0, "tx": "0xg%d" % i} for i in range(4)], 0.0)
    assert sum(u"批量打款" in e for e in evs3) == 1 and b3, evs3
    evs4, _, b4 = compose([{"in": False, "from": A, "to": "0x" + "9" * 40, "amt": 30.0, "tx": "0xh%d" % i} for i in range(4)], 0.0, True)
    assert not b4, "冷却期内不重复报警"
    assert not evs2 and not act2, "灰尘不应产生消息"
    print("selftest ok")


def main():
    if not C.claim('chain_watch'):
        print('SKIP: previous run still active')
        return
    if "--selftest" in sys.argv:
        selftest(); return
    if "--announce" in sys.argv:
        msg = (u"✅ 打款钱包监控已上线(每3分钟自动检查)\n"
               u"对象:热钱包A %s + 中转钱包B %s\n"
               u"触发:A 到账≥1 USDC / A 给你打款 / A 给 B 备款 / B 任何动静 / B 收 gas / 客户地址到账\n"
               u"要停掉或改条件,回 Hermes 说一声即可。" % (short(A), short(B)))
        if not push_lark(msg):
            print(msg)
        return

    if "--status" in sys.argv:
        rpc = Rpc({})
        ua, ba = usdc_of(rpc, A), bnb_of(rpc, A)
        ub, bb = usdc_of(rpc, B), bnb_of(rpc, B)
        msg = (u"\U0001F4E1 打款钱包监控 · 运行中\n"
               u"A 余额:%s USDC / %.4f BNB\nB 余额:%s USDC / %.6f BNB\n"
               u"(每3分钟自动检查;到账/打款/放款批次会秒推)" % (fmt(ua), ba, fmt(ub), bb))
        if not push_lark(msg):
            print(msg)
        return

    st = load_state()
    try:
        rpc = Rpc(st)
        latest = int(rpc.call("eth_blockNumber", []), 16)
        usdc_b = usdc_of(rpc, B); bnb_b = bnb_of(rpc, B)
        usdc_a = usdc_of(rpc, A); bnb_a = bnb_of(rpc, A)

        if not st.get("last_block"):
            st = {"last_block": latest, "usdc_b": usdc_b, "bnb_b": bnb_b, "seen": [], "fails": 0,
                  "rpc": rpc.best}
            save_state(st)
            log("baseline set at block %d; A=%s USDC/%s BNB  B=%s USDC/%s BNB" %
                (latest, usdc_a, bnb_a, usdc_b, bnb_b))
            return

        lo = st["last_block"] + 1
        if latest - lo > MAX_SPAN:
            log("gap too big (%d blocks), clamp" % (latest - lo))
            lo = latest - MAX_SPAN

        seen = set(st.get("seen") or [])
        transfers = []
        for addr, inflag in ((A, True), (B, True), (A, False), (B, False)) + tuple((c, True) for c in CUSTOMERS.values()):
            topics = [XFER, None, topic(addr)] if inflag else [XFER, topic(addr)]
            for t in evs_from_logs(rpc.logs(USDC, lo, latest, topics), inflag):
                if t["tx"] not in seen:
                    transfers.append(t)

        batch_cool = (time.time() - st.get("last_batch_alert", 0)) < 1800
        evs, act, batch_fired = compose(transfers, bnb_b - st.get("bnb_b", bnb_b), batch_cool)

        if evs:
            msg = (u"💰 打款钱包有动静\n" + "\n".join(evs) +
                   u"\n\nA 余额:%s USDC / %.4f BNB\nB 余额:%s USDC / %.6f BNB" %
                   (fmt(usdc_a), bnb_a, fmt(usdc_b), bnb_b))
            if act:
                msg += u"\n→ 有钱了,抓紧去平台发起提现"
            if not push_lark(msg):
                print(msg)  # 飞书失败 → stdout 兜底
            log("alert: " + " | ".join(evs))

        nseen = list(seen.union(t["tx"] for t in transfers))[-500:]
        prev_fails = int(st.get("fails") or 0)
        st.update({"last_block": latest, "usdc_b": usdc_b, "bnb_b": bnb_b,
                   "seen": nseen, "fails": 0, "rpc": rpc.best})
        if batch_fired:
            st["last_batch_alert"] = time.time()
        now = datetime.datetime.now()
        if prev_fails >= 10:
            push_lark(u"\u2705 打款钱包监控网络已恢复(之前中断 %d 次,现正常)" % prev_fails)
        if now.hour == 21 and st.get("hb_date") != now.strftime("%Y-%m-%d"):
            hb = (u"\U0001F4E1 打款钱包监控日报(运行正常)\n"
                  u"A 余额:%s USDC / %.4f BNB\nB 余额:%s USDC / %.6f BNB\n"
                  u"有到账/打款/放款批次会第一时间提醒" % (fmt(usdc_a), bnb_a, fmt(usdc_b), bnb_b))
            if push_lark(hb):
                st["hb_date"] = now.strftime("%Y-%m-%d")
        save_state(st)
    except Exception as e:
        st["fails"] = int(st.get("fails") or 0) + 1
        save_state(st)
        log("tick fail #%d: %s" % (st["fails"], e))
        if st["fails"] in (10, 20) or st["fails"] % 40 == 0:
            m = u"⚠️ 打款钱包监控网络异常已连续 %d 次,正在自动重试(可能是梯子节点问题)" % st["fails"]
            if not push_lark(m):
                print(m)


if __name__ == "__main__":
    main()
