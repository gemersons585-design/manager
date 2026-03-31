#!/usr/bin/env bash
# ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
# ┃ XRAY TUNNEL MANAGER PRO v4 (VMess + WS + Reverse Portal/Bridge)   ┃
# ┃ - Rotação segura de UUID                                          ┃
# ┃ - Backup automático antes de alterar config                       ┃
# ┃ - SOCKS do servidor preso em 127.0.0.1                            ┃
# ┃ - Autenticação opcional no SOCKS local                            ┃
# ┃ - Exporta JSON do Windows para arquivo                            ┃
# ┃ - Auditoria rápida de segurança                                   ┃
# ┃ - Visualização de peers conectados / logs recentes                ┃
# ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

set -Eeuo pipefail

# =========================
# CORES / UI
# =========================
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
WHITE=$'\033[1;37m'
DIM=$'\033[2m'
NC=$'\033[0m'

# =========================
# PATHS / ARQUIVOS
# =========================
UUID_FILE="/root/.xray_uuid_fixed"
UUID_HISTORY_DIR="/root/.xray_uuid_history"
CONFIG_FILE="/usr/local/etc/xray/config.json"
SETTINGS_FILE="/root/.xray_tunnel_manager.env"
STATE_FILE="/root/.xray_tunnel_manager.state"
BACKUP_DIR="/root/.xray_tunnel_manager_backups"
CLIENT_EXPORT_FILE="/root/xray_windows_bridge_config.json"
XRAY_LOG_DIR="/var/log/xray"
ACCESS_LOG_FILE="${XRAY_LOG_DIR}/access.log"
ERROR_LOG_FILE="${XRAY_LOG_DIR}/error.log"

XRAY_BIN="/usr/local/bin/xray"
SERVICE="xray"

# =========================
# PADRÕES (alteráveis no menu)
# =========================
PORT_TUNNEL_DEFAULT=443
PORT_SOCKS_DEFAULT=1080
WS_PATH_DEFAULT="/tunnel"
REVERSE_DOMAIN_DEFAULT="reverse.intranet"
SOCKS_LISTEN_DEFAULT="127.0.0.1"
SOCKS_AUTH_DEFAULT="noauth"
SOCKS_USER_DEFAULT=""
SOCKS_PASS_DEFAULT=""
TZ_NAME_DEFAULT="America/Sao_Paulo"
AUTO_CHECK_DEFAULT=1
AUTO_CHECK_INTERVAL_DEFAULT=60

# =========================
# SITES DA VISTORIA (via SOCKS)
# =========================
SITES=(
  "INTRANET (HOME)|http://intranet.policiamilitar.sp.gov.br/"
  "COPOM ONLINE|https://copomonline.policiamilitar.sp.gov.br/Login/Login"
  "MURALHA PAULISTA|https://operacional.muralhapaulista.sp.gov.br/Home/Login"
  "SIOPM-WEB|http://sistemasopr.intranet.policiamilitar.sp.gov.br/siopmweb/HSiopm.aspx"
  "INFOCRIM|https://www.infocrim.ssp.sp.gov.br/login"
)

# =========================
# SETTINGS
# =========================
PORT_TUNNEL="$PORT_TUNNEL_DEFAULT"
PORT_SOCKS="$PORT_SOCKS_DEFAULT"
WS_PATH="$WS_PATH_DEFAULT"
REVERSE_DOMAIN="$REVERSE_DOMAIN_DEFAULT"
SOCKS_LISTEN="$SOCKS_LISTEN_DEFAULT"
SOCKS_AUTH="$SOCKS_AUTH_DEFAULT"
SOCKS_USER="$SOCKS_USER_DEFAULT"
SOCKS_PASS="$SOCKS_PASS_DEFAULT"
TZ_NAME="$TZ_NAME_DEFAULT"
AUTO_CHECK="$AUTO_CHECK_DEFAULT"
AUTO_CHECK_INTERVAL="$AUTO_CHECK_INTERVAL_DEFAULT"

# =========================
# STATE
# =========================
LAST_CHECK_AT=""
LAST_CHECK_EPOCH=""
SITE_RESULTS=""

# =========================
# UI helpers
# =========================
term_cols() { tput cols 2>/dev/null || echo "${COLUMNS:-100}"; }

rule() {
  local ch="${1:-─}"
  local w; w="$(term_cols)"
  printf "%b" "${DIM}"
  printf "%*s" "$w" "" | tr ' ' "$ch"
  printf "%b\n" "${NC}"
}

title_bar() {
  local t="$1"
  printf "%b\n" "${BLUE}${WHITE}${t}${NC}"
  rule "━"
}

section() {
  local t="$1"
  printf "%b\n" "${WHITE}${t}${NC}"
  rule "─"
}

pause() { read -r -p "Enter para continuar..." _; }
pad() { local w="$1"; shift; printf "%-*s" "$w" "$*"; }

