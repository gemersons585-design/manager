#!/usr/bin/env bash
# ==============================================================================
#  XRAY TUNNEL MANAGER PRO v4 (VMess + WS + Reverse Portal/Bridge)
# ==============================================================================
#  - Rotacao segura de UUID
#  - Backup automatico antes de alterar config
#  - SOCKS do servidor preso em 127.0.0.1
#  - Autenticacao opcional no SOCKS local
#  - Exporta JSON do Windows para arquivo
#  - Auditoria rapida de seguranca
#  - Visualizacao de peers conectados / logs recentes
# ==============================================================================

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
# PADROES (alteraveis no menu)
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
# SETTINGS & STATE
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

LAST_CHECK_AT=""
LAST_CHECK_EPOCH=""
SITE_RESULTS=""

# =========================
# UI HELPERS (NOVO LAYOUT)
# =========================
term_cols() { tput cols 2>/dev/null || echo "${COLUMNS:-100}"; }

barra_titulo() {
  echo -e "${C}================================================================${NC}"
}

barra_fina() {
  echo -e "${C}----------------------------------------------------------------${NC}"
}

title_bar() {
  local t="$1"
  echo -e "${W}             $t              ${NC}"
  barra_titulo
}

section() {
  local t="$1"
  echo -e "${W} [ $t ]${NC}"
}

pause() { read -r -p "Pressione Enter para continuar..." _; }
pad() { local w="$1"; shift; printf "%-*s" "$w" "$*"; }

