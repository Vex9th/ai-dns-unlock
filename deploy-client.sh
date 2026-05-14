#!/usr/bin/env bash
# deploy-client.sh
# 在「被解锁机」(无法直连 AI 服务的机器) 上部署 SmartDNS
# 默认组使用本地可用 DNS;ai-unlock 组指向「解锁机」,AI 域名走 ai-unlock 组
#
# 目标系统: Debian 12+ / Ubuntu 22.04+
#
# 用法:
#   sudo ./deploy-client.sh
#   或在顶部变量预填后 sudo bash deploy-client.sh
# 重跑可更新域名清单 / 切换解锁机 IP。

set -euo pipefail

# =============== 可配参数 ===============
UNLOCKER_IPS=""           # 解锁机 IP,空格分隔(多个会被 SmartDNS 测速择优 + 故障转移)
                          # 空则交互输入,至少要 1 个
LOCAL_DNS="1.1.1.1 8.8.8.8"  # 默认 DNS,所有非 AI 域名走这里
LIST_URL="https://raw.githubusercontent.com/1-stream/1stream-public-utils/main/stream.smartdns.list"
# ========================================

MARK="ai-unlock"
SMARTDNS_CONF="/etc/smartdns/smartdns.conf"
AI_CONF="/etc/smartdns/ai.conf"

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

RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YLW=$'\033[1;33m'; BLU=$'\033[1;34m'; RST=$'\033[0m'
log()  { echo "${BLU}[*]${RST} $*"; }
ok()   { echo "${GRN}[✓]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*" >&2; }
die()  { echo "${RED}[x]${RST} $*" >&2; exit 1; }

# =============== 前置检查 ===============
[[ $EUID -eq 0 ]] || die "请用 root 运行 (sudo bash $0)"
[[ -f /etc/debian_version ]] || die "仅支持 Debian / Ubuntu"

# =============== 交互输入兜底 ===============
if [[ -z "$UNLOCKER_IPS" ]]; then
    read -rp "请输入「解锁机」公网 IP(多个空格分隔,如 1.2.3.4 5.6.7.8): " UNLOCKER_IPS
fi
[[ -n "$UNLOCKER_IPS" ]] || die "至少要填一个解锁机 IP"

for ip in $UNLOCKER_IPS; do
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "IP 格式错误: $ip"
done

# =============== 安装 SmartDNS ===============
install_smartdns_from_github() {
    log "从 GitHub Release 安装 SmartDNS..."
    local arch
    case "$(uname -m)" in
        x86_64)   arch="x86_64" ;;
        aarch64)  arch="aarch64" ;;
        armv7l)   arch="arm" ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac

    # Release 46 及更早是 x86_64-linux-all.deb,Release 47+ 改名为 x86_64-debian-all.deb
    # 这里两种命名都匹配,优先新的 debian-all,留兜底匹配任何 ${arch}*.deb
    local deb_url
    deb_url=$(curl -fsSL --max-time 10 \
        "https://api.github.com/repos/pymumu/smartdns/releases/latest" 2>/dev/null \
        | grep "browser_download_url" \
        | grep -E "${arch}-(debian|linux)-all\.deb\"" \
        | head -1 | cut -d'"' -f4 || true)

    if [[ -z "$deb_url" ]]; then
        # 兜底:任何含 ${arch} 的 .deb
        deb_url=$(curl -fsSL --max-time 10 \
            "https://api.github.com/repos/pymumu/smartdns/releases/latest" 2>/dev/null \
            | grep "browser_download_url" \
            | grep -E "${arch}[^\"]*\.deb\"" \
            | head -1 | cut -d'"' -f4 || true)
    fi

    [[ -n "$deb_url" ]] || die "无法获取 SmartDNS 最新 .deb 下载链接(GitHub API 不可达?或 release asset 命名又变了:https://github.com/pymumu/smartdns/releases/latest)"

    local tmp_deb
    tmp_deb=$(mktemp --suffix=.deb)
    curl -fsSL --max-time 60 -o "$tmp_deb" "$deb_url" || { rm -f "$tmp_deb"; die "下载 .deb 失败: $deb_url"; }

    # apt-get install 本地 .deb,会自动解决依赖,比 dpkg -i 后 apt -f 更可靠
    apt-get install -y -q "$tmp_deb" || die "SmartDNS .deb 安装失败"
    rm -f "$tmp_deb"
}

