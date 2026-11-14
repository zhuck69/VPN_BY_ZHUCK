#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

REALITY_TARGET="www.microsoft.com:443"
REALITY_SERVER_NAME="www.microsoft.com"
SERVER_ADDR=""
PROFILE_NAME="HAPP Resilient"
HY2_HOP_START=20000
HY2_HOP_END=50000

usage() {
  cat <<'EOF'
Использование: sudo ./install.sh [параметры]

Параметры:
  --server-address IP_ИЛИ_ИМЯ       Публичный адрес в ссылках клиентов
  --reality-target ИМЯ:ПОРТ         Камуфляжная цель REALITY
  --reality-sni ИМЯ                 SNI для клиентов REALITY
  --profile-name ИМЯ                Название профиля в HAPP
  -h, --help                        Показать эту справку
EOF
}

while (($#)); do
  case "$1" in
    --server-address)
      SERVER_ADDR="${2:?missing value for --server-address}"
      shift 2
      ;;
    --reality-target)
      REALITY_TARGET="${2:?missing value for --reality-target}"
      shift 2
      ;;
    --reality-sni)
      REALITY_SERVER_NAME="${2:?missing value for --reality-sni}"
      shift 2
      ;;
    --profile-name)
      PROFILE_NAME="${2:?missing value for --profile-name}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Неизвестный параметр: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Запустите от root: sudo ./install.sh" >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "Неподдерживаемая система: отсутствует /etc/os-release" >&2
  exit 1
fi

. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *)
    echo "Поддерживаются Ubuntu и Debian (обнаружено: ${ID:-неизвестно})" >&2
    exit 1
    ;;
esac

if [[ ! "$REALITY_TARGET" =~ ^[A-Za-z0-9.-]+:[0-9]{1,5}$ ]]; then
  echo "Некорректный --reality-target; ожидается ИМЯ:ПОРТ" >&2
  exit 2
