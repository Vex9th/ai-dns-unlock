# ai-dns-unlock

基于 SmartDNS + dnsmasq + sniproxy 的 AI 服务 DNS 分流解锁。
当前网络无法直连 OpenAI / Claude / Gemini 时,用一台或多台能直连的机器当落地节点,把这些域名"接出去"。

两个独立 bash 脚本,Debian 12+ / Ubuntu 22.04+,**以 root 运行**,幂等可重复执行。

技术细节、原理详解、不用脚本时怎么手动一步步配,看 [INTERNALS.md](./INTERNALS.md)。

---

## 数据流

```
[被解锁机 App]
    │ DNS query
    ▼
[SmartDNS @ 127.0.0.1:53]
    ├─ 默认组      → 1.1.1.1 / 8.8.8.8     (直连)
    └─ ai-unlock 组 → 解锁机:53            (多机时测速择优 + 故障转移)
                             │
                             ▼
                   [解锁机 dnsmasq @ PUB_IP:53]
                   address=/openai.com/PUB_IP …
                             │
                             ▼  返回解锁机自己的 IP
[被解锁机 App] ── HTTPS ──▶ [解锁机 sniproxy @ PUB_IP:80,443]
                                    │  按 SNI 透传
                                    ▼
                            [真实 OpenAI / Claude / Gemini]
```

AI 域名清单从 [1stream-public-utils](https://github.com/1-stream/1stream-public-utils) 自动拉取(`> AI Platform` 段),拉不到用内置兜底清单。

---

## 部署

> **以 root 运行,不要用 `sudo VAR=... bash ...`** — sudo 默认会丢掉环境变量,你预填的参数会被吃掉。先 `sudo -i` 或 `su -` 进 root 再跑。

### 1. 解锁机(能直连 AI 的机器)

```bash
curl -fsSLO https://raw.githubusercontent.com/Vex9th/ai-dns-unlock/main/deploy-unlocker.sh
bash deploy-unlocker.sh
# 按提示输入被解锁机的源 IP(支持多个,空格分隔)
```

预填参数跑:

```bash
CLIENT_IPS="1.2.3.4 5.6.7.8" bash deploy-unlocker.sh
```

每台解锁机各跑一遍。

### 2. 被解锁机

```bash
curl -fsSLO https://raw.githubusercontent.com/Vex9th/ai-dns-unlock/main/deploy-client.sh
bash deploy-client.sh
# 按提示输入解锁机公网 IP(支持多个,SmartDNS 会测速择优 + 故障转移)
```

预填参数跑:

```bash
UNLOCKER_IPS="<IP_A> <IP_B>" bash deploy-client.sh
```

脚本会**自动**:
- 检测并停掉 53 端口占用者(systemd-resolved / AdGuardHome / dnsmasq / unbound / pi-hole 等)
- 备份 `/etc/resolv.conf` 到 `.bak.ai-unlock`
- 把 `/etc/resolv.conf` 改为 `nameserver 127.0.0.1`

### 3. 关掉浏览器自带 DoH

Chrome / Edge / Firefox 的 "Use secure DNS" 会**绕过系统 DNS**,必须关掉:

- Chrome / Edge:`chrome://settings/security` → Use secure DNS → Off
- Firefox:`about:preferences#privacy` → 滚到底 → Enable DNS over HTTPS → Off

---

## 验证

```bash
dig chat.openai.com +short        # 应回 解锁机 IP 之一
dig chat.openai.com AAAA +short   # 应为空
dig chat.openai.com TYPE65 +short # 应为空
dig example.com +short            # 应正常解析(默认组未受影响)
curl -v https://chat.openai.com/  # 能完成 TLS 握手
```

---

## 运维

| 场景 | 操作 |
|---|---|
| 1stream 列表更新了想跟进 | 在两边都重跑脚本 |
| 被解锁机出口 IP 变了 | 在每台解锁机重跑,带新 `CLIENT_IPS` |
| 加新的解锁机 | 在新机跑 `deploy-unlocker.sh`,在被解锁机重跑 `deploy-client.sh` 并把新 IP 加进 `UNLOCKER_IPS` |
| 某个解锁机被风控 | `sed -i 's\|^server <IP> -group ai-unlock\|#&\|' /etc/smartdns/smartdns.conf && systemctl reload smartdns`,或重跑 client 脚本只填留下的 IP |

---

## 常见冲突 / 注意事项

- **53 端口被占**:脚本会自动停掉 systemd-resolved / AdGuardHome / dnsmasq / unbound / named / pdns / pi-hole-FTL / coredns。遇到未识别的 DNS 进程会 warn,需要手动停后重跑。
- **NetworkManager 覆盖 /etc/resolv.conf**:脚本会 warn。被覆盖后跑 `chattr +i /etc/resolv.conf` 锁定。
- **风控判断靠人**:SmartDNS 的 TCP 测速只识别"握手失败",识别不了"握手成功但 7 层被风控返 403"。
- **CNAME 链外的域名会泄露**:1stream 列表覆盖了主流 CDN/CNAME 但不是 100%。
- **iptables 规则用独立子链 `ai-unlock`**,不污染你已有的 INPUT 规则。
- **`sudo VAR=... bash` 不会传 VAR**(sudo env_reset policy)。要么 `sudo -E`,要么直接以 root 跑。

---

## 文件清单

- `deploy-unlocker.sh` — 解锁机部署
- `deploy-client.sh` — 被解锁机部署
- `README.md` — 本文档(部署指引)
- `INTERNALS.md` — 技术细节、原理详解、手动部署教程

---

## 致谢

- [1stream-public-utils](https://github.com/1-stream/1stream-public-utils) — AI 域名清单
- [pymumu/smartdns](https://github.com/pymumu/smartdns)
- [dlundquist/sniproxy](https://github.com/dlundquist/sniproxy)
- [lthero-big/Smartdns_sniproxy_installer](https://github.com/lthero-big/Smartdns_sniproxy_installer) — 配置生成思路参考

## License

MIT
