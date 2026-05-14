#!/usr/bin/env bash
# deploy-unlocker.sh
# 在「解锁机」(可直连 AI 服务的机器) 上部署
# 安装 dnsmasq + sniproxy,把 AI 域名劫持到本机,按 SNI 转发给真实上游
# iptables 仅放行「被解锁机」白名单源 IP
#
# 目标系统: Debian 12+ / Ubuntu 22.04+
#
# 用法:
#   sudo ./deploy-unlocker.sh
#   或在顶部变量预填后 sudo bash deploy-unlocker.sh
# 重跑此脚本可更新域名清单 / 白名单 IP / 公网 IP。

set -euo pipefail

# =============== 可配参数 ===============
CLIENT_IPS=""              # 被解锁机的源 IP,空格分隔;空则交互输入
PUB_IP=""                  # 解锁机自己的公网 IPv4;空则自动探测
UPSTREAM_DNS="1.1.1.1 8.8.8.8"
LIST_URL="https://raw.githubusercontent.com/1-stream/1stream-public-utils/main/stream.smartdns.list"
# ========================================

MARK="ai-unlock"
DNSMASQ_CONF="/etc/dnsmasq.d/${MARK}.conf"
SNIPROXY_CONF="/etc/sniproxy.conf"
IPSET_NAME="ai_unlock_clients"

# 兜底域名清单(1stream 拉取失败时使用,2026-05-14 快照)
FALLBACK_DOMAINS=(
    openai.com
    chatgpt.com
    sora.com
    oaistatic.com
    oaiusercontent.com
    anthropic.com
    claude.ai
    claude.com
    gemini.google.com
    proactivebackend-pa.googleapis.com
    aisandbox-pa.googleapis.com
    robinfrontend-pa.googleapis.com
    aistudio.google.com
    alkalimakersuite-pa.clients6.google.com
    generativelanguage.googleapis.com
    alkalicore-pa.clients6.google.com
    waa-pa.clients6.google.com
    copilot.microsoft.com
)

# =============== 日志函数 ===============
RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YLW=$'\033[1;33m'; BLU=$'\033[1;34m'; RST=$'\033[0m'
log()  { echo "${BLU}[*]${RST} $*"; }
ok()   { echo "${GRN}[✓]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*" >&2; }
die()  { echo "${RED}[x]${RST} $*" >&2; exit 1; }

# =============== 前置检查 ===============
[[ $EUID -eq 0 ]] || die "请用 root 运行 (sudo bash $0)"
[[ -f /etc/debian_version ]] || die "仅支持 Debian / Ubuntu"

# =============== 交互输入兜底 ===============
if [[ -z "$CLIENT_IPS" ]]; then
    echo
    read -rp "请输入「被解锁机」的源 IP(多个用空格分隔): " CLIENT_IPS
    [[ -n "$CLIENT_IPS" ]] || die "CLIENT_IPS 不能为空,否则解锁机将无法被任何客户端访问"
fi

# 校验 IP 格式
for ip in $CLIENT_IPS; do
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "CLIENT_IPS 格式错误: $ip"
done

