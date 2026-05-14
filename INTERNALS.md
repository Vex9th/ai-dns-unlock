# 内部细节与手动部署

本文档解释两台机器各装了什么、为什么这么装、以及不用脚本时如何手动一步步部署。

目标读者:想理解架构 / 排查具体问题 / 不信任脚本想自己控制每一步的人。

---

## 1. 两台机器装了什么

### 解锁机(`deploy-unlocker.sh`)

| 组件 | 版本来源 | 作用 |
|---|---|---|
| `dnsmasq` | Debian/Ubuntu 官方源(2.86+) | DNS 劫持:把 AI 域名解析成本机公网 IP |
| `sniproxy` | Debian/Ubuntu 官方源(0.6.0-2.1) | L4 透明代理:接 80/443,按 TLS SNI 转发到真实上游 |
| `ipset` | 官方源 | 装"被解锁机白名单"IP 集合 |
| `iptables-persistent` | 官方源 | 把 iptables 规则和 ipset 在重启后还原 |
| `curl` / `ca-certificates` | 官方源 | 拉 1stream 列表 |

**新增 / 修改的文件**:

- `/etc/dnsmasq.d/ai-unlock.conf` — 我们独占,可以随时 rm 删干净
- `/etc/sniproxy.conf` — 覆盖原文件(原版本被 Debian 包装成默认配置)
- `/etc/default/sniproxy` — `ENABLED=0` → `ENABLED=1`
- `/etc/iptables/rules.v4` — iptables 持久化
- `/etc/iptables/ipsets` — ipset 持久化
- `/etc/systemd/system/ipset-restore.service` — boot 时优先于 `netfilter-persistent` 还原 ipset(否则白名单失效)

**新增的 iptables 规则**(全部在独立子链 `ai-unlock` 里,从 `INPUT` 顶部跳入):

```
-N ai-unlock
-A INPUT -j ai-unlock                                                     # 主链跳到子链
-A ai-unlock -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN          # 已建立连接放行
-A ai-unlock -m addrtype --src-type LOCAL -j RETURN                        # 本机自测放行
-A ai-unlock -m set --match-set ai_unlock_clients src -p udp --dport 53  -j ACCEPT
-A ai-unlock -m set --match-set ai_unlock_clients src -p tcp --dport 53  -j ACCEPT
-A ai-unlock -m set --match-set ai_unlock_clients src -p tcp --dport 80  -j ACCEPT
-A ai-unlock -m set --match-set ai_unlock_clients src -p tcp --dport 443 -j ACCEPT
-A ai-unlock                                  -p udp --dport 53  -j DROP    # 其他源 53/80/443 一律 DROP
-A ai-unlock                                  -p tcp --dport 53  -j DROP
-A ai-unlock                                  -p tcp --dport 80  -j DROP
-A ai-unlock                                  -p tcp --dport 443 -j DROP
```

子链的好处:重跑脚本只 flush 这一个子链,不污染机器上原有 INPUT 规则(SSH、Docker、k8s CNI 之类都不动)。

### 被解锁机(`deploy-client.sh`)

| 组件 | 版本来源 | 作用 |
|---|---|---|
| `smartdns` | GitHub Release(Debian/Ubuntu 官方源没有) | 分流核心:不同域名走不同 DNS 上游 |
| `curl` / `ca-certificates` | 官方源 | 拉 1stream 列表 + 拉 GitHub Release |

**新增 / 修改的文件**:

- `/etc/smartdns/smartdns.conf` — 覆盖(首次跑会把原文件备份成 `.orig`)
- `/etc/smartdns/ai.conf` — 我们独占的 AI 域名规则
- `/var/cache/smartdns/cache.bin` — 持久化 DNS 缓存
- `/etc/resolv.conf` — 改成 `nameserver 127.0.0.1`,原文件备份为 `.bak.ai-unlock`
- 若原本有 systemd-resolved / AdGuardHome / unbound / dnsmasq / pi-hole-FTL / named / pdns / coredns 占 53,**被自动停 + disable**(不卸载,只是停服务)