trunc() {
  local w="$1"; shift
  local s="$*"
  if (( ${#s} > w )); then
    printf "%s" "${s:0:w-1}..."
  else
    printf "%s" "$s"
  fi
}

dot() {
  local ok="$1"
  if [[ "$ok" == "1" ]]; then
    printf "%b" "${GREEN}[ON]${NC}"
  else
    printf "%b" "${RED}[OFF]${NC}"
  fi
}

kv1() {
  local l="$1" v="$2"
  printf "%b\n" "  - ${WHITE}$(pad 14 "${l}:")${NC} ${CYAN}${v}${NC}"
}

kv2() {
  local l1="$1" v1="$2" l2="$3" v2="$4"
  printf "%b\n" "  - ${WHITE}$(pad 12 "${l1}:")${NC} ${CYAN}${v1}${NC}    - ${WHITE}$(pad 12 "${l2}:")${NC} ${CYAN}${v2}${NC}"
}

# =========================
# ERROS
# =========================
on_error() {
  local line="$1" cmd="$2"
  echo "" >&2
  echo -e "${RED}[ERRO]${NC} Linha ${WHITE}${line}${NC}: ${DIM}${cmd}${NC}" >&2
  echo -e "${DIM}Dica: journalctl -u ${SERVICE} -n 120 --no-pager${NC}" >&2
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# =========================
# UTILS & HELPERS
# =========================
have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo -e "${RED}[ERRO] Rode como root.${NC} Ex: sudo bash $0"
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

json_escape() { jq -Rsa . <<<"$1"; }
random_token() { tr -dc 'A-Za-z0-9@#%_=+.-' </dev/urandom | head -c "${1:-24}"; }

generate_uuid() {
  if have_cmd xray; then xray uuid 2>/dev/null && return 0; fi
  if have_cmd uuidgen; then uuidgen 2>/dev/null && return 0; fi
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
  if [[ -f "$SETTINGS_FILE" ]]; then source "$SETTINGS_FILE"; fi
  if [[ -f "$STATE_FILE" ]]; then source "$STATE_FILE"; fi

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
}

save_settings() {
  cat > "$SETTINGS_FILE" <<EOF2
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

port_is_listening() { [[ -n "$(port_listen_info "$1")" ]]; }

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
  if have_cmd fuser; then fuser -k "${port}/tcp" >/dev/null 2>&1 || true
  else lsof -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | xargs -r kill -9 >/dev/null 2>&1 || true
  fi
}

force_cleanup_ports() {
  echo -e "${YELLOW}[*] Parando servico e limpando portas ${PORT_TUNNEL}/${PORT_SOCKS}...${NC}"
  systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  kill_port "$PORT_TUNNEL"
  kill_port "$PORT_SOCKS"
  echo -e "${GREEN}[OK] Limpeza concluida.${NC}"
}

apply_setcap_if_needed() {
  if [[ -x "$XRAY_BIN" ]]; then setcap CAP_NET_BIND_SERVICE=+eip "$XRAY_BIN" >/dev/null 2>&1 || true; fi
}

is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 )); }

backup_current_config() {
  ensure_dirs
  if [[ -f "$CONFIG_FILE" ]]; then cp "$CONFIG_FILE" "$BACKUP_DIR/config.$(stamp).json"; fi
  if [[ -f "$UUID_FILE" ]]; then cp "$UUID_FILE" "$UUID_HISTORY_DIR/uuid.$(stamp).txt"; fi
}

restore_latest_backup() {
  local last
  last="$(ls -1t "$BACKUP_DIR"/config.*.json 2>/dev/null | head -n1 || true)"
  if [[ -z "$last" ]]; then
    echo -e "${RED}[ERRO] Nenhum backup encontrado.${NC}"
    pause
    return 0
  fi
  cp "$last" "$CONFIG_FILE"
  restart_xray
  echo -e "${GREEN}[OK] Backup restaurado: ${CYAN}${last}${NC}"
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

# ==============================================================
# CONFIG DO SERVIDOR (COM CORRECAO DO ROTEAMENTO BUMERANGUE)
# ==============================================================
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
    echo -e "${RED}[ERRO] JSON gerado ficou invalido. Nada foi aplicado.${NC}"
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

# ==============================================================
# CONFIG DO CLIENTE (COM PROXY LOCAL 10808 MIXED)
# ==============================================================
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
  barra_titulo
  title_bar "CONFIG DO PC INTRANET (WINDOWS - BRIDGE)"
  echo -e "${DIM}Copie e salve como config.json no Windows:${NC}\n"
  cat "$CLIENT_EXPORT_FILE"
  echo ""
  barra_fina
  echo -e "${DIM}Arquivo salvo em:${NC} ${CYAN}${CLIENT_EXPORT_FILE}${NC}"
  echo -e "${DIM}Dica: se mudar UUID ou portas, gere este JSON novamente.${NC}"
  pause
}

restart_xray() {
  systemctl restart "$SERVICE" >/dev/null 2>&1 || true
  sleep 1
}

install_or_repair() {
  clear
  barra_titulo
  title_bar "INSTALAR / REPARAR XRAY (PORTAL)"

  ensure_deps
  ensure_dirs

  echo -e "${YELLOW}[*] Instalando Xray oficial...${NC}"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 || true

  echo ""
  force_cleanup_ports

  echo -e "${YELLOW}[*] Gerando config do servidor...${NC}"
  write_server_config
  apply_setcap_if_needed

  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
  restart_xray

  echo ""
  if service_active; then echo -e "${GREEN}[SUCESSO] Xray esta ONLINE.${NC}"
  else echo -e "${RED}[ERRO] Xray nao subiu. Veja logs: journalctl -u $SERVICE -n 140${NC}"
  fi

  echo ""
  barra_fina
  echo -e "${WHITE}Resumo da Config:${NC}"
  kv2 "TUNEL" "$PORT_TUNNEL" "SOCKS" "$PORT_SOCKS"
  kv2 "WS PATH" "$WS_PATH" "DOMAIN" "$REVERSE_DOMAIN"
  kv2 "LISTEN" "$SOCKS_LISTEN" "AUTH" "$SOCKS_AUTH"
  kv1 "UUID" "$UUID"
  barra_fina
  pause
}

site_count() { echo "${#SITES[@]}"; }

count_ok_sites() {
  local ok=0
  while IFS='|' read -r _name _code _ms status _msg; do
    [[ -z "${_name:-}" ]] && continue
    if [[ "$status" == "OK" ]]; then ok=$((ok+1)); fi
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
  out="$(curl -k -sS -o /dev/null -w "%{http_code}|%{time_total}" --connect-timeout 5 --max-time 15 --proxy "$proxy" "$url" 2>"$tmp_err")"
  rc=$?
  set -e

  code="${out%%|*}"
  total_time_ms="$(awk -v t="${out##*|}" 'BEGIN{ printf "%.0f", (t*1000) }' 2>/dev/null || echo 0)"

  if [[ $rc -ne 0 ]]; then
    local msg; msg="$(tr '\n' ' ' <"$tmp_err" | sed 's/[[:space:]]\+/ /g' | cut -c1-90)"
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
  local nowh nowe total tmpdir idx=0
  nowh="$(now_human)"
  nowe="$(now_epoch)"
  total="$(site_count)"
  tmpdir="/tmp/xray_tm_sites.$$"

  rm -rf "$tmpdir" >/dev/null 2>&1 || true
  mkdir -p "$tmpdir"

  for item in "${SITES[@]}"; do
    local name="${item%%|*}" url="${item#*|}"
    ( test_one_site "$name" "$url" > "$tmpdir/$idx" ) &
    idx=$((idx+1))
  done
  wait || true

  local results="" i
  for ((i=0; i<total; i++)); do
    if [[ -f "$tmpdir/$i" ]]; then results+="$(cat "$tmpdir/$i")"$'\n'; fi
  done
  rm -rf "$tmpdir" >/dev/null 2>&1 || true

  LAST_CHECK_AT="$nowh"
  LAST_CHECK_EPOCH="$nowe"
  SITE_RESULTS="$results"
  save_state
}

maybe_auto_check() {
  [[ "${AUTO_CHECK:-1}" -ne 1 ]] && return 0
  if [[ -z "${LAST_CHECK_EPOCH:-}" ]]; then run_all_tests; return 0; fi

  local now diff
  now="$(now_epoch)"
  diff=$(( now - LAST_CHECK_EPOCH ))
  if (( diff >= AUTO_CHECK_INTERVAL )); then run_all_tests; fi
}

render_sites_block() {
  section "VISTORIA (via SOCKS 127.0.0.1:${PORT_SOCKS})"
  if [[ -z "${LAST_CHECK_AT:-}" ]]; then echo -e "  ${DIM}(ainda não executada)${NC}"; return 0; fi

  local ok total badge
  ok="$(count_ok_sites)"
  total="$(site_count)"
  badge="$YELLOW"
  [[ "$ok" -eq "$total" ]] && badge="$GREEN"
  [[ "$ok" -eq 0 ]] && badge="$RED"

  echo -e "  Ultima execucao: ${CYAN}${LAST_CHECK_AT}${NC}"
  echo -e "  Resultado:       ${badge}${ok}/${total} OK${NC}\n"

  local W; W="$(term_cols)"
  local name_w=20 code_w=5 ms_w=6
  local msg_w=$(( W - (2 + name_w + code_w + ms_w + 10) ))
  (( msg_w < 15 )) && msg_w=15

  echo -e "  ${DIM}$(pad $name_w "SITE") | $(pad $code_w "HTTP") | $(pad $ms_w "LAT") | $(pad $msg_w "OBS")${NC}"
  barra_fina

  local i=1
  while IFS='|' read -r name code ms status msg; do
    [[ -z "${name:-}" ]] && continue
    local c="$YELLOW"
    [[ "$status" == "OK" ]] && c="$GREEN"
    [[ "$status" == "FAIL" ]] && c="$RED"

    echo -e "  $(pad $name_w "$(trunc $name_w "$name")") ${DIM}|${NC} ${c}$(pad $code_w "${code:-000}")${NC} ${DIM}|${NC} ${DIM}$(pad $ms_w "${ms:-0}ms")${NC} ${DIM}|${NC} ${DIM}$(trunc $msg_w "${msg:-}")${NC}"
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
  barra_titulo
  title_bar "XRAY TUNNEL MANAGER"

  section "IDENTIDADE"
  kv2 "VPS IP" "${vps_ip:-N/A}" "TZ" "$TZ_NAME"
  kv1 "UUID" "$UUID"
  echo ""

  section "CONFIG"
  kv2 "TUNEL" "$PORT_TUNNEL" "SOCKS" "$PORT_SOCKS"
  kv2 "WS PATH" "$WS_PATH" "DOMAIN" "$REVERSE_DOMAIN"
  kv2 "LISTEN" "$SOCKS_LISTEN" "AUTH" "$SOCKS_AUTH"
  echo -e "  - ${WHITE}Listen tunel:${NC} ${DIM}${li_tun:-N/A}${NC}"
  echo -e "  - ${WHITE}Listen socks:${NC} ${DIM}${li_socks:-N/A}${NC}"
  echo ""

  section "SAUDE"
  echo -e "  $(dot "$srv") Xray   $(dot "$tnl") Tunel   $(dot "$sks") SOCKS   $(dot "$br") Bridge Windows"
  echo ""

  render_sites_block
  echo ""
}

diagnostico() {
  local vps_ip="$1"
  clear
  barra_titulo
  title_bar "DIAGNOSTICO COMPLETO"

  kv2 "VPS IP" "${vps_ip:-N/A}" "AGORA" "$(now_human)"
  kv1 "UUID" "$UUID"
  echo ""

  if service_active; then echo -e "  $(dot 1) ${GREEN}Servico Xray ONLINE${NC}"
  else echo -e "  $(dot 0) ${RED}Servico Xray OFFLINE${NC}"; fi

  local li_tun li_socks
  li_tun="$(port_listen_info "$PORT_TUNNEL")"
  li_socks="$(port_listen_info "$PORT_SOCKS")"

  echo ""
  section "PORTAS"
  if [[ -n "$li_tun" ]]; then echo -e "  ${GREEN}OK${NC}  Tunel ${CYAN}${PORT_TUNNEL}${NC}  ${DIM}${li_tun}${NC}"
  else echo -e "  ${RED}OFF${NC} Tunel ${CYAN}${PORT_TUNNEL}${NC}"; fi
  if [[ -n "$li_socks" ]]; then echo -e "  ${GREEN}OK${NC}  SOCKS ${CYAN}${PORT_SOCKS}${NC}  ${DIM}${li_socks}${NC}"
  else echo -e "  ${RED}OFF${NC} SOCKS ${CYAN}${PORT_SOCKS}${NC}"; fi

  echo ""
  section "POLITICA SOCKS LOCAL"
  kv2 "LISTEN" "$SOCKS_LISTEN" "AUTH" "$SOCKS_AUTH"
  if [[ "$SOCKS_AUTH" == "password" ]]; then kv1 "USER" "$SOCKS_USER"; fi

  echo ""
  section "BRIDGE WINDOWS"
  if bridge_is_online "$PORT_TUNNEL"; then
    echo -e "  ${GREEN}CONECTADO${NC} (sessao ESTABLISHED no tunel)\n"
    if have_cmd ss; then ss -Htn state established "( sport = :$PORT_TUNNEL )" 2>/dev/null | head -n 12 || true
    else netstat -tn 2>/dev/null | grep -E "ESTABLISHED.*:${PORT_TUNNEL}$" | head -n 12 || true; fi
  else echo -e "  ${RED}DESCONECTADO${NC}"; fi

  echo ""
  barra_fina
  echo -e "${DIM}Logs: journalctl -u $SERVICE -n 160 --no-pager${NC}"
  pause
}

port_doctor() {
  clear
  barra_titulo
  title_bar "PORT DOCTOR"

  local a b
  a="$(port_listen_info "$PORT_TUNNEL")"
  b="$(port_listen_info "$PORT_SOCKS")"

  echo -e "  - Tunel ${CYAN}${PORT_TUNNEL}${NC}:  ${DIM}${a:-LIVRE / NAO LISTEN}${NC}"
  echo -e "  - SOCKS ${CYAN}${PORT_SOCKS}${NC}:  ${DIM}${b:-LIVRE / NAO LISTEN}${NC}\n"

  echo -e "${WHITE}Acoes:${NC}"
  echo -e "  1) Matar processo na porta do Tunel (${PORT_TUNNEL})"
  echo -e "  2) Matar processo na porta do SOCKS (${PORT_SOCKS})"
  echo -e "  3) Limpeza completa (stop xray + kill nas duas portas)"
  echo -e "  0) Voltar\n"
  read -r -p "Escolha: " op

  case "$op" in
    1) kill_port "$PORT_TUNNEL"; echo -e "${GREEN}[OK] Kill na porta ${PORT_TUNNEL}.${NC}"; pause ;;
    2) kill_port "$PORT_SOCKS";  echo -e "${GREEN}[OK] Kill na porta ${PORT_SOCKS}.${NC}"; pause ;;
    3) force_cleanup_ports; pause ;;
    0) ;;
    *) echo -e "${RED}Invalido${NC}"; pause ;;
  esac
}