fi
if [[ ! "$REALITY_SERVER_NAME" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "Некорректный --reality-sni" >&2
  exit 2
fi
if [[ ${#PROFILE_NAME} -gt 25 || "$PROFILE_NAME" == *$'\n'* ]]; then
  echo "Название профиля должно быть одной строкой длиной не более 25 символов" >&2
  exit 2
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl openssl qrencode iproute2 nftables

if [[ -z "$SERVER_ADDR" ]]; then
  SERVER_ADDR="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
fi
if [[ -z "$SERVER_ADDR" ]]; then
  SERVER_ADDR="$(curl -6fsS --max-time 10 https://api64.ipify.org || true)"
fi
if [[ -z "$SERVER_ADDR" || "$SERVER_ADDR" == *$'\n'* || "$SERVER_ADDR" == *' '* ]]; then
  echo "Не удалось определить публичный адрес; укажите --server-address IP_ИЛИ_ИМЯ" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d /tmp/happ-vpn.XXXXXXXX)"
cleanup() {
  rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

curl -fsSL --retry 4 --retry-delay 2 \
  https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh \
  -o "$TMP_DIR/xray-install.sh"
bash "$TMP_DIR/xray-install.sh" install

curl -fsSL --retry 4 --retry-delay 2 \
  https://raw.githubusercontent.com/apernet/hysteria/master/scripts/install_server.sh \
  -o "$TMP_DIR/hysteria-install.sh"
bash "$TMP_DIR/hysteria-install.sh"

XRAY_BIN="$(command -v xray)"
HYSTERIA_BIN="$(command -v hysteria)"

XRAY_KEYS="$($XRAY_BIN x25519)"
REALITY_PRIVATE_KEY="$(awk -F': *' '/^(PrivateKey|Private key)/ {print $2; exit}' <<<"$XRAY_KEYS")"
REALITY_PUBLIC_KEY="$(awk -F': *' '/^(Password|Public key)/ {print $2; exit}' <<<"$XRAY_KEYS")"
if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
  echo "Не удалось разобрать вывод Xray x25519" >&2
  exit 1
fi

VLESS_UUID="$(cat /proc/sys/kernel/random/uuid)"
REALITY_SHORT_ID="$(openssl rand -hex 8)"
HY2_PASSWORD="$(openssl rand -hex 24)"
HY2_OBFS_PASSWORD="$(openssl rand -hex 24)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="/root/happ-vpn/backups/$STAMP"
OUTPUT_DIR="/root/happ-vpn"

mkdir -p "$BACKUP_DIR" "$OUTPUT_DIR" /usr/local/etc/xray /etc/hysteria
for item in /usr/local/etc/xray/config.json /etc/hysteria/config.yaml /etc/hysteria/server.crt /etc/hysteria/server.key /etc/zhuck-vpn/udp-hop.nft /etc/systemd/system/happ-vpn-udp-hop.service; do
  if [[ -e "$item" ]]; then
    cp -a -- "$item" "$BACKUP_DIR/"
  fi
done

systemctl stop xray.service hysteria-server.service happ-vpn-udp-hop.service 2>/dev/null || true
if ss -H -ltnup | grep -Eq '(^|[[:space:]])[^[:space:]]*:443([[:space:]]|$)'; then
  echo "После остановки Xray/Hysteria порт 443 всё ещё занят:" >&2
  ss -H -ltnup | grep -E '(^|[[:space:]])[^[:space:]]*:443([[:space:]]|$)' >&2 || true
  exit 1
fi

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$VLESS_UUID", "flow": "xtls-rprx-vision", "email": "happ" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$REALITY_TARGET",
          "xver": 0,
          "serverNames": ["$REALITY_SERVER_NAME"],
          "privateKey": "$REALITY_PRIVATE_KEY",
          "shortIds": ["$REALITY_SHORT_ID"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "blocked" }
  ]
}
EOF
XRAY_SERVICE_GROUP="$(id -gn nobody 2>/dev/null || true)"
if [[ -z "$XRAY_SERVICE_GROUP" ]]; then
  echo "Не удалось определить группу службы Xray" >&2
  exit 1
fi
chown root:"$XRAY_SERVICE_GROUP" /usr/local/etc/xray/config.json
chmod 640 /usr/local/etc/xray/config.json

openssl req -x509 -nodes -newkey ec \
  -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout /etc/hysteria/server.key \
  -out /etc/hysteria/server.crt \
  -days 3650 \
  -subj "/CN=$REALITY_SERVER_NAME" \
  -addext "subjectAltName=DNS:$REALITY_SERVER_NAME" >/dev/null 2>&1
HY2_CERT_PIN="$(openssl x509 -noout -fingerprint -sha256 -in /etc/hysteria/server.crt | cut -d= -f2)"

cat > /etc/hysteria/config.yaml <<EOF
listen: :443

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
  sniGuard: disable

auth:
  type: password
  password: $HY2_PASSWORD

obfs:
  type: salamander
  salamander:
    password: $HY2_OBFS_PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://$REALITY_SERVER_NAME/
    rewriteHost: true
EOF

if getent group hysteria >/dev/null 2>&1; then
  chown root:hysteria /etc/hysteria/config.yaml /etc/hysteria/server.key /etc/hysteria/server.crt
fi
chmod 640 /etc/hysteria/config.yaml /etc/hysteria/server.key
chmod 644 /etc/hysteria/server.crt

mkdir -p /etc/zhuck-vpn
cat > /etc/zhuck-vpn/udp-hop.nft <<EOF
table inet zhuck_vpn_hop {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    udp dport $HY2_HOP_START-$HY2_HOP_END redirect to :443
  }
}
EOF

cat > /etc/systemd/system/happ-vpn-udp-hop.service <<'EOF'
[Unit]
Description=ZHUCK VPN: переброс UDP-портов Hysteria2
Before=hysteria-server.service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/sbin/nft delete table inet zhuck_vpn_hop
ExecStart=/usr/sbin/nft -f /etc/zhuck-vpn/udp-hop.nft
ExecStop=-/usr/sbin/nft delete table inet zhuck_vpn_hop

[Install]
WantedBy=multi-user.target
EOF

"$XRAY_BIN" run -test -config /usr/local/etc/xray/config.json
systemctl daemon-reload
systemctl enable --now happ-vpn-udp-hop.service
systemctl enable --now xray.service hysteria-server.service

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow 443/tcp
  ufw allow 443/udp
  ufw allow "$HY2_HOP_START:$HY2_HOP_END/udp"
fi

cat > /etc/sysctl.d/99-happ-vpn.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system >/dev/null 2>&1 || true

sleep 2
for service in xray.service hysteria-server.service happ-vpn-udp-hop.service; do
  if ! systemctl is-active --quiet "$service"; then
    echo "Служба $service не запустилась" >&2
    journalctl -u "$service" -n 50 --no-pager >&2 || true
    exit 1
  fi
done

LINK_HOST="$SERVER_ADDR"
if [[ "$LINK_HOST" == *:* && "$LINK_HOST" != \[*\] ]]; then
  LINK_HOST="[$LINK_HOST]"
fi

VLESS_LINK="vless://${VLESS_UUID}@${LINK_HOST}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none#VLESS-REALITY-${SERVER_ADDR}"
HY2_LINK="hysteria2://${HY2_PASSWORD}@${LINK_HOST}:443,${HY2_HOP_START}-${HY2_HOP_END}/?insecure=1&pinSHA256=${HY2_CERT_PIN}&obfs=salamander&obfs-password=${HY2_OBFS_PASSWORD}&sni=${REALITY_SERVER_NAME}#Hysteria2-${SERVER_ADDR}"
ROUTING_JSON='{"Name":"ZHUCK VPN - RU direct","GlobalProxy":"true","RemoteDNSType":"DoH","RemoteDNSDomain":"https://cloudflare-dns.com/dns-query","RemoteDNSIP":"1.1.1.1","DomesticDNSType":"DoU","DomesticDNSDomain":"","DomesticDNSIP":"77.88.8.8","Geoipurl":"https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat","Geositeurl":"https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat","LastUpdated":"","DnsHosts":{"cloudflare-dns.com":"1.1.1.1"},"DirectSites":["geosite:category-ru","geosite:private"],"DirectIp":["geoip:ru","geoip:private","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","224.0.0.0/4","255.255.255.255"],"ProxySites":[],"ProxyIp":[],"BlockSites":[],"BlockIp":[],"DomainStrategy":"IPIfNonMatch","FakeDNS":"false"}'
ROUTING_LINK="happ://routing/onadd/$(printf '%s' "$ROUTING_JSON" | base64 -w 0)"

cat > "$OUTPUT_DIR/subscription.txt" <<EOF
#profile-title: $PROFILE_NAME
#profile-update-interval: 6
#routing-enable: 1
#announce: RU services direct; other traffic via VPN
$ROUTING_LINK
$VLESS_LINK
$HY2_LINK
EOF

cat > "$OUTPUT_DIR/INSTALL_REPORT.txt" <<EOF
Installed: $STAMP
Server: $SERVER_ADDR
REALITY target: $REALITY_TARGET

HAPP links:
$VLESS_LINK
$HY2_LINK

Subscription body:
$OUTPUT_DIR/subscription.txt

Required cloud firewall rules:
TCP 443 inbound
UDP 443 inbound
UDP $HY2_HOP_START-$HY2_HOP_END входящие (переброс UDP-портов Hysteria2)
EOF

qrencode -o "$OUTPUT_DIR/vless-reality.png" "$VLESS_LINK"
qrencode -o "$OUTPUT_DIR/hysteria2.png" "$HY2_LINK"
chmod 600 "$OUTPUT_DIR/subscription.txt" "$OUTPUT_DIR/INSTALL_REPORT.txt" "$OUTPUT_DIR"/*.png

echo
echo "Установка завершена. Импортируйте одну или обе ссылки в HAPP:"
echo
echo "$VLESS_LINK"
echo
echo "$HY2_LINK"
echo
echo "Ссылки и QR-коды сохранены в $OUTPUT_DIR"