trunc() {
  local w="$1"; shift
  local s="$*"
  if (( ${#s} > w )); then
    printf "%s" "${s:0:w-1}…"
  else
    printf "%s" "$s"
  fi
}

dot() {
  local ok="$1"
  if [[ "$ok" == "1" ]]; then
    printf "%b" "${GREEN}●${NC}"
  else
    printf "%b" "${RED}●${NC}"
  fi
}

kv1() {
  local l="$1" v="$2"
  printf "%b\n" "  ${DIM}•${NC} ${WHITE}$(pad 14 "${l}:")${NC} ${CYAN}${v}${NC}"
}

kv2() {
  local l1="$1" v1="$2" l2="$3" v2="$4"
  printf "%b\n" "  ${DIM}•${NC} ${WHITE}$(pad 12 "${l1}:")${NC} ${CYAN}${v1}${NC}    ${DIM}•${NC} ${WHITE}$(pad 12 "${l2}:")${NC} ${CYAN}${v2}${NC}"
}

# =========================
# ERROS
# =========================
on_error() {
  local line="$1" cmd="$2"
  printf "%b\n" "" >&2
  printf "%b\n" "${RED}${WHITE}[ERRO]${NC} Linha ${WHITE}${line}${NC}: ${DIM}${cmd}${NC}" >&2
  printf "%b\n" "${DIM}Dica:${NC} journalctl -u ${SERVICE} -n 120 --no-pager" >&2
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# =========================
# HELPERS
# =========================
have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    printf "%b\n" "${RED}[ERRO] Rode como root.${NC} Ex: sudo bash $0"
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "$UUID_HISTORY_DIR" "$BACKUP_DIR" "$XRAY_LOG_DIR"
  chown -R nobody:nogroup "$XRAY_LOG_DIR" 2>/dev/null || chown -R nobody "$XRAY_LOG_DIR" 2>/dev/null || true
}

ensure_deps() {
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y curl jq net-tools psmisc lsof iproute2 libcap2-bin gawk util-linux >/dev/null 2>&1 || true
}

get_ip() {
  local ip=""
  ip="$(curl -4s --max-time 3 ifconfig.me 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -4s --max-time 3 icanhazip.com 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -4s --max-time 3 api.ipify.org 2>/dev/null || true)"
  echo "$ip"
}

now_human() { TZ="$TZ_NAME" date '+%d/%m/%Y %H:%M:%S %Z'; }
now_epoch() { TZ="$TZ_NAME" date '+%s'; }
stamp() { date '+%F_%H%M%S'; }

json_escape() {
  jq -Rsa . <<<"$1"
}

random_token() {
  tr -dc 'A-Za-z0-9@#%_=+.-' </dev/urandom | head -c "${1:-24}"
}

generate_uuid() {
  if have_cmd xray; then
    xray uuid 2>/dev/null && return 0
  fi
  if have_cmd uuidgen; then
    uuidgen 2>/dev/null && return 0
  fi
  cat /proc/sys/kernel/random/uuid
}

ensure_uuid() {
  if [[ -f "$UUID_FILE" ]]; then
    UUID="$(tr -d '[:space:]' < "$UUID_FILE")"
  else
    UUID="$(generate_uuid)"
    echo "$UUID" > "$UUID_FILE"
  fi
}

load_settings() {
  if [[ -f "$SETTINGS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SETTINGS_FILE"
  fi
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi

  : "${PORT_TUNNEL:=$PORT_TUNNEL_DEFAULT}"
  : "${PORT_SOCKS:=$PORT_SOCKS_DEFAULT}"
  : "${WS_PATH:=$WS_PATH_DEFAULT}"
  : "${REVERSE_DOMAIN:=$REVERSE_DOMAIN_DEFAULT}"
  : "${SOCKS_LISTEN:=$SOCKS_LISTEN_DEFAULT}"
  : "${SOCKS_AUTH:=$SOCKS_AUTH_DEFAULT}"
  : "${SOCKS_USER:=$SOCKS_USER_DEFAULT}"
  : "${SOCKS_PASS:=$SOCKS_PASS_DEFAULT}"
  : "${TZ_NAME:=$TZ_NAME_DEFAULT}"
  : "${AUTO_CHECK:=$AUTO_CHECK_DEFAULT}"
  : "${AUTO_CHECK_INTERVAL:=$AUTO_CHECK_INTERVAL_DEFAULT}"
  : "${LAST_CHECK_AT:=}"
  : "${LAST_CHECK_EPOCH:=}"
  : "${SITE_RESULTS:=}"
}

save_settings() {
  cat > "$SETTINGS_FILE" <<EOF2
# XRAY TUNNEL MANAGER - SETTINGS
PORT_TUNNEL=${PORT_TUNNEL}
PORT_SOCKS=${PORT_SOCKS}
WS_PATH=$(printf "%q" "$WS_PATH")
REVERSE_DOMAIN=$(printf "%q" "$REVERSE_DOMAIN")
SOCKS_LISTEN=$(printf "%q" "$SOCKS_LISTEN")
SOCKS_AUTH=$(printf "%q" "$SOCKS_AUTH")
SOCKS_USER=$(printf "%q" "$SOCKS_USER")
SOCKS_PASS=$(printf "%q" "$SOCKS_PASS")
TZ_NAME=$(printf "%q" "$TZ_NAME")
AUTO_CHECK=${AUTO_CHECK}
AUTO_CHECK_INTERVAL=${AUTO_CHECK_INTERVAL}
EOF2
}

save_state() {
  cat > "$STATE_FILE" <<EOF2
# XRAY TUNNEL MANAGER - STATE
LAST_CHECK_AT=$(printf "%q" "$LAST_CHECK_AT")
LAST_CHECK_EPOCH=$(printf "%q" "$LAST_CHECK_EPOCH")
SITE_RESULTS=$(printf "%q" "$SITE_RESULTS")
EOF2
}

service_active() { systemctl is-active --quiet "$SERVICE"; }

port_listen_info() {
  local port="$1" out=""
  if have_cmd ss; then
    out="$(ss -Hltnp "sport = :$port" 2>/dev/null | awk '{print $NF}' | head -n1 || true)"
  fi
  if [[ -z "$out" ]]; then
    out="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR==2{print $2"/"$1}' || true)"
  fi
  echo "$out"
}

port_is_listening() {
  local port="$1"
  [[ -n "$(port_listen_info "$port")" ]]
}

bridge_is_online() {
  local port="$1" n=0
  if have_cmd ss; then
    n="$(ss -Htn state established "( sport = :$port )" 2>/dev/null | wc -l | tr -d ' ' || true)"
  else
    n="$(netstat -tn 2>/dev/null | awk '{print $6,$4}' | grep -E "ESTABLISHED .*:${port}$" -c || true)"
  fi
  [[ "${n:-0}" -gt 0 ]]
}

kill_port() {
  local port="$1"
  if have_cmd fuser; then
    fuser -k "${port}/tcp" >/dev/null 2>&1 || true
  else
    lsof -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | xargs -r kill -9 >/dev/null 2>&1 || true
  fi
}

force_cleanup_ports() {
  printf "%b\n" "${YELLOW}[*] Parando serviço e limpando portas ${PORT_TUNNEL}/${PORT_SOCKS}...${NC}"
  systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  kill_port "$PORT_TUNNEL"
  kill_port "$PORT_SOCKS"
  printf "%b\n" "${GREEN}[OK] Limpeza concluída.${NC}"
}

apply_setcap_if_needed() {
  if [[ -x "$XRAY_BIN" ]]; then
    setcap CAP_NET_BIND_SERVICE=+eip "$XRAY_BIN" >/dev/null 2>&1 || true
  fi
}

is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 )); }

backup_current_config() {
  ensure_dirs
  if [[ -f "$CONFIG_FILE" ]]; then
    cp "$CONFIG_FILE" "$BACKUP_DIR/config.$(stamp).json"
  fi
  if [[ -f "$UUID_FILE" ]]; then
    cp "$UUID_FILE" "$UUID_HISTORY_DIR/uuid.$(stamp).txt"
  fi
}

restore_latest_backup() {
  local last
  last="$(ls -1t "$BACKUP_DIR"/config.*.json 2>/dev/null | head -n1 || true)"
  if [[ -z "$last" ]]; then
    printf "%b\n" "${RED}[ERRO] Nenhum backup encontrado.${NC}"
    pause
    return 0
  fi

  cp "$last" "$CONFIG_FILE"
  restart_xray
  printf "%b\n" "${GREEN}[OK] Backup restaurado:${NC} ${CYAN}${last}${NC}"
  pause
}

build_socks_settings_json() {
  if [[ "$SOCKS_AUTH" == "password" ]]; then
    cat <<EOF2
      "settings": {
        "auth": "password",
        "accounts": [
          {
            "user": ${SOCKS_USER_JSON},
            "pass": ${SOCKS_PASS_JSON}
          }
        ],
        "udp": true
      },
EOF2
  else
    cat <<EOF2
      "settings": { "auth": "noauth", "udp": true },
EOF2
  fi
}

write_server_config() {
  ensure_dirs
  mkdir -p "$(dirname "$CONFIG_FILE")"

  SOCKS_USER_JSON="$(json_escape "$SOCKS_USER")"
  SOCKS_PASS_JSON="$(json_escape "$SOCKS_PASS")"

  local tmp="${CONFIG_FILE}.tmp"

  cat > "$tmp" <<EOF2
{
  "log": {
    "loglevel": "warning",
    "access": "$ACCESS_LOG_FILE",
    "error": "$ERROR_LOG_FILE"
  },
  "reverse": {
    "portals": [
      { "tag": "portal", "domain": "$REVERSE_DOMAIN" }
    ]
  },
  "inbounds": [
    {
      "tag": "interceptor",
      "listen": "$SOCKS_LISTEN",
      "port": $PORT_SOCKS,
      "protocol": "socks",
$(build_socks_settings_json)      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    },
    {
      "tag": "tunnel-in",
      "port": $PORT_TUNNEL,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "email": "bridge-main@local"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "$WS_PATH" }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ],
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": ["interceptor"], "outboundTag": "portal" },
      { "type": "field", "inboundTag": ["tunnel-in"], "domain": ["full:$REVERSE_DOMAIN"], "outboundTag": "portal" },
      { "type": "field", "inboundTag": ["tunnel-in"], "outboundTag": "direct" }
    ]
  }
}
EOF2

  if ! jq empty "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp" >/dev/null 2>&1 || true
    printf "%b\n" "${RED}[ERRO] JSON gerado ficou inválido. Nada foi aplicado.${NC}"
    return 1
  fi

  backup_current_config
  mv "$tmp" "$CONFIG_FILE"
}