test_manual_one() {
  clear
  barra_titulo
  title_bar "TESTE MANUAL (1 URL)"
  echo -e "${DIM}Proxy: $(proxy_url)${NC}\n"
  read -r -p "URL: " url
  [[ -z "${url:-}" ]] && echo -e "${RED}[ERRO] URL vazia.${NC}" && pause && return 0

  echo -e "\n${YELLOW}[*] Testando...${NC}"
  local line _name code ms status msg
  line="$(test_one_site "MANUAL" "$url")"
  IFS='|' read -r _name code ms status msg <<< "$line"

  local c="$YELLOW"
  [[ "$status" == "OK" ]] && c="$GREEN"
  [[ "$status" == "FAIL" ]] && c="$RED"

  echo -e "\n  HTTP: ${c}${code}${NC}"
  echo -e "  LAT:  ${DIM}${ms}ms${NC}"
  echo -e "  OBS:  ${DIM}${msg}${NC}"
  echo -e "  Hora: ${CYAN}$(now_human)${NC}"
  pause
}

change_ports() {
  clear
  barra_titulo
  title_bar "ALTERAR PORTAS"
  echo -e "${DIM}Atual: tunel=${PORT_TUNNEL} | socks=${PORT_SOCKS}${NC}\n"

  local new_t new_s
  read -r -p "Nova porta do Tunel [${PORT_TUNNEL}]: " new_t
  read -r -p "Nova porta do SOCKS [${PORT_SOCKS}]: " new_s
  new_t="${new_t:-$PORT_TUNNEL}"
  new_s="${new_s:-$PORT_SOCKS}"

  if ! is_valid_port "$new_t" || ! is_valid_port "$new_s"; then
    echo -e "${RED}[ERRO] Portas invalidas. Use 1-65535.${NC}"; pause; return 0
  fi

  PORT_TUNNEL="$new_t"; PORT_SOCKS="$new_s"; save_settings
  echo -e "\n${YELLOW}[*] Aplicando nova config...${NC}"
  force_cleanup_ports; write_server_config; apply_setcap_if_needed; restart_xray

  if service_active; then echo -e "${GREEN}[OK] Alteracoes aplicadas.${NC}"; else echo -e "${RED}[ERRO] Xray nao subiu.${NC}"; fi
  run_all_tests; pause
}

