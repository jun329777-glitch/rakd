#!/bin/bash
# ============================================================================
# VPS 一键部署脚本：Xray (VLESS+REALITY) + 可选静态住宅IP链式代理
# 系统要求：Ubuntu 22.04 / Debian 11+，root 用户执行
# 用法：按需填好下方参数后，chmod +x deploy.sh && ./deploy.sh
# ============================================================================
set -e

# =============================================================
# SSH 端口（改掉默认22，防扫描）
SSH_PORT="42878"

# Xray 监听端口（REALITY 建议用 443，最像正常 HTTPS 流量）
XRAY_PORT="443"

# ---- 静态住宅代理（ISP Proxy）信息，找你的代理商家要 ----
RESI_HOST="__填住宅代理地址__" # 例如：us.isp-proxy.com
RESI_PORT="__填端口__" # 例如：1080
RESI_USER="__填用户名__"
RESI_PASS="__填密码__"

# ---- 需要走住宅IP的域名（逗号分隔，可自行增减） ----
# 这些网站的流量会从住宅IP出去，其他走VPS直连
RESI_DOMAINS="openai.com,chatgpt.com,claude.ai,anthropic.com,google.com,gmail.com,youtube.com,github.com,netflix.com,disneyplus.com"

# ---- 可选：填入你的 SSH 公钥，填了之后自动禁用密码登录（更安全）----
# 不填则保留密码登录（配合改端口+fail2ban，够用）
SSH_PUBKEY=""

# ---- REALITY 伪装目标（dest/serverNames/SNI）----
# 必须用证书小的站点：www.microsoft.com 的证书链已膨胀到 8273 字节，
# 超过 Xray REALITY 内建 8192 字节上限（上游 XTLS/Xray-core#6356），
# 会导致所有客户端握手失败（"handshake did not complete successfully"），
# 表现为 Shadowrocket 全部超时——即使密钥/端口/版本都没问题。
# www.cloudflare.com 实测证书约 2500 字节，安全。换目标时先用
# openssl s_client -connect <host>:443 -servername <host> -tls1_3 -msg
# 确认 Certificate 记录长度 ≤8000 字节再采用。
REALITY_DEST="www.cloudflare.com"

# ---- 流量监控：是否安装 vnstat（服务器本地流量统计）----
INSTALL_VNSTAT="yes"

# ============================================================================
# 以下为自动执行部分，无需修改
# ============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log() { echo -e "${GREEN}[OK]${NC} $1";}
warn() { echo -e "${YELLOW}[!]${NC} $1";}
err() { echo -e "${RED}[X]${NC} $1"; exit 1;}

[ "$(id -u)" -eq 0 ] || err "请用 root 用户执行"
# 住宅代理为可选项：不填则跳过链式代理，全部流量走 VPS 直连
if [[ "$RESI_HOST" == __* ]]; then
USE_RESI="no"
warn "未填写住宅代理信息，将跳过住宅IP链式代理（全部流量走 VPS 直连）"
else
USE_RESI="yes"
log "已配置住宅代理：$RESI_HOST:$RESI_PORT"
fi

echo "========== 1/8 系统更新 =========="
apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
apt-get install -y -qq curl wget openssl ufw fail2ban unattended-upgrades > /dev/null
log "系统更新完成"

echo "========== 2/8 开启 BBR 加速 =========="
grep -q "net.core.default_qdisc" /etc/sysctl.conf || cat >> /etc/sysctl.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl -p > /dev/null 2>&1
log "BBR 已开启"

echo "========== 3/8 SSH 加固 =========="
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sed -i "s/^#\?Port.*/Port $SSH_PORT/" /etc/ssh/sshd_config
# 禁止空密码
sed -i "s/^#\?PermitEmptyPasswords.*/PermitEmptyPasswords no/" /etc/ssh/sshd_config
# 缩短登录宽限时间，防慢速暴力破解
sed -i "s/^#\?LoginGraceTime.*/LoginGraceTime 30/" /etc/ssh/sshd_config
# 最多3次验证机会
sed -i "s/^#\?MaxAuthTries.*/MaxAuthTries 3/" /etc/ssh/sshd_config

# 安全红线：只有确认 SSH 公钥已成功写入，才允许禁用密码登录；
# 否则必须明确保留 root 密码登录，否则直接把自己锁死
if [ -n "$SSH_PUBKEY" ]; then
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo "$SSH_PUBKEY" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
[ -s /root/.ssh/authorized_keys ] || err "公钥写入失败，为防锁死已中止"
sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config
sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config
sed -i "s/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/" /etc/ssh/sshd_config
warn "已写入SSH公钥并禁用密码登录！请确认私钥在手，否则会锁死"
else
sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
warn "未提供SSH公钥，已保留 root 密码登录（改端口+fail2ban防护）"
fi
systemctl restart sshd
log "SSH 加固完成，新端口：$SSH_PORT"