proxy_url() {
  if [[ "$SOCKS_AUTH" == "password" ]]; then
    printf 'socks5h://%s:%s@127.0.0.1:%s' "$SOCKS_USER" "$SOCKS_PASS" "$PORT_SOCKS"
  else
    printf 'socks5h://127.0.0.1:%s' "$PORT_SOCKS"
  fi
}

export_client_json() {
  local vps_ip="$1"
  mkdir -p "$(dirname "$CLIENT_EXPORT_FILE")"

  cat > "$CLIENT_EXPORT_FILE" <<EOF2
{
  "log": { "loglevel": "warning" },
  "reverse": { "bridges": [ { "tag": "bridge", "domain": "$REVERSE_DOMAIN" } ] },
  "inbounds": [
    {
      "tag": "proxy-bot",
      "port": 10808,
      "listen": "127.0.0.1",
      "protocol": "mixed"
    }
  ],
  "outbounds": [
    {
      "tag": "tunnel-out",
      "protocol": "vmess",
      "settings": {
        "vnext": [
          {
            "address": "$vps_ip",
            "port": $PORT_TUNNEL,
            "users": [
              {
                "id": "$UUID",
                "security": "auto"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "$WS_PATH" }
      }
    },
    { "tag": "out", "protocol": "freedom" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": ["proxy-bot"], "outboundTag": "tunnel-out" },
      { "type": "field", "domain": ["full:$REVERSE_DOMAIN"], "outboundTag": "tunnel-out" },
      { "type": "field", "inboundTag": ["bridge"], "outboundTag": "out" }
    ]
  }
}
EOF2
}

show_client_json() {
  local vps_ip="$1"
  export_client_json "$vps_ip"

  clear
  title_bar "CONFIG DO PC INTRANET (WINDOWS - BRIDGE)"
  printf "%b\n\n" "${DIM}Copie e salve como ${WHITE}config.json${NC}${DIM} no Windows:${NC}"
  cat "$CLIENT_EXPORT_FILE"
  echo
  rule "─"
  printf "%b\n" "${DIM}Arquivo exportado em:${NC} ${CYAN}${CLIENT_EXPORT_FILE}${NC}"
  printf "%b\n" "${DIM}Obs:${NC} se mudar UUID, porta ou WS path, gere novamente este JSON."
  pause
}

restart_xray() {
  systemctl restart "$SERVICE" >/dev/null 2>&1 || true
  sleep 1
}

install_or_repair() {
  clear
  title_bar "INSTALAR / REPARAR XRAY (PORTAL)"

  ensure_deps
  ensure_dirs

  printf "%b\n" "${YELLOW}[*] Instalando/atualizando Xray oficial...${NC}"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 || true

  echo
  force_cleanup_ports

  printf "%b\n" "${YELLOW}[*] Gerando config do servidor...${NC}"
  write_server_config
  apply_setcap_if_needed

  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
  restart_xray

  echo
  if service_active; then
    printf "%b\n" "${GREEN}${WHITE}[SUCESSO]${NC} Xray está ONLINE."
  else
    printf "%b\n" "${RED}${WHITE}[ERRO]${NC} Xray não subiu."
    printf "%b\n" "${DIM}Veja logs:${NC} journalctl -u $SERVICE -n 140 --no-pager"
  fi

  echo
  rule "─"
  printf "%b\n" "${WHITE}Resumo da Config:${NC}"
  kv2 "TÚNEL" "$PORT_TUNNEL" "SOCKS" "$PORT_SOCKS"
  kv2 "WS PATH" "$WS_PATH" "DOMAIN" "$REVERSE_DOMAIN"
  kv2 "SOCKS LISTEN" "$SOCKS_LISTEN" "SOCKS AUTH" "$SOCKS_AUTH"
  kv1 "UUID" "$UUID"
  rule "─"

  pause
}

site_count() { echo "${#SITES[@]}"; }

count_ok_sites() {
  local ok=0
  while IFS='|' read -r _name _code _ms status _msg; do
    [[ -z "${_name:-}" ]] && continue
    if [[ "$status" == "OK" ]]; then
      ok=$((ok+1))
    fi
  done <<< "${SITE_RESULTS:-}"
  echo "$ok"
}

test_one_site() {
  local name="$1" url="$2"

  if ! port_is_listening "$PORT_SOCKS"; then
    echo "${name}|000|0|FAIL|SOCKS OFF"
    return 0
  fi

  local tmp_err="/tmp/.xray_tm_curl_err.$$.$RANDOM"
  local out code total_time_ms rc proxy
  proxy="$(proxy_url)"

  set +e
  out="$(curl -k -sS -o /dev/null \
    -w "%{http_code}|%{time_total}" \
    --connect-timeout 5 --max-time 15 \
    --proxy "$proxy" \
    "$url" 2>"$tmp_err")"
  rc=$?
  set -e

  code="${out%%|*}"
  total_time_ms="$(awk -v t="${out##*|}" 'BEGIN{ printf "%.0f", (t*1000) }' 2>/dev/null || echo 0)"

  if [[ $rc -ne 0 ]]; then
    local msg
    msg="$(tr '\n' ' ' <"$tmp_err" | sed 's/[[:space:]]\+/ /g' | cut -c1-90)"
    rm -f "$tmp_err" >/dev/null 2>&1 || true
    echo "${name}|${code:-000}|${total_time_ms:-0}|FAIL|${msg:-curl error}"
    return 0
  fi

  rm -f "$tmp_err" >/dev/null 2>&1 || true

  local status="WARN" msg="Verificar"
  if [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]]; then
    status="OK"; msg="OK"
  fi

  echo "${name}|${code:-000}|${total_time_ms:-0}|${status}|${msg}"
}

run_all_tests() {
  local nowh nowe total
  nowh="$(now_human)"
  nowe="$(now_epoch)"
  total="$(site_count)"

  local tmpdir="/tmp/xray_tm_sites.$$"
  rm -rf "$tmpdir" >/dev/null 2>&1 || true
  mkdir -p "$tmpdir"

  local idx=0
  for item in "${SITES[@]}"; do
    local name="${item%%|*}"
    local url="${item#*|}"

    (
      test_one_site "$name" "$url" > "$tmpdir/$idx"
    ) &

    idx=$((idx+1))
  done

  wait || true

  local results=""
  local i
  for ((i=0; i<total; i++)); do
    if [[ -f "$tmpdir/$i" ]]; then
      results+="$(cat "$tmpdir/$i")"$'\n'
    fi
  done

  rm -rf "$tmpdir" >/dev/null 2>&1 || true

  LAST_CHECK_AT="$nowh"
  LAST_CHECK_EPOCH="$nowe"
  SITE_RESULTS="$results"
  save_state
}

maybe_auto_check() {
  [[ "${AUTO_CHECK:-1}" -ne 1 ]] && return 0

  if [[ -z "${LAST_CHECK_EPOCH:-}" ]]; then
    run_all_tests
    return 0
  fi

  local now diff
  now="$(now_epoch)"
  diff=$(( now - LAST_CHECK_EPOCH ))
  if (( diff >= AUTO_CHECK_INTERVAL )); then
    run_all_tests
  fi
}

render_sites_block() {
  printf "%b\n" "${WHITE}VISTORIA (via SOCKS 127.0.0.1:${PORT_SOCKS})${NC}"

  if [[ -z "${LAST_CHECK_AT:-}" ]]; then
    printf "%b\n" "  ${DIM}(ainda não executada)${NC}"
    return 0
  fi

  local ok total
  ok="$(count_ok_sites)"
  total="$(site_count)"

  local badge="$YELLOW"
  [[ "$ok" -eq "$total" ]] && badge="$GREEN"
  [[ "$ok" -eq 0 ]] && badge="$RED"

  printf "%b\n" "  ${DIM}Última execução:${NC} ${CYAN}${LAST_CHECK_AT}${NC}"
  printf "%b\n" "  ${DIM}Resultado:${NC} ${badge}${ok}/${total} OK${NC}"
  echo

  local W; W="$(term_cols)"
  local name_w=22 code_w=5 ms_w=7
  local msg_w=$(( W - (2 + 3 + name_w + 3 + code_w + 3 + ms_w + 3 + 2) ))
  (( msg_w < 18 )) && msg_w=18

  printf "%b\n" "  ${DIM}#  $(pad $name_w "SITE") | $(pad $code_w "HTTP") | $(pad $ms_w "LAT") | $(pad $msg_w "OBS")${NC}"
  rule "·"

  local i=1
  while IFS='|' read -r name code ms status msg; do
    [[ -z "${name:-}" ]] && continue

    local c="$YELLOW"
    [[ "$status" == "OK" ]] && c="$GREEN"
    [[ "$status" == "FAIL" ]] && c="$RED"

    printf "%b\n" "  ${DIM}$(pad 2 "$i")${NC} $(pad $name_w "$(trunc $name_w "$name")") ${DIM}|${NC} ${c}$(pad $code_w "${code:-000}")${NC} ${DIM}|${NC} ${DIM}$(pad $ms_w "${ms:-0}ms")${NC} ${DIM}|${NC} ${DIM}$(trunc $msg_w "${msg:-}")${NC}"
    i=$((i+1))
  done <<< "${SITE_RESULTS:-}"
}

render_header() {
  local vps_ip="$1"

  local srv=0 tnl=0 sks=0 br=0
  service_active && srv=1
  port_is_listening "$PORT_TUNNEL" && tnl=1
  port_is_listening "$PORT_SOCKS" && sks=1
  bridge_is_online "$PORT_TUNNEL" && br=1

  local li_tun li_socks
  li_tun="$(port_listen_info "$PORT_TUNNEL")"
  li_socks="$(port_listen_info "$PORT_SOCKS")"

  clear
  title_bar "XRAY TESTE PMESP (VMess+WS + Reverse Portal/Bridge)"

  section "IDENTIDADE"
  kv2 "VPS IP" "${vps_ip:-N/A}" "TZ" "$TZ_NAME"
  kv1 "UUID" "$UUID"

  section "CONFIG"
  kv2 "TÚNEL" "$PORT_TUNNEL" "SOCKS" "$PORT_SOCKS"
  kv2 "WS PATH" "$WS_PATH" "DOMAIN" "$REVERSE_DOMAIN"
  kv2 "SOCKS LISTEN" "$SOCKS_LISTEN" "SOCKS AUTH" "$SOCKS_AUTH"
  printf "%b\n" "  ${DIM}•${NC} ${WHITE}Listen túnel:${NC} ${DIM}${li_tun:-N/A}${NC}"
  printf "%b\n" "  ${DIM}•${NC} ${WHITE}Listen socks:${NC} ${DIM}${li_socks:-N/A}${NC}"

  section "SAÚDE"
  printf "%b\n" "  $(dot "$srv") ${WHITE}Serviço Xray${NC}      $(dot "$tnl") ${WHITE}Porta Túnel${NC}      $(dot "$sks") ${WHITE}Porta SOCKS${NC}      $(dot "$br") ${WHITE}Bridge (Windows)${NC}"

  rule "─"
  render_sites_block
  rule "━"
}

diagnostico() {
  local vps_ip="$1"
  clear
  title_bar "DIAGNÓSTICO COMPLETO"

  kv2 "VPS IP" "${vps_ip:-N/A}" "AGORA" "$(now_human)"
  kv1 "UUID" "$UUID"
  echo

  if service_active; then
    printf "%b\n" "  $(dot 1) ${GREEN}Serviço Xray ONLINE${NC}"
  else
    printf "%b\n" "  $(dot 0) ${RED}Serviço Xray OFFLINE${NC}"
  fi

  local li_tun li_socks
  li_tun="$(port_listen_info "$PORT_TUNNEL")"
  li_socks="$(port_listen_info "$PORT_SOCKS")"

  echo
  section "PORTAS"
  if [[ -n "$li_tun" ]]; then
    printf "%b\n" "  ${GREEN}OK${NC}  Túnel ${CYAN}${PORT_TUNNEL}${NC}  ${DIM}${li_tun}${NC}"
  else
    printf "%b\n" "  ${RED}OFF${NC} Túnel ${CYAN}${PORT_TUNNEL}${NC}"
  fi
  if [[ -n "$li_socks" ]]; then
    printf "%b\n" "  ${GREEN}OK${NC}  SOCKS ${CYAN}${PORT_SOCKS}${NC}  ${DIM}${li_socks}${NC}"
  else
    printf "%b\n" "  ${RED}OFF${NC} SOCKS ${CYAN}${PORT_SOCKS}${NC}"
  fi

  echo
  section "POLÍTICA LOCAL DO SOCKS"
  kv2 "LISTEN" "$SOCKS_LISTEN" "AUTH" "$SOCKS_AUTH"
  if [[ "$SOCKS_AUTH" == "password" ]]; then
    kv1 "USUÁRIO SOCKS" "$SOCKS_USER"
  fi

  echo
  section "BRIDGE (WINDOWS)"
  if bridge_is_online "$PORT_TUNNEL"; then
    printf "%b\n" "  ${GREEN}CONECTADO${NC} (sessão ESTABLISHED no túnel)"
    echo
    if have_cmd ss; then
      ss -Htn state established "( sport = :$PORT_TUNNEL )" 2>/dev/null | head -n 12 || true
    else
      netstat -tn 2>/dev/null | grep -E "ESTABLISHED.*:${PORT_TUNNEL}$" | head -n 12 || true
    fi
  else
    printf "%b\n" "  ${RED}DESCONECTADO${NC}"
  fi

  echo
  rule "─"
  printf "%b\n" "${DIM}Logs:${NC} journalctl -u $SERVICE -n 160 --no-pager"
  pause
}

port_doctor() {
  clear
  title_bar "PORT DOCTOR"

  local a b
  a="$(port_listen_info "$PORT_TUNNEL")"
  b="$(port_listen_info "$PORT_SOCKS")"

  printf "%b\n" "  • Túnel ${CYAN}${PORT_TUNNEL}${NC}:  ${DIM}${a:-LIVRE / NÃO LISTEN}${NC}"
  printf "%b\n" "  • SOCKS ${CYAN}${PORT_SOCKS}${NC}:  ${DIM}${b:-LIVRE / NÃO LISTEN}${NC}"
  echo

  printf "%b\n" "${WHITE}Ações:${NC}"
  printf "%b\n" "  1) Matar processo na porta do Túnel (${PORT_TUNNEL})"
  printf "%b\n" "  2) Matar processo na porta do SOCKS (${PORT_SOCKS})"
  printf "%b\n" "  3) Limpeza completa (stop xray + kill nas duas portas)"
  printf "%b\n" "  0) Voltar"
  echo
  read -r -p "Escolha: " op

  case "$op" in
    1) kill_port "$PORT_TUNNEL"; printf "%b\n" "${GREEN}[OK] Kill solicitado na porta ${PORT_TUNNEL}.${NC}"; pause ;;
    2) kill_port "$PORT_SOCKS";  printf "%b\n" "${GREEN}[OK] Kill solicitado na porta ${PORT_SOCKS}.${NC}"; pause ;;
    3) force_cleanup_ports; pause ;;
    0) ;;
    *) printf "%b\n" "${RED}Inválido${NC}"; pause ;;
  esac
}