log "检查 / 安装 SmartDNS..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
if ! command -v smartdns >/dev/null 2>&1; then
    apt-get install -y -q curl ca-certificates
    # Debian/Ubuntu 官方源没有 smartdns,跳过 apt 尝试,直接 GitHub Release
    install_smartdns_from_github
fi
command -v smartdns >/dev/null 2>&1 || die "SmartDNS 安装失败"
ok "SmartDNS 已就绪: $(smartdns -v 2>&1 | head -1 || echo unknown)"

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

# =============== 写 SmartDNS 主配置 ===============
log "生成 $SMARTDNS_CONF ..."
mkdir -p /etc/smartdns /var/cache/smartdns

# 备份原配置(首次重跑保留 distro 默认)
if [[ -f "$SMARTDNS_CONF" && ! -f "${SMARTDNS_CONF}.orig" ]]; then
    cp -a "$SMARTDNS_CONF" "${SMARTDNS_CONF}.orig"
fi

{
    echo "# Managed by deploy-client.sh — DO NOT EDIT BY HAND"
    echo "# Generated: $(date -Is)"
    echo
    echo "bind 127.0.0.1:53"
    echo "cache-size 32768"
    echo "cache-persist yes"
    echo "cache-file /var/cache/smartdns/cache.bin"
    echo "prefetch-domain yes"
    echo "serve-expired yes"
    echo "serve-expired-ttl 86400"
    echo "speed-check-mode tcp:443"
    echo "response-mode first-ping"
    echo "log-level warn"
    echo
    echo "# 默认组:上游 DNS"
    for d in $LOCAL_DNS; do
        echo "server $d"
    done
    echo
    echo "# ai-unlock 组:解锁机(测速 tcp:443 择优 + 故障转移)"
    for ip in $UNLOCKER_IPS; do
        echo "server $ip -group ai-unlock -exclude-default-group"
    done
    echo
    echo "# AI 域名规则"
    echo "conf-file $AI_CONF"
} > "$SMARTDNS_CONF"
ok "主配置写入完成"

# =============== 写 ai.conf ===============
# - nameserver: 把 AI 域名指向 ai-unlock 组
# - address /d/#6: 对 AI 域名的 AAAA 查询返 SOA(NODATA),阻断 IPv6 绕过
# - domain-rules -force-https-soa: 对 AI 域名的 HTTPS RR(type 65)返 SOA,阻断 ECH
log "生成 $AI_CONF ..."
{
    echo "# Managed by deploy-client.sh — DO NOT EDIT BY HAND"
    echo "# Generated: $(date -Is)"
    echo "# AI 域名 ${#DOMAINS[@]} 个 (source: $LIST_SOURCE)"
    echo
    echo "# 把 AI 域名指向 ai-unlock 组"
    for d in "${DOMAINS[@]}"; do
        echo "nameserver /${d}/ai-unlock"
    done
    echo
    echo "# 屏蔽 AAAA(按域名生效,不影响其他流量)"
    for d in "${DOMAINS[@]}"; do
        echo "address /${d}/#6"
    done
    echo
    echo "# 屏蔽 HTTPS RR / ECH(按域名生效)"
    for d in "${DOMAINS[@]}"; do
        echo "domain-rules /${d}/ -force-https-soa"
    done
} > "$AI_CONF"
ok "ai.conf 写入完成"

# =============== 接管系统 DNS(必须在 SmartDNS 启动之前腾出 127.0.0.1:53)===============
log "接管系统 DNS..."