---

## 2. 原理逐步解释

### 2.1 为什么是 SmartDNS

`SmartDNS` 支持把不同域名分组到不同上游(`nameserver /domain/group-name`),组内多个上游可以并行测速选最快(`speed-check-mode tcp:443`),被解锁机的核心分流逻辑由它完成。

类似工具:`dnsmasq`(支持 `server=/domain/ip` 单条转发,不支持组内测速)、`unbound`(支持但配置复杂)、`AdGuardHome`(支持但更偏广告拦截定位)。

### 2.2 为什么解锁机用 dnsmasq + sniproxy 而不是 SNI 代理一体

```
被解锁机想访问 chat.openai.com
   │
   ▼ 查 DNS
解锁机的 dnsmasq 把 chat.openai.com 解成 <解锁机公网 IP>
   │
   ▼ TCP 443 连上来
解锁机的 sniproxy 监听 :443
   │
   ▼ 从 ClientHello 里读 SNI = chat.openai.com
sniproxy 用自己的 resolver(1.1.1.1 / 8.8.8.8)查到真实 IP
   │
   ▼ TCP 连出去
真实 OpenAI 服务器
   │
   ▼ TLS 在客户端和真实服务器之间端到端建立(中间人看不到明文)
```

**为什么不直接 NAT/iptables 重定向**:被解锁机不知道真实 OpenAI 的 IP,它只知道解锁机的 IP。所以必须先有 DNS 劫持把流量"骗"到解锁机,再由解锁机按 SNI 做 7 层转发。

**为什么 sniproxy 不做 TLS 解密**:它根本不需要密钥就能转发,只读 ClientHello 里明文的 SNI 字段。客户端和真实服务器之间的 TLS 是端到端的,sniproxy 只搬字节流。这是这个方案在用户层无感知的关键 — 浏览器里看到的证书仍然是真实 OpenAI 的。

### 2.3 为什么屏蔽 AAAA 和 type65

- **AAAA(IPv6)**:若 SmartDNS 让 AI 域名走默认组的 AAAA 查询,客户端拿到真实 v6 地址会直连(绕过解锁机)。所以对 AI 域名要返 NODATA。dnsmasq 端:`address=/domain/IP` 进入权威模式,AAAA 查询自动返 NODATA(无需额外配置)。SmartDNS 端:`address /domain/#6`(只对 AAAA 返 SOA)。
- **HTTPS RR / type 65 / ECH**:Chrome 等浏览器在 TLS 握手前会查域名的 type65 记录,里面带 ECHConfig(Encrypted Client Hello 公钥)。客户端拿到后会**加密 ClientHello**,sniproxy 就读不到 SNI 字段了,转发功能挂掉。所以对 AI 域名要返 NODATA。dnsmasq 端:同样靠权威模式自动返 NODATA。SmartDNS 端:`domain-rules /domain/ -force-https-soa`(per-domain 屏蔽,不影响其他流量)。

### 2.4 为什么 iptables 白名单

解锁机暴露 53(开放解析器)和 80/443(透明 SNI 代理)给整个互联网会被滥用:
- 53 开放会被 DDoS amplification 攻击利用(攻击者伪造源 IP 让你解析器回大量数据给受害者)
- 80/443 开放会被任意人当跳板访问任何站点(实际就是滥用你的带宽)

所以只允许"你信任的被解锁机源 IP"访问这三个端口。剩余源 IP 一律 DROP,而不是 REJECT — DROP 不返回任何应答,让扫描器更难发现这是一台活着的机器。

### 2.5 为什么把接管 DNS 放在 SmartDNS 启动之前

被解锁机上启动 SmartDNS 前,127.0.0.1:53 可能被 systemd-resolved / AdGuardHome / 旧版本 SmartDNS / 其他用户安装的 DNS 服务占用。如果 SmartDNS 启动时端口被占,会直接报 "Address in use" 退出,systemd 反复重试无果。所以必须先腾端口再起服务。