test_manual_one() {
  clear
  title_bar "TESTE MANUAL (1 URL) via SOCKS"
  printf "%b\n" "${DIM}Proxy:${NC} $(proxy_url)"
  echo
  read -r -p "URL: " url
  [[ -z "${url:-}" ]] && printf "%b\n" "${RED}[ERRO] URL vazia.${NC}" && pause && return 0

  echo
  printf "%b\n" "${YELLOW}[*] Testando...${NC}"
  local line _name code ms status msg
  line="$(test_one_site "MANUAL" "$url")"
  IFS='|' read -r _name code ms status msg <<< "$line"

  local c="$YELLOW"
  [[ "$status" == "OK" ]] && c="$GREEN"
  [[ "$status" == "FAIL" ]] && c="$RED"

  echo
  printf "%b\n" "  HTTP: ${c}${code}${NC}"
  printf "%b\n" "  LAT:  ${DIM}${ms}ms${NC}"
  printf "%b\n" "  OBS:  ${DIM}${msg}${NC}"
  printf "%b\n" "  Hora: ${CYAN}$(now_human)${NC}"
  pause
}

change_ports() {
  clear
  title_bar "ALTERAR PORTAS"
  printf "%b\n\n" "${DIM}Atual: túnel=${PORT_TUNNEL} | socks=${PORT_SOCKS}${NC}"

  local new_t new_s
  read -r -p "Nova porta do Túnel (VMess+WS) [${PORT_TUNNEL}]: " new_t
  read -r -p "Nova porta do SOCKS interno [${PORT_SOCKS}]: " new_s
  new_t="${new_t:-$PORT_TUNNEL}"
  new_s="${new_s:-$PORT_SOCKS}"

  if ! is_valid_port "$new_t" || ! is_valid_port "$new_s"; then
    printf "%b\n" "${RED}[ERRO] Portas inválidas. Use 1-65535.${NC}"
    pause
    return 0
  fi

  PORT_TUNNEL="$new_t"
  PORT_SOCKS="$new_s"
  save_settings

  echo
  printf "%b\n" "${YELLOW}[*] Aplicando nova config e reiniciando Xray...${NC}"
  force_cleanup_ports
  write_server_config
  apply_setcap_if_needed
  restart_xray

  echo
  if service_active; then
    printf "%b\n" "${GREEN}[OK] Alterações aplicadas.${NC}"
  else
    printf "%b\n" "${RED}[ERRO] Xray não subiu após a mudança.${NC}"
  fi

  run_all_tests
  pause
}

