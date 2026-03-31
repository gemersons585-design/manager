#!/bin/bash
# INSTALADOR PMESP ULTIMATE V8.0 + XRAY TUNNEL
echo -e "\033[1;34m>>> PREPARANDO SISTEMA E ATUALIZANDO PACOTES (SUDO/ROOT)...\033[0m"

# Atualiza as listas e faz o upgrade total (modo silencioso para não travar a tela)
DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# Instala todas as dependências necessárias
DEBIAN_FRONTEND=noninteractive apt-get install -y jq python3 python3-pip wget msmtp msmtp-mta ca-certificates bc screen nano net-tools lsof cron zip unzip

# Instala FastAPI para a API
pip3 install fastapi uvicorn --break-system-packages 2>/dev/null || pip3 install fastapi uvicorn

# Define o novo repositório correto
REPO="https://raw.githubusercontent.com/gemersons585-design/manager/main"

# Baixa e configura o Manager Principal
wget -qO /usr/local/bin/pmesp "$REPO/manager.sh"
chmod +x /usr/local/bin/pmesp

# Baixa e configura o Xray (Túnel Reverso) com nome seguro (xray-menu)
wget -qO /usr/local/bin/xray-menu "$REPO/xray.sh"
chmod +x /usr/local/bin/xray-menu

# Baixa e configura a API
mkdir -p /etc/pmesp
wget -qO /etc/pmesp/api_pmesp.py "$REPO/api_pmesp.py"

# Cria serviço da API (Auto-start)
cat <<EOF > /etc/systemd/system/pmesp-api.service
[Unit]
Description=API PMESP
After=network.target

[Service]
User=root
WorkingDirectory=/etc/pmesp
ExecStart=/usr/local/bin/uvicorn api_pmesp:app --host 0.0.0.0 --port 8000
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable pmesp-api.service
systemctl restart pmesp-api.service

echo -e "\033[1;32m>>> TUDO PRONTO! Digite 'pmesp' para abrir o painel.\033[0m"