`deploy-client.sh` 里 `free_port_53` 函数:扫 `ss -lntup` 找占 53 的 pid,按进程名分类优雅停止(systemctl stop + disable,或者 binary 自带的 `-s stop`)。

---

## 3. 手动部署(不用脚本)

### 前置条件

- Debian 12+ 或 Ubuntu 22.04+
- 两台机器都以 **root** 操作
- 解锁机能直连 OpenAI / Claude / Gemini
- 被解锁机能访问 https://github.com 和 https://raw.githubusercontent.com(拿 1stream 列表 + SmartDNS deb)

### 3.1 手动配置解锁机

假设解锁机公网 IP `1.2.3.4`,允许的被解锁机源 IP `5.6.7.8`。

```bash
# 1. 装包
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    dnsmasq sniproxy curl ipset iptables-persistent ca-certificates
systemctl stop dnsmasq   # 默认配置可能冲突,先停下

# 2. 拉 AI 域名清单(从 1stream)
curl -fsSL https://raw.githubusercontent.com/1-stream/1stream-public-utils/main/stream.smartdns.list \
    | awk '
        /^# ---------- > AI Platform/ {flag=1; next}
        /^# ---------- >/ {flag=0}
        flag && /^nameserver \// {print}
    ' | sed -E 's|^nameserver /([^/]+)/.*|\1|' | sort -u > /tmp/ai-domains.txt

cat /tmp/ai-domains.txt   # 看清单(应该有 18 个左右)

# 3. 写 dnsmasq 配置
PUB_IP=1.2.3.4
cat > /etc/dnsmasq.d/ai-unlock.conf <<EOF
listen-address=${PUB_IP}
bind-interfaces
no-resolv
no-hosts
domain-needed
bogus-priv
log-queries=no
server=1.1.1.1
server=8.8.8.8
filter-AAAA
EOF
while read -r d; do
    echo "address=/${d}/${PUB_IP}" >> /etc/dnsmasq.d/ai-unlock.conf
done < /tmp/ai-domains.txt

# 4. 写 sniproxy 配置
cat > /etc/sniproxy.conf <<'EOF'
username daemon
pidfile /var/run/sniproxy.pid

error_log {
    syslog daemon
    priority notice
}

resolver {
    nameserver 1.1.1.1
    nameserver 8.8.8.8
    mode ipv4_only
}

listener 0.0.0.0:80 {
    protocol http
    table https_hosts
    access_log {
        filename /var/log/sniproxy/http_access.log
    }
}

listener 0.0.0.0:443 {
    protocol tls
    table https_hosts
    access_log {
        filename /var/log/sniproxy/https_access.log
    }
}

table https_hosts {
    .* *
}
EOF
mkdir -p /var/log/sniproxy
sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/sniproxy

# 5. iptables + ipset 白名单
CLIENT_IPS="5.6.7.8"   # 改成你的被解锁机 IP

ipset create ai_unlock_clients hash:ip -exist
ipset flush ai_unlock_clients
for ip in $CLIENT_IPS; do
    ipset add ai_unlock_clients "$ip"
done

iptables -N ai-unlock 2>/dev/null || true
iptables -F ai-unlock
iptables -A ai-unlock -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
iptables -A ai-unlock -m addrtype --src-type LOCAL -j RETURN
for proto_port in "udp 53" "tcp 53" "tcp 80" "tcp 443"; do
    read -r proto port <<< "$proto_port"
    iptables -A ai-unlock -m set --match-set ai_unlock_clients src -p "$proto" --dport "$port" -j ACCEPT
    iptables -A ai-unlock -p "$proto" --dport "$port" -j DROP
done
iptables -C INPUT -j ai-unlock 2>/dev/null || iptables -I INPUT 1 -j ai-unlock

mkdir -p /etc/iptables
ipset save > /etc/iptables/ipsets
iptables-save > /etc/iptables/rules.v4

# 6. ipset boot 时优先于 iptables-persistent 还原
cat > /etc/systemd/system/ipset-restore.service <<EOF
[Unit]
Description=Restore ipset before iptables-persistent
DefaultDependencies=no
Wants=netfilter-persistent.service
Before=netfilter-persistent.service

[Service]
Type=oneshot
ExecStart=/sbin/ipset restore -exist -f /etc/iptables/ipsets
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable ipset-restore.service

# 7. 启动
systemctl enable --now dnsmasq sniproxy
systemctl restart dnsmasq sniproxy
systemctl is-active dnsmasq sniproxy   # 都应该 active

# 8. 自检
dig @${PUB_IP} chat.openai.com +short          # 应回 ${PUB_IP}
curl -v --resolve chat.openai.com:443:${PUB_IP} https://chat.openai.com/ 2>&1 | head -15
```