change_ws_path() {
  clear
  title_bar "ALTERAR WS PATH"
  printf "%b\n\n" "${DIM}Atual: ${WS_PATH}${NC}"

  local p
  read -r -p "Novo WS path (ex: /tunnel) [${WS_PATH}]: " p
  p="${p:-$WS_PATH}"
  [[ "$p" != /* ]] && p="/$p"

  WS_PATH="$p"
  save_settings

  echo
  printf "%b\n" "${YELLOW}[*] Aplicando nova config e reiniciando Xray...${NC}"
  force_cleanup_ports
  write_server_config
  apply_setcap_if_needed
  restart_xray

  echo
  if service_active; then
    printf "%b\n" "${GREEN}[OK] WS path atualizado.${NC}"
  else
    printf "%b\n" "${RED}[ERRO] Xray não subiu após a mudança.${NC}"
  fi

  run_all_tests
  pause
}

toggle_auto_check() {
  clear
  title_bar "AUTO-VISTORIA NO MENU"

  kv2 "AUTO" "${AUTO_CHECK} (1=ON 0=OFF)" "INTERVALO" "${AUTO_CHECK_INTERVAL}s"
  kv1 "TZ" "$TZ_NAME"
  echo

  local a i tz
  read -r -p "Auto-vistoria (1/0) [${AUTO_CHECK}]: " a
  read -r -p "Intervalo em segundos [${AUTO_CHECK_INTERVAL}]: " i
  read -r -p "Timezone (ex: America/Sao_Paulo) [${TZ_NAME}]: " tz

  a="${a:-$AUTO_CHECK}"
  i="${i:-$AUTO_CHECK_INTERVAL}"
  tz="${tz:-$TZ_NAME}"

  if [[ "$a" != "0" && "$a" != "1" ]]; then
    printf "%b\n" "${RED}[ERRO] Auto-vistoria deve ser 0 ou 1.${NC}"; pause; return 0
  fi
  if ! [[ "$i" =~ ^[0-9]+$ ]] || (( i < 5 || i > 3600 )); then
    printf "%b\n" "${RED}[ERRO] Intervalo inválido (5..3600).${NC}"; pause; return 0
  fi

  AUTO_CHECK="$a"
  AUTO_CHECK_INTERVAL="$i"
  TZ_NAME="$tz"
  save_settings

  printf "%b\n" "\n${GREEN}[OK] Configurações salvas.${NC}"
  pause
}

rotate_uuid() {
  clear
  title_bar "ROTACIONAR UUID"

  local old_uuid new_uuid
  old_uuid="$UUID"
  new_uuid="$(generate_uuid)"

  if [[ -z "$new_uuid" ]]; then
    printf "%b\n" "${RED}[ERRO] Não foi possível gerar novo UUID.${NC}"
    pause
    return 0
  fi

  backup_current_config
  echo "$new_uuid" > "$UUID_FILE"
  UUID="$new_uuid"

  printf "%b\n" "${YELLOW}[*] Regravando config da VPS com o novo UUID...${NC}"
  write_server_config
  restart_xray

  echo
  kv1 "UUID ANTIGO" "$old_uuid"
  kv1 "UUID NOVO" "$UUID"
  printf "%b\n" "\n${GREEN}[OK] UUID rotacionado na VPS.${NC}"
  printf "%b\n" "${YELLOW}[*] Gere novamente o JSON do Windows pela opção 'Mostrar JSON do Windows'.${NC}"
  pause
}

change_socks_security() {
  clear
  title_bar "SEGURANÇA DO SOCKS LOCAL"

  kv2 "LISTEN" "$SOCKS_LISTEN" "AUTH" "$SOCKS_AUTH"
  [[ "$SOCKS_AUTH" == "password" ]] && kv1 "USUÁRIO" "$SOCKS_USER"
  echo
  printf "%b\n" "${WHITE}Opções:${NC}"
  printf "%b\n" "  1) Manter local seguro em 127.0.0.1"
  printf "%b\n" "  2) Ativar senha no SOCKS local"
  printf "%b\n" "  3) Remover senha do SOCKS local"
  printf "%b\n" "  0) Voltar"
  echo
  read -r -p "Escolha: " op

  case "$op" in
    1)
      SOCKS_LISTEN="127.0.0.1"
      save_settings
      write_server_config
      restart_xray
      printf "%b\n" "${GREEN}[OK] SOCKS preso em 127.0.0.1.${NC}"
      pause
      ;;
    2)
      local u p
      read -r -p "Usuário do SOCKS [monitor]: " u
      read -r -p "Senha do SOCKS [gerar automática]: " p
      u="${u:-monitor}"
      p="${p:-$(random_token 24)}"
      SOCKS_LISTEN="127.0.0.1"
      SOCKS_AUTH="password"
      SOCKS_USER="$u"
      SOCKS_PASS="$p"
      save_settings
      write_server_config
      restart_xray
      printf "%b\n" "${GREEN}[OK] Autenticação ativada no SOCKS local.${NC}"
      kv2 "USUÁRIO" "$SOCKS_USER" "SENHA" "$SOCKS_PASS"
      pause
      ;;
    3)
      SOCKS_LISTEN="127.0.0.1"
      SOCKS_AUTH="noauth"
      SOCKS_USER=""
      SOCKS_PASS=""
      save_settings
      write_server_config
      restart_xray
      printf "%b\n" "${GREEN}[OK] SOCKS local voltou para noauth, mas segue preso em 127.0.0.1.${NC}"
      pause
      ;;
    0) ;;
    *) printf "%b\n" "${RED}Inválido${NC}"; pause ;;
  esac
}

security_audit() {
  clear
  title_bar "AUDITORIA RÁPIDA DE SEGURANÇA"

  local score=0

  if [[ "$SOCKS_LISTEN" == "127.0.0.1" ]]; then
    printf "%b\n" "  ${GREEN}OK${NC}  SOCKS do servidor restrito a 127.0.0.1"
    score=$((score+1))
  else
    printf "%b\n" "  ${RED}RISCO${NC} SOCKS escutando fora de 127.0.0.1"
  fi

  if [[ "$SOCKS_AUTH" == "password" ]]; then
    printf "%b\n" "  ${GREEN}OK${NC}  SOCKS local com autenticação"
    score=$((score+1))
  else
    printf "%b\n" "  ${YELLOW}AVISO${NC} SOCKS local sem senha (aceitável só por estar em 127.0.0.1)"
  fi

  if [[ -f "$UUID_FILE" ]]; then
    printf "%b\n" "  ${GREEN}OK${NC}  UUID persistido e rotacionável"
    score=$((score+1))
  else
    printf "%b\n" "  ${RED}RISCO${NC} UUID persistente não encontrado"
  fi

  if [[ -f "$ACCESS_LOG_FILE" ]]; then
    printf "%b\n" "  ${GREEN}OK${NC}  Access log habilitado em $ACCESS_LOG_FILE"
    score=$((score+1))
  else
    printf "%b\n" "  ${YELLOW}AVISO${NC} Access log ainda não foi criado"
  fi

  if service_active; then
    printf "%b\n" "  ${GREEN}OK${NC}  Serviço Xray ativo"
    score=$((score+1))
  else
    printf "%b\n" "  ${RED}RISCO${NC} Serviço Xray inativo"
  fi

  echo
  printf "%b\n" "${WHITE}Placar:${NC} ${CYAN}${score}/5${NC}"
  echo
  printf "%b\n" "${DIM}Sugestão:${NC} após rotacionar UUID, gere novo JSON do Windows e descarte o antigo."
  pause
}

show_connected_peers() {
  clear
  title_bar "PEERS CONECTADOS NO TÚNEL"

  printf "%b\n" "${DIM}Porta observada:${NC} ${CYAN}${PORT_TUNNEL}${NC}"
  echo

  if have_cmd ss; then
    ss -Htn state established "( sport = :$PORT_TUNNEL )" 2>/dev/null | awk '{print $4" <- " $5}' | sort -u || true
  else
    netstat -tn 2>/dev/null | awk '/ESTABLISHED/ && $4 ~ /:'"$PORT_TUNNEL"'$/ {print $4" <- "$5}' | sort -u || true
  fi

  echo
  printf "%b\n" "${DIM}Se aparecer IP/desconhecido em horários estranhos, rotacione UUID imediatamente.${NC}"
  pause
}

show_recent_logs() {
  clear
  title_bar "LOGS RECENTES DO XRAY"

  printf "%b\n" "${WHITE}Últimas linhas do access.log:${NC}"
  rule "─"
  tail -n 40 "$ACCESS_LOG_FILE" 2>/dev/null || printf "%b\n" "${DIM}(sem access.log ainda)${NC}"
  echo
  rule "─"
  printf "%b\n" "${WHITE}Últimas linhas do error.log:${NC}"
  rule "─"
  tail -n 25 "$ERROR_LOG_FILE" 2>/dev/null || printf "%b\n" "${DIM}(sem error.log ainda)${NC}"
  pause
}

render_menu() {
  section "MENU"
  local W; W="$(term_cols)"

  local left=(
    "1|Instalar / Reparar"
    "2|Alterar portas (túnel/socks)"
    "3|Alterar WS path"
    "4|Mostrar JSON do Windows (Bridge)"
    "5|Diagnóstico completo"
    "6|Rodar vistoria agora"
    "7|Teste manual (1 URL)"
    "8|Port Doctor"
  )
  local right=(
    "9|Reiniciar Xray"
    "10|Auto-vistoria"
    "11|Rotacionar UUID"
    "12|Segurança do SOCKS local"
    "13|Auditoria rápida de segurança"
    "14|Ver peers conectados"
    "15|Ver logs recentes"
    "16|Restaurar último backup"
  )

  if (( W < 92 )); then
    local item
    for item in "${left[@]}" "${right[@]}"; do
      local k="${item%%|*}" t="${item#*|}"
      printf "%b\n" "  ${CYAN}$(pad 2 "$k")${NC}  ${WHITE}${t}${NC}"
    done
    printf "%b\n\n" "  ${DIM}0   Sair${NC}"
    return 0
  fi

  local i
  for i in 0 1 2 3 4 5 6 7; do
    local l="${left[$i]}" r="${right[$i]}"
    local lk="${l%%|*}" lt="${l#*|}"
    local rk="${r%%|*}" rt="${r#*|}"
    printf "%b\n" "  ${CYAN}$(pad 2 "$lk")${NC}  ${WHITE}$(pad 34 "$lt")${NC}   ${CYAN}$(pad 2 "$rk")${NC}  ${WHITE}${rt}${NC}"
  done
  printf "%b\n\n" "  ${DIM}0   Sair${NC}"
}

main() {
  require_root
  ensure_deps
  ensure_dirs
  load_settings
  ensure_uuid

  local VPS_IP
  VPS_IP="$(get_ip)"

  while true; do
    maybe_auto_check
    render_header "$VPS_IP"
    render_menu

    read -r -p "Escolha: " op
    case "$op" in
      1) install_or_repair ;;
      2) change_ports ;;
      3) change_ws_path ;;
      4) show_client_json "$VPS_IP" ;;
      5) diagnostico "$VPS_IP" ;;
      6) run_all_tests; printf "%b\n" "${GREEN}[OK] Vistoria executada.${NC}"; pause ;;
      7) test_manual_one ;;
      8) port_doctor ;;
      9) restart_xray; run_all_tests; printf "%b\n" "${GREEN}[OK] Reiniciado + vistoria atualizada.${NC}"; pause ;;
      10) toggle_auto_check ;;
      11) rotate_uuid ;;
      12) change_socks_security ;;
      13) security_audit ;;
      14) show_connected_peers ;;
      15) show_recent_logs ;;
      16) restore_latest_backup ;;
      0) exit 0 ;;
      *) printf "%b\n" "${RED}Inválido${NC}"; pause ;;
    esac
  done
}

main "$@"