# =============== 公网 IP 探测 ===============
if [[ -z "$PUB_IP" ]]; then
    log "探测解锁机公网 IPv4..."
    for endpoint in "https://ipv4.icanhazip.com" "https://api.ipify.org" "https://ifconfig.me"; do
        PUB_IP=$(curl -fsS4 --max-time 5 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$PUB_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            ok "公网 IP: $PUB_IP (via $endpoint)"
            break
        fi
        PUB_IP=""
    done
    [[ -n "$PUB_IP" ]] || die "公网 IP 探测失败,请在脚本顶部 PUB_IP 变量手填"
fi

# =============== 安装依赖 ===============
log "安装 dnsmasq / sniproxy / iptables-persistent / ipset..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
# 先备份 /etc/resolv.conf,因为 dnsmasq 包的 postinst 可能改它
if [[ -e /etc/resolv.conf && ! -e /etc/resolv.conf.bak.ai-unlock ]]; then
    cp -a /etc/resolv.conf /etc/resolv.conf.bak.ai-unlock 2>/dev/null || true
fi
RESOLV_BEFORE=$(readlink -f /etc/resolv.conf 2>/dev/null || echo /etc/resolv.conf)
RESOLV_SUM_BEFORE=$(md5sum /etc/resolv.conf 2>/dev/null | awk '{print $1}')

apt-get install -y -q dnsmasq sniproxy curl ipset iptables-persistent ca-certificates
# 安装后 dnsmasq 用默认配置启动可能冲突 systemd-resolved,先停下,等配置写完再启
systemctl stop dnsmasq 2>/dev/null || true

# 如果 dnsmasq 包改了 /etc/resolv.conf 把它指回了 127.0.0.1(部分系统),恢复
RESOLV_SUM_AFTER=$(md5sum /etc/resolv.conf 2>/dev/null | awk '{print $1}')
if [[ "$RESOLV_SUM_AFTER" != "$RESOLV_SUM_BEFORE" ]] && grep -qE '^nameserver\s+127\.' /etc/resolv.conf 2>/dev/null; then
    warn "dnsmasq 包安装时改写了 /etc/resolv.conf 指向 127.x,恢复中..."
    [[ -L /etc/resolv.conf ]] && rm -f /etc/resolv.conf
    if [[ -e /etc/resolv.conf.bak.ai-unlock ]]; then
        cp -a /etc/resolv.conf.bak.ai-unlock /etc/resolv.conf
    else
        printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
    fi
fi
ok "依赖安装完成"

# dnsmasq 版本检查(filter-AAAA 需要 2.86+)
DNSMASQ_VER=$(dnsmasq --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0.0")
log "dnsmasq 版本: $DNSMASQ_VER"
DNSMASQ_HAS_FILTER_AAAA=0
if awk -v v="$DNSMASQ_VER" 'BEGIN{split(v,a,"."); exit !(a[1]>2 || (a[1]==2 && a[2]>=86))}'; then
    DNSMASQ_HAS_FILTER_AAAA=1
else
    warn "dnsmasq < 2.86,filter-AAAA 跳过(依赖 address= 的隐式 NODATA 即可)"
fi

# =============== 拉取域名清单 ===============
log "从 1stream 拉取 AI 域名清单..."
TMP_LIST=$(mktemp)
trap 'rm -f "$TMP_LIST"' EXIT

DOMAINS=()
LIST_SOURCE="online"
if curl -fsSL --max-time 10 "$LIST_URL" -o "$TMP_LIST" 2>/dev/null && [[ -s "$TMP_LIST" ]]; then
    mapfile -t DOMAINS < <(
        awk '
            /^# ---------- > AI Platform/ {flag=1; next}
            /^# ---------- >/ {flag=0}
            flag && /^nameserver \// {print}
        ' "$TMP_LIST" | sed -E 's|^nameserver /([^/]+)/.*|\1|' | sort -u
    )
fi

if [[ ${#DOMAINS[@]} -eq 0 ]]; then
    warn "在线列表拉取失败 / 解析为空,使用内置兜底清单"
    DOMAINS=("${FALLBACK_DOMAINS[@]}")
    LIST_SOURCE="fallback"
fi
ok "得到 ${#DOMAINS[@]} 个 AI 域名 (source: $LIST_SOURCE)"

# =============== 主 dnsmasq.conf 防冲突处理 ===============
# 注释掉默认 listen-address=127 行(若存在),避免与我们 listen-address=<PUB_IP> 冲突
if [[ -f /etc/dnsmasq.conf ]] && grep -qE '^listen-address=127' /etc/dnsmasq.conf; then
    sed -i 's/^\(listen-address=127.*\)/#\1   # disabled by deploy-unlocker.sh/' /etc/dnsmasq.conf
fi

# =============== 写 dnsmasq 配置 ===============
log "生成 $DNSMASQ_CONF ..."
{
    echo "# Managed by deploy-unlocker.sh — DO NOT EDIT BY HAND"
    echo "# Generated: $(date -Is)"
    echo "# Domain list source: $LIST_SOURCE (${#DOMAINS[@]} domains)"
    echo
    echo "listen-address=${PUB_IP}"
    echo "bind-interfaces"
    echo "no-resolv"
    echo "no-hosts"
    echo "domain-needed"
    echo "bogus-priv"
    echo "log-queries=no"
    for u in $UPSTREAM_DNS; do
        echo "server=$u"
    done
    # 注意:dnsmasq 没有 filter-rr-types 选项;type65(ECH)由 address= 进入
    # 权威模式后自动返 NODATA,不需要额外配置。
    if [[ $DNSMASQ_HAS_FILTER_AAAA -eq 1 ]]; then
        echo "filter-AAAA"
    fi
    echo
    echo "# AI 域名劫持到本机(对 AAAA / type65 由 address= 权威模式自动返 NODATA)"
    for d in "${DOMAINS[@]}"; do
        echo "address=/${d}/${PUB_IP}"
    done
} > "$DNSMASQ_CONF"
ok "dnsmasq 配置写入完成"

systemctl enable dnsmasq >/dev/null 2>&1 || true

# =============== 写 sniproxy 配置 ===============
# 语法依据: Debian 12 sniproxy 包(dlundquist/sniproxy 0.6.x)的 sniproxy.conf(5) manpage
log "生成 $SNIPROXY_CONF ..."
mkdir -p /var/log/sniproxy
cat > "$SNIPROXY_CONF" <<EOF
# Managed by deploy-unlocker.sh — DO NOT EDIT BY HAND
# Generated: $(date -Is)

username daemon
pidfile /var/run/sniproxy.pid

error_log {
    syslog daemon
    priority notice
}

resolver {
    nameserver $(echo "$UPSTREAM_DNS" | awk '{print $1}')
    nameserver $(echo "$UPSTREAM_DNS" | awk '{print $2}')
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
ok "sniproxy 配置写入完成"

# Debian 包默认 ENABLED=0,改成 1
if [[ -f /etc/default/sniproxy ]]; then
    sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/sniproxy
fi
systemctl enable sniproxy >/dev/null 2>&1 || true

# =============== iptables 白名单(独立子链)===============
log "配置 iptables 白名单(子链: $MARK,ipset: $IPSET_NAME)..."

# 创建/重置 ipset
ipset create "$IPSET_NAME" hash:ip -exist
ipset flush "$IPSET_NAME"
for ip in $CLIENT_IPS; do
    ipset add "$IPSET_NAME" "$ip"
done

# 用独立子链,重跑只需 flush 子链,不污染 INPUT 上其他规则
iptables -N "$MARK" 2>/dev/null || true
iptables -F "$MARK"

# 子链规则
iptables -A "$MARK" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN  # 已建立放行,继续后续 INPUT 规则
iptables -A "$MARK" -m addrtype --src-type LOCAL -j RETURN                # 本机自检流量不拦
iptables -A "$MARK" -m set --match-set "$IPSET_NAME" src -p udp --dport 53 -j ACCEPT
iptables -A "$MARK" -m set --match-set "$IPSET_NAME" src -p tcp --dport 53 -j ACCEPT
iptables -A "$MARK" -m set --match-set "$IPSET_NAME" src -p tcp --dport 80 -j ACCEPT
iptables -A "$MARK" -m set --match-set "$IPSET_NAME" src -p tcp --dport 443 -j ACCEPT
iptables -A "$MARK" -p udp --dport 53 -j DROP
iptables -A "$MARK" -p tcp --dport 53 -j DROP
iptables -A "$MARK" -p tcp --dport 80 -j DROP
iptables -A "$MARK" -p tcp --dport 443 -j DROP

# 把 INPUT 顶部跳到子链(若已存在则跳过插入)
if ! iptables -C INPUT -j "$MARK" 2>/dev/null; then
    iptables -I INPUT 1 -j "$MARK"
fi

# 持久化
mkdir -p /etc/iptables
ipset save > /etc/iptables/ipsets
iptables-save > /etc/iptables/rules.v4
ok "iptables 规则已下发并持久化"

# ipset-restore 必须在 netfilter-persistent 之前跑,否则 iptables 还原时 set 不存在会报错
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
systemctl enable ipset-restore.service >/dev/null 2>&1 || true

# =============== 启动 / 重启服务 ===============
log "启动 dnsmasq / sniproxy..."
systemctl restart dnsmasq
systemctl restart sniproxy
sleep 1
systemctl is-active --quiet dnsmasq  || die "dnsmasq 启动失败,看 journalctl -u dnsmasq"
systemctl is-active --quiet sniproxy || die "sniproxy 启动失败,看 journalctl -u sniproxy"
ok "服务已运行"

# =============== 输出指引 ===============
cat <<EOF

${GRN}========== 解锁机部署完成 ==========${RST}
解锁机公网 IP   : ${PUB_IP}
被解锁机白名单  : ${CLIENT_IPS}
AI 域名数       : ${#DOMAINS[@]} (source: ${LIST_SOURCE})
dnsmasq 配置    : ${DNSMASQ_CONF}
sniproxy 配置   : ${SNIPROXY_CONF}

${BLU}本机自检:${RST}
  dig @${PUB_IP} chat.openai.com +short          # 应返回 ${PUB_IP}
  dig @${PUB_IP} chat.openai.com AAAA +short     # 应为空
  dig @${PUB_IP} chat.openai.com TYPE65 +short   # 应为空

${BLU}从被解锁机自检:${RST}
  dig @${PUB_IP} chat.openai.com +short
  curl -v --resolve chat.openai.com:443:${PUB_IP} https://chat.openai.com/

${BLU}白名单外机器(预期 DROP):${RST}
  dig @${PUB_IP} chat.openai.com                 # 应超时

${YLW}白名单 IP 或公网 IP 变更时,直接重跑本脚本即可(幂等)。${RST}
EOF