### 3.2 手动配置被解锁机

假设解锁机 IP `1.2.3.4`(同上)。

```bash
# 1. 装 SmartDNS(官方源没有,从 GitHub Release 拿)
apt-get update
apt-get install -y curl ca-certificates

# 找 latest release 的 .deb URL(注意 Release 47+ 命名是 debian-all,旧版是 linux-all)
ARCH=x86_64   # aarch64 / arm 改这里
DEB_URL=$(curl -fsSL https://api.github.com/repos/pymumu/smartdns/releases/latest \
    | grep "browser_download_url" \
    | grep -E "${ARCH}-(debian|linux)-all\.deb\"" \
    | head -1 | cut -d'"' -f4)
echo "$DEB_URL"

curl -fsSLO "$DEB_URL"
apt-get install -y "./$(basename "$DEB_URL")"
smartdns -v   # 确认装上

# 2. 拉 AI 域名清单(同解锁机)
curl -fsSL https://raw.githubusercontent.com/1-stream/1stream-public-utils/main/stream.smartdns.list \
    | awk '
        /^# ---------- > AI Platform/ {flag=1; next}
        /^# ---------- >/ {flag=0}
        flag && /^nameserver \// {print}
    ' | sed -E 's|^nameserver /([^/]+)/.*|\1|' | sort -u > /tmp/ai-domains.txt

# 3. 腾出 127.0.0.1:53(停掉所有占用者)
for svc in systemd-resolved AdGuardHome dnsmasq unbound named pdns_recursor pihole-FTL coredns; do
    systemctl stop "$svc" 2>/dev/null
    systemctl disable "$svc" 2>/dev/null
done
ss -lntu 'sport = :53'   # 应该没输出

# 4. 备份 + 改 /etc/resolv.conf
[[ -e /etc/resolv.conf && ! -e /etc/resolv.conf.bak.ai-unlock ]] && cp -a /etc/resolv.conf /etc/resolv.conf.bak.ai-unlock
[[ -L /etc/resolv.conf ]] && rm -f /etc/resolv.conf
echo "nameserver 127.0.0.1" > /etc/resolv.conf

# 5. 写主配置
UNLOCKER_IPS="1.2.3.4"   # 改成你的解锁机 IP(多个空格分隔)
mkdir -p /etc/smartdns /var/cache/smartdns
[[ -f /etc/smartdns/smartdns.conf && ! -f /etc/smartdns/smartdns.conf.orig ]] && cp -a /etc/smartdns/smartdns.conf /etc/smartdns/smartdns.conf.orig
cat > /etc/smartdns/smartdns.conf <<EOF
bind 127.0.0.1:53
cache-size 32768
cache-persist yes
cache-file /var/cache/smartdns/cache.bin
prefetch-domain yes
serve-expired yes
serve-expired-ttl 86400
speed-check-mode tcp:443
response-mode first-ping
log-level warn

server 1.1.1.1
server 8.8.8.8

EOF
for ip in $UNLOCKER_IPS; do
    echo "server $ip -group ai-unlock -exclude-default-group" >> /etc/smartdns/smartdns.conf
done
echo "conf-file /etc/smartdns/ai.conf" >> /etc/smartdns/smartdns.conf

# 6. 写 ai.conf
{
    while read -r d; do echo "nameserver /${d}/ai-unlock"; done < /tmp/ai-domains.txt
    while read -r d; do echo "address /${d}/#6"; done < /tmp/ai-domains.txt
    while read -r d; do echo "domain-rules /${d}/ -force-https-soa"; done < /tmp/ai-domains.txt
} > /etc/smartdns/ai.conf

# 7. 启动
systemctl enable --now smartdns
systemctl restart smartdns
systemctl is-active smartdns   # active

# 8. 自检
dig chat.openai.com +short        # 应回解锁机 IP
dig chat.openai.com AAAA +short   # 应为空
dig chat.openai.com TYPE65 +short # 应为空
curl -v https://chat.openai.com/ 2>&1 | head -15
```