echo "========== 4/8 防火墙 (UFW) =========="
ufw --force reset > /dev/null
ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null
ufw allow "$SSH_PORT"/tcp comment 'SSH' > /dev/null
ufw allow "$XRAY_PORT"/tcp comment 'Xray-REALITY' > /dev/null
ufw --force enable > /dev/null
log "防火墙已启用，仅开放 SSH($SSH_PORT) 和 Xray($XRAY_PORT)"

echo "========== 5/8 Fail2ban 防暴力破解 =========="
cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = $SSH_PORT
maxretry = 3
bantime = 86400
findtime = 600
EOF
systemctl enable --now fail2ban > /dev/null 2>&1
log "Fail2ban 已启用（3次失败封禁24小时）"

echo "========== 6/8 自动安全更新 =========="
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now unattended-upgrades > /dev/null 2>&1
log "自动安全更新已开启"

if [ "$INSTALL_VNSTAT" = "yes" ]; then
echo "========== 6.5/8 安装 vnstat 流量统计 =========="
apt-get install -y -qq vnstat > /dev/null
systemctl enable --now vnstat > /dev/null 2>&1
log "vnstat 已安装（vnstat -d 查每日流量，vnstat -m 查每月流量）"
fi

echo "========== 7/8 安装 Xray =========="
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1
log "Xray 安装完成：$(xray version 2>/dev/null | head -1)"