change_ws_path() {
  clear
  barra_titulo
  title_bar "ALTERAR WS PATH"
  echo -e "${DIM}Atual: ${WS_PATH}${NC}\n"

  local p
  read -r -p "Novo WS path [${WS_PATH}]: " p
  p="${p:-$WS_PATH}"
  [[ "$p" != /* ]] && p="/$p"

  WS_PATH="$p"; save_settings
  echo -e "\n${YELLOW}[*] Aplicando nova config...${NC}"
  force_cleanup_ports; write_server_config; apply_setcap_if_needed; restart_xray
  
  if service_active; then echo -e "${GREEN}[OK] WS path atualizado.${NC}"; else echo -e "${RED}[ERRO] Xray nao subiu.${NC}"; fi
  run_all_tests; pause
}

toggle_auto_check() {
  clear
  barra_titulo
  title_bar "AUTO-VISTORIA"
  kv2 "AUTO" "${AUTO_CHECK} (1=ON 0=OFF)" "INT(s)" "${AUTO_CHECK_INTERVAL}"
  kv1 "TZ" "$TZ_NAME"
  echo ""

  local a i tz
  read -r -p "Auto-vistoria (1/0) [${AUTO_CHECK}]: " a
  read -r -p "Intervalo (segundos) [${AUTO_CHECK_INTERVAL}]: " i
  read -r -p "Timezone [${TZ_NAME}]: " tz

  a="${a:-$AUTO_CHECK}"; i="${i:-$AUTO_CHECK_INTERVAL}"; tz="${tz:-$TZ_NAME}"

  if [[ "$a" != "0" && "$a" != "1" ]]; then echo -e "${RED}[ERRO] Deve ser 0 ou 1.${NC}"; pause; return 0; fi
  if ! [[ "$i" =~ ^[0-9]+$ ]] || (( i < 5 || i > 3600 )); then echo -e "${RED}[ERRO] Invalido (5..3600).${NC}"; pause; return 0; fi

  AUTO_CHECK="$a"; AUTO_CHECK_INTERVAL="$i"; TZ_NAME="$tz"; save_settings
  echo -e "\n${GREEN}[OK] Salvo.${NC}"; pause
}

rotate_uuid() {
  clear
  barra_titulo
  title_bar "ROTACIONAR UUID"

  local old_uuid="$UUID" new_uuid
  new_uuid="$(generate_uuid)"
  if [[ -z "$new_uuid" ]]; then echo -e "${RED}[ERRO] Falha ao gerar UUID.${NC}"; pause; return 0; fi

  backup_current_config
  echo "$new_uuid" > "$UUID_FILE"
  UUID="$new_uuid"

  echo -e "${YELLOW}[*] Regravando config da VPS...${NC}"
  write_server_config; restart_xray

  echo ""
  kv1 "UUID ANTIGO" "$old_uuid"
  kv1 "UUID NOVO" "$UUID"
  echo -e "\n${GREEN}[OK] UUID alterado.${NC} ${YELLOW}Gere o novo JSON para o Windows.${NC}"
  pause
}

change_socks_security() {
  clear
  barra_titulo
  title_bar "SEGURANCA DO SOCKS LOCAL"
  kv2 "LISTEN" "$SOCKS_LISTEN" "AUTH" "$SOCKS_AUTH"
  [[ "$SOCKS_AUTH" == "password" ]] && kv1 "USER" "$SOCKS_USER"
  echo -e "\n${WHITE}Opcoes:${NC}"
  echo -e "  1) Manter seguro em 127.0.0.1"
  echo -e "  2) Ativar senha"
  echo -e "  3) Remover senha"
  echo -e "  0) Voltar\n"
  read -r -p "Escolha: " op

  case "$op" in
    1) SOCKS_LISTEN="127.0.0.1"; save_settings; write_server_config; restart_xray; echo -e "${GREEN}[OK] Salvo.${NC}"; pause ;;
    2)
      local u p
      read -r -p "User [monitor]: " u; read -r -p "Pass [gerar]: " p
      SOCKS_LISTEN="127.0.0.1"; SOCKS_AUTH="password"; SOCKS_USER="${u:-monitor}"; SOCKS_PASS="${p:-$(random_token 24)}"
      save_settings; write_server_config; restart_xray
      echo -e "${GREEN}[OK] Senha ativada.${NC}"; kv2 "USER" "$SOCKS_USER" "PASS" "$SOCKS_PASS"; pause ;;
    3)
      SOCKS_LISTEN="127.0.0.1"; SOCKS_AUTH="noauth"; SOCKS_USER=""; SOCKS_PASS=""
      save_settings; write_server_config; restart_xray
      echo -e "${GREEN}[OK] Senha removida.${NC}"; pause ;;
    0) ;;
    *) echo -e "${RED}Invalido${NC}"; pause ;;
  esac
}

security_audit() {
  clear
  barra_titulo
  title_bar "AUDITORIA RAPIDA"
  local score=0

  if [[ "$SOCKS_LISTEN" == "127.0.0.1" ]]; then echo -e "  ${GREEN}[OK]${NC} SOCKS restrito a 127.0.0.1"; score=$((score+1))
  else echo -e "  ${RED}[!!]${NC} SOCKS aberto fora do localhost"; fi

  if [[ "$SOCKS_AUTH" == "password" ]]; then echo -e "  ${GREEN}[OK]${NC} SOCKS com senha"; score=$((score+1))
  else echo -e "  ${YELLOW}[--]${NC} SOCKS sem senha"; fi

  if [[ -f "$UUID_FILE" ]]; then echo -e "  ${GREEN}[OK]${NC} UUID persistido"; score=$((score+1))
  else echo -e "  ${RED}[!!]${NC} UUID solto"; fi

  if [[ -f "$ACCESS_LOG_FILE" ]]; then echo -e "  ${GREEN}[OK]${NC} Access log ativo"; score=$((score+1))
  else echo -e "  ${YELLOW}[--]${NC} Access log vazio"; fi

  if service_active; then echo -e "  ${GREEN}[OK]${NC} Xray ativo"; score=$((score+1))
  else echo -e "  ${RED}[!!]${NC} Xray inativo"; fi

  echo -e "\n${WHITE}Placar:${NC} ${CYAN}${score}/5${NC}"
  pause
}

show_connected_peers() {
  clear
  barra_titulo
  title_bar "PEERS CONECTADOS"
  echo -e "${DIM}Porta: ${CYAN}${PORT_TUNNEL}${NC}\n"

  if have_cmd ss; then ss -Htn state established "( sport = :$PORT_TUNNEL )" 2>/dev/null | awk '{print $4" <- " $5}' | sort -u || true
  else netstat -tn 2>/dev/null | awk '/ESTABLISHED/ && $4 ~ /:'"$PORT_TUNNEL"'$/ {print $4" <- "$5}' | sort -u || true; fi
  echo ""
  pause
}

show_recent_logs() {
  clear
  barra_titulo
  title_bar "LOGS XRAY"
  echo -e "${WHITE}ACCESS.LOG (ultimas linhas):${NC}"
  barra_fina
  tail -n 20 "$ACCESS_LOG_FILE" 2>/dev/null || echo -e "${DIM}(vazio)${NC}"
  echo ""
  echo -e "${WHITE}ERROR.LOG (ultimas linhas):${NC}"
  barra_fina
  tail -n 15 "$ERROR_LOG_FILE" 2>/dev/null || echo -e "${DIM}(vazio)${NC}"
  pause
}

render_menu() {
  barra_titulo
  echo -e "${W} [ CONTROLE DO TUNEL ]${NC}"
  echo -e "${C}  01.${NC} Instalar / Reparar    ${C}05.${NC} Ver JSON Windows"
  echo -e "${C}  02.${NC} Alterar Portas        ${C}06.${NC} Rotacionar UUID"
  echo -e "${C}  03.${NC} Alterar WS Path       ${C}07.${NC} Configurar Seguranca"
  echo -e "${C}  04.${NC} Reiniciar Xray        ${C}08.${NC} Restaurar Backup"
  echo ""
  echo -e "${W} [ MONITORAMENTO ]${NC}"
  echo -e "${C}  09.${NC} Diagnostico Geral     ${C}13.${NC} Port Doctor"
  echo -e "${C}  10.${NC} Rodar Vistoria        ${C}14.${NC} Ver Peers Online"
  echo -e "${C}  11.${NC} Teste de URL Unico    ${C}15.${NC} Ver Logs Recentes"
  echo -e "${C}  12.${NC} Ajustar Auto-Check    ${C}16.${NC} Auditoria Express"
  echo ""
  echo -e "${R}  00.${NC} Voltar ao Painel PMESP"
  barra_titulo
}

main() {
  require_root; ensure_deps; ensure_dirs; load_settings; ensure_uuid
  local VPS_IP="$(get_ip)"

  while true; do
    maybe_auto_check
    render_header "$VPS_IP"
    render_menu
    read -r -p "➤ Opcao: " op
    case "$op" in
      1|01) install_or_repair ;;
      2|02) change_ports ;;
      3|03) change_ws_path ;;
      4|04) restart_xray; run_all_tests; echo -e "${GREEN}[OK] Reiniciado.${NC}"; pause ;;
      5|05) show_client_json "$VPS_IP" ;;
      6|06) rotate_uuid ;;
      7|07) change_socks_security ;;
      8|08) restore_latest_backup ;;
      9|09) diagnostico "$VPS_IP" ;;
      10) run_all_tests; echo -e "${GREEN}[OK] Vistoria OK.${NC}"; pause ;;
      11) test_manual_one ;;
      12) toggle_auto_check ;;
      13) port_doctor ;;
      14) show_connected_peers ;;
      15) show_recent_logs ;;
      16) security_audit ;;
      0|00) exit 0 ;;
      *) echo -e "${RED}Invalido${NC}"; sleep 1 ;;
    esac
  done
}

main "$@"