### 3.3 浏览器侧

`chrome://settings/security` → 关闭 "Use secure DNS"。其他基于 Chromium 的浏览器同理。Firefox 在 `about:preferences#privacy` 滚到底关 DoH。

---

## 4. 卸载

### 解锁机

```bash
# 停服务
systemctl disable --now dnsmasq sniproxy ipset-restore.service

# 删配置
rm -f /etc/dnsmasq.d/ai-unlock.conf
rm -f /etc/sniproxy.conf
rm -f /etc/systemd/system/ipset-restore.service
systemctl daemon-reload

# 清 iptables 子链
iptables -D INPUT -j ai-unlock 2>/dev/null
iptables -F ai-unlock 2>/dev/null
iptables -X ai-unlock 2>/dev/null
ipset destroy ai_unlock_clients 2>/dev/null
iptables-save > /etc/iptables/rules.v4
ipset save > /etc/iptables/ipsets

# 如果不再需要这两个包
apt-get purge -y dnsmasq sniproxy ipset iptables-persistent
```

### 被解锁机

```bash
# 停服务
systemctl disable --now smartdns

# 恢复 resolv.conf
rm -f /etc/resolv.conf
[[ -e /etc/resolv.conf.bak.ai-unlock ]] && cp -a /etc/resolv.conf.bak.ai-unlock /etc/resolv.conf

# 删配置
rm -f /etc/smartdns/smartdns.conf /etc/smartdns/ai.conf /etc/smartdns/cache.bin
[[ -e /etc/smartdns/smartdns.conf.orig ]] && mv /etc/smartdns/smartdns.conf.orig /etc/smartdns/smartdns.conf

# 卸载包(从 GitHub deb 装的)
apt-get purge -y smartdns

# 如果需要恢复 systemd-resolved
systemctl enable --now systemd-resolved
```

---

## 5. 排错思路

| 现象 | 排查 |
|---|---|
| `dnsmasq` 启动失败 | `journalctl -u dnsmasq -n 50`;`dnsmasq --test`;主 `/etc/dnsmasq.conf` 是否有 `listen-address=127` 跟 `listen-address=<PUB_IP>` 冲突 |
| `sniproxy` 启动失败,80/443 已被占 | `ss -lntp 'sport = :443'` 看是不是有 nginx/apache/前一个 sniproxy 残留;`kill` 掉残留进程 |
| `smartdns` 启动失败 `Address in use` | `ss -lntu 'sport = :53'` 找占用者;最常见是 systemd-resolved / AdGuardHome / 旧 dnsmasq |
| `smartdns` active 但 `dig` 没结果 | `cat /etc/resolv.conf` 是不是 127.0.0.1;`/var/log/smartdns/smartdns.log` 看具体错 |
| `dig` 通,`curl` 卡 | 解锁机 iptables 白名单没生效(`iptables -nvL ai-unlock` 看 DROP 计数);或解锁机 sniproxy 没起 |
| Chrome 能查 DNS 但不走解锁 | 关 chrome://settings/security 的 Use secure DNS |
| 重启后白名单失效 | `systemctl status ipset-restore.service`;手动 `systemctl enable ipset-restore.service` |