echo "========== 8/8 生成密钥并写入 Xray 配置 =========="
# 生成 REALITY 密钥对（注：新版 xray 输出为 "PrivateKey: xxx" 两段式，用 $NF 取末字段兼容新旧格式）
KEYS=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep -i "PrivateKey" | awk '{print $NF}')
PUBLIC_KEY=$(echo "$KEYS" | grep -i "PublicKey" | awk '{print $NF}')
[ ${#PRIVATE_KEY} -ge 40 ] || err "REALITY 密钥解析失败（xray x25519 输出格式变化），请检查"
[ ${#PUBLIC_KEY} -ge 40 ] || err "REALITY 密钥解析失败（xray x25519 输出格式变化），请检查"
# 生成 UUID 和 shortId
UUID=$(cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(openssl rand -hex 8)

# 住宅代理出站与路由规则（仅在填写了住宅代理信息时生成）
if [ "$USE_RESI" = "yes" ]; then
# 域名列表转 JSON 数组
DOMAIN_JSON=$(echo "$RESI_DOMAINS" | tr ',' '\n' | sed 's/^/"/;s/$/"/' | paste -sd "," -)
RESI_OUTBOUND=$(cat <<JSONEOF
{
"tag": "residential",
"protocol": "socks",
"settings": {
"servers": [
{
"address": "$RESI_HOST",
"port": $RESI_PORT,
"users": [ { "user": "$RESI_USER", "pass": "$RESI_PASS"}]
}
]
}
},
JSONEOF
)
RESI_RULE=$(cat <<JSONEOF
{ "type": "field", "domain": [$DOMAIN_JSON], "outboundTag": "residential"},
JSONEOF
)
else
RESI_OUTBOUND=""
RESI_RULE=""
fi

cat > /usr/local/etc/xray/config.json <<EOF
{
"log": { "loglevel": "warning"},
"inbounds": [
{
"port": $XRAY_PORT,
"protocol": "vless",
"settings": {
"clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision"}],
"decryption": "none"
},
"streamSettings": {
"network": "tcp",
"security": "reality",
"realitySettings": {
"show": false,
"dest": "$REALITY_DEST:443",
"xver": 0,
"serverNames": [ "$REALITY_DEST"],
"privateKey": "$PRIVATE_KEY",
"shortIds": [ "$SHORT_ID"]
}
},
"sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"]}
}
],
"outbounds": [
$RESI_OUTBOUND
{ "tag": "direct", "protocol": "freedom"},
{ "tag": "block", "protocol": "blackhole"}
],
"routing": {
"domainStrategy": "IPIfNonMatch",
"rules": [
{ "type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block"},
$RESI_RULE
{ "type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
{ "type": "field", "network": "udp", "port": 443, "outboundTag": "block"}
]
}
}
EOF

systemctl enable --now xray
sleep 2
systemctl is-active --quiet xray && log "Xray 运行正常" || err "Xray 启动失败，请检查 journalctl -u xray"

# 获取本机公网 IP
SERVER_IP=$(curl -s -m 10 ifconfig.me || curl -s -m 10 ipinfo.io/ip)

# 生成客户端链接
VLESS_LINK="vless://${UUID}@${SERVER_IP}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$REALITY_DEST&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#RAK-SJ"

mkdir -p /root/proxy-info
cat > /root/proxy-info/client.txt <<EOF
==================== 客户端连接信息 ====================
服务器 IP：${SERVER_IP}
端口：${XRAY_PORT}
UUID：${UUID}
PublicKey：${PUBLIC_KEY}
ShortId：${SHORT_ID}

VLESS 链接（复制导入 v2rayNG / Nekoray / Streisand / Shadowrocket）：
${VLESS_LINK}

SSH 连接：ssh -p ${SSH_PORT} root@${SERVER_IP}
========================================================
EOF

echo ""
echo -e "${GREEN}================ 部署完成 ================${NC}"
cat /root/proxy-info/client.txt
echo ""
warn "重要提醒："
warn "1. 客户端信息已保存到 /root/proxy-info/client.txt，妥善保管，不要外传"
warn "2. 下次 SSH 请用新端口：ssh -p $SSH_PORT root@你的IP"
warn "3. 建议定期执行 apt update && apt upgrade 保持 Xray 为最新版"

echo "========== 9/9 Stage2: 8443备用 + SS2022 =========="
apt-get install -y -qq python3 > /dev/null 2>&1
cat > /root/stage2-rak.py <<'PYEOF'
import json, os, base64, subprocess, sys, copy
CFG = "/usr/local/etc/xray/config.json"
cfg = json.load(open(CFG))
inbounds = cfg["inbounds"]
base = inbounds[0]
def has_port(p): return any(i.get("port") == p for i in inbounds)
if not has_port(8443):
    v2 = copy.deepcopy(base); v2["port"] = 8443; inbounds.append(v2)
SSKEY_FILE = "/root/proxy-info/sskey.txt"
if not has_port(8388):
    sskey = base64.b64encode(os.urandom(32)).decode()
    inbounds.append({"port": 8388, "protocol": "shadowsocks",
        "settings": {"method": "2022-blake3-aes-256-gcm", "password": sskey, "network": "tcp,udp"},
        "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}, "tag": "ss2022-in"})
    os.makedirs("/root/proxy-info", exist_ok=True)
    open(SSKEY_FILE, "w").write(sskey)
else:
    sskey = open(SSKEY_FILE).read().strip()
json.dump(cfg, open(CFG, "w"), indent=2)
r = subprocess.run(["xray", "-test", "-config", CFG], capture_output=True, text=True)
if r.returncode != 0:
    print("XRAY_TEST_FAILED", r.stdout[-200:], r.stderr[-200:]); sys.exit(1)
subprocess.run(["systemctl", "restart", "xray"], check=False)
subprocess.run(["ufw", "allow", "8443/tcp"], capture_output=True)
subprocess.run(["ufw", "allow", "8388/tcp"], capture_output=True)
subprocess.run(["ufw", "allow", "8388/udp"], capture_output=True)
ip = "198.200.58.246"
uuid = base["settings"]["clients"][0]["id"]
rs = base["streamSettings"]["realitySettings"]
pubk = ""
try:
    for line in open("/root/proxy-info/client.txt"):
        if "PublicKey" in line: pubk = line.split("：")[-1].split(":")[-1].strip()
except Exception: pass
sid = rs["shortIds"][0]; sni = "www.cloudflare.com"
v8443 = f"vless://{uuid}@{ip}:8443?encryption=none&flow=xtls-rprx-vision&security=reality&sni={sni}&fp=chrome&pbk={pubk}&sid={sid}&type=tcp#RAK-SJ-8443"
userinfo = base64.urlsafe_b64encode(f"2022-blake3-aes-256-gcm:{sskey}".encode()).decode().rstrip("=")
sslink = f"ss://{userinfo}@{ip}:8388#RAK-SJ-SS"
with open("/root/proxy-info/client.txt", "a") as f:
    f.write("\n----- Stage2 additions -----\n")
    f.write(f"VLESS 8443: {v8443}\nSS2022 link: {sslink}\nSS2022 password(b64 32B): {sskey}\n")
print("stage2 done")
PYEOF
python3 /root/stage2-rak.py
echo ""
echo "=================RESULT================="
cat /root/proxy-info/client.txt
systemctl is-active xray
echo "=================END===================="