# 通用 53 端口腾出:检测占用者,逐个优雅停掉
free_port_53() {
    local pids name exe
    # 取所有占 53 的 pid(去重)
    pids=$(ss -lntup 2>/dev/null | awk '$5 ~ /:53$/' | grep -oP 'pid=\K[0-9]+' | sort -u)
    [[ -z "$pids" ]] && return 0

    for pid in $pids; do
        name=$(cat "/proc/$pid/comm" 2>/dev/null || echo unknown)
        exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || echo unknown)
        case "$name" in
            smartdns) ;;  # 是我们自己上一轮跑剩的,后面 restart 会接管
            systemd-resolved)
                log "停 systemd-resolved (占 53)"
                systemctl stop systemd-resolved
                systemctl disable systemd-resolved >/dev/null 2>&1 || true
                ;;
            AdGuardHome)
                log "停 AdGuardHome (占 53)"
                "$exe" -s stop 2>/dev/null || systemctl stop AdGuardHome 2>/dev/null || kill -TERM "$pid" 2>/dev/null
                systemctl disable AdGuardHome >/dev/null 2>&1 || true
                ;;
            dnsmasq|unbound|named|pdns_recursor|pdns_server|pihole-FTL|coredns)
                log "停 $name (占 53)"
                systemctl stop "$name" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
                systemctl disable "$name" >/dev/null 2>&1 || true
                ;;
            *)
                warn "未识别的 DNS 进程占 53: $name (pid=$pid, exe=$exe)"
                warn "脚本不自动停未知进程,SmartDNS 启动可能会失败;手动 kill $pid 后再重跑"
                ;;
        esac
    done
    sleep 1
}
free_port_53

# 二次检查
if ss -lntu 2>/dev/null | awk '$5 ~ /:53$/' | grep -qE '(127\.0\.0\.1|0\.0\.0\.0|\*):53'; then
    warn "127.0.0.1:53 / 0.0.0.0:53 仍被占,SmartDNS 可能启动失败"
    ss -lntup 2>/dev/null | awk '$5 ~ /:53$/' >&2 || true
fi

# 备份原 /etc/resolv.conf(只在首次跑脚本时备)
if [[ -e /etc/resolv.conf && ! -e /etc/resolv.conf.bak.ai-unlock ]]; then
    cp -a /etc/resolv.conf /etc/resolv.conf.bak.ai-unlock 2>/dev/null || true
fi

# 解 symlink + 解锁 + 写入
[[ -L /etc/resolv.conf ]] && rm -f /etc/resolv.conf
chattr -i /etc/resolv.conf 2>/dev/null || true
echo "nameserver 127.0.0.1" > /etc/resolv.conf
ok "/etc/resolv.conf 已指向 127.0.0.1"

# =============== 启动 SmartDNS ===============
systemctl enable smartdns >/dev/null 2>&1 || true
systemctl restart smartdns
sleep 1
systemctl is-active --quiet smartdns || die "SmartDNS 启动失败,看 journalctl -u smartdns 和 /var/log/smartdns/smartdns.log"
ok "SmartDNS 已运行(127.0.0.1:53)"

# 如果 NetworkManager 在跑,提示它可能会覆盖
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    warn "检测到 NetworkManager 在运行,它可能在下次网络变更时覆盖 /etc/resolv.conf"
    warn "若被覆盖,执行: chattr +i /etc/resolv.conf 锁定文件"
fi

# =============== 输出指引 ===============
cat <<EOF

${GRN}========== 被解锁机部署完成 ==========${RST}
解锁机列表       : ${UNLOCKER_IPS}
AI 域名数        : ${#DOMAINS[@]} (source: ${LIST_SOURCE})
主配置           : ${SMARTDNS_CONF}
AI 规则          : ${AI_CONF}
系统 DNS         : 127.0.0.1 (/etc/resolv.conf 已接管,原文件备份在 /etc/resolv.conf.bak.ai-unlock)

${BLU}最后一步:${RST}
  关闭 Chrome 的 "Use secure DNS":chrome://settings/security
  (浏览器自带 DoH 会绕过系统 DNS,必须关掉脚本才生效)

${BLU}验证命令:${RST}
  dig chat.openai.com +short          # 应回解锁机 IP 之一
  dig chat.openai.com AAAA +short     # 应为空
  dig chat.openai.com TYPE65 +short   # 应为空
  dig example.com +short              # 应正常解析(默认组未受影响)
  curl -v https://chat.openai.com/

${BLU}临时摘掉某个解锁机:${RST}
  sudo sed -i 's|^server <IP> -group ai-unlock|#&|' ${SMARTDNS_CONF}
  sudo systemctl reload smartdns
  # 或者直接重跑本脚本,只填留下的那些 IP(更稳)。
EOF
