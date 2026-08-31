#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Deploy script per OpenWA su Debian
#
# Uso: eseguire come root
#   chmod +x deploy-openwa.sh
#   ./deploy-openwa.sh
#
# Idempotente: se rilanciato su un deploy esistente, fa "git pull"
# invece di clonare di nuovo, e non tocca un .env già presente.
# ============================================================

# ---- Configurazione (modifica qui se serve) ----
APP_USER="nodeapp"
APP_DIR="/home/${APP_USER}/OpenWA"
REPO_URL="https://github.com/rmyndharis/OpenWA.git"
NODE_MAJOR="22"
ENGINE_TYPE="whatsapp-web.js"   # oppure "baileys" (piu' leggero, niente Chromium)
APP_PORT="2785"
PM2_APP_NAME="openwa"
# --------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "Questo script va eseguito come root." >&2
  exit 1
fi

echo "==> Installo pacchetti di base (git, curl, openssl)..."
apt update
apt install -y git curl openssl

echo "==> Verifico Node.js..."
CURRENT_MAJOR="0"
if command -v node &>/dev/null; then
  CURRENT_MAJOR="$(node -v | sed 's/v//' | cut -d. -f1)"
fi
if [[ "$CURRENT_MAJOR" -lt "$NODE_MAJOR" ]]; then
  echo "==> Installo Node.js ${NODE_MAJOR}.x..."
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt install -y nodejs
else
  echo "==> Node.js gia' presente: $(node -v)"
fi

echo "==> Installo PM2 globalmente (se manca)..."
if ! command -v pm2 &>/dev/null; then
  npm install -g pm2
fi

if [[ "$ENGINE_TYPE" == "whatsapp-web.js" ]]; then
  echo "==> Engine whatsapp-web.js: installo Chromium..."
  apt install -y chromium
fi

echo "==> Creo utente di sistema '${APP_USER}' (se non esiste)..."
if ! id -u "$APP_USER" &>/dev/null; then
  useradd -m -s /bin/bash -c "OpenWA deploy user" "$APP_USER"
  echo "    Utente creato. Nessuna password di login impostata: si accede solo con 'su - ${APP_USER}' da root."
else
  echo "    Utente ${APP_USER} gia' esistente, salto la creazione."
fi

echo "==> Clono/aggiorno il repository OpenWA..."
if [[ -d "${APP_DIR}/.git" ]]; then
  su - "$APP_USER" -c "cd '${APP_DIR}' && git pull"
else
  su - "$APP_USER" -c "git clone '${REPO_URL}' '${APP_DIR}'"
fi

echo "==> Installo le dipendenze npm..."
su - "$APP_USER" -c "cd '${APP_DIR}' && npm install"

echo "==> Configuro .env..."
su - "$APP_USER" bash -c "
  cd '${APP_DIR}'
  if [[ ! -f .env ]]; then
    cp .env.example .env
    GENERATED_KEY=\$(openssl rand -hex 32)
    sed -i \"s|^API_KEY=.*|API_KEY=\${GENERATED_KEY}|\" .env
    sed -i \"s|^NODE_ENV=.*|NODE_ENV=production|\" .env
    sed -i \"s|^PORT=.*|PORT=${APP_PORT}|\" .env
    sed -i \"s|^ENGINE_TYPE=.*|ENGINE_TYPE=${ENGINE_TYPE}|\" .env
    echo \"    Generata nuova API_KEY, salvata in .env: \${GENERATED_KEY}\"
    echo \"    IMPORTANTE: verifica manualmente .env, i nomi esatti delle variabili\"
    echo \"    potrebbero differire da quelli attesi da questo script.\"
  else
    echo '    .env gia esistente, non lo tocco.'
  fi
"

echo "==> Compilo backend e dashboard..."
su - "$APP_USER" -c "cd '${APP_DIR}' && npm run build && npm run dashboard:build"

echo "==> Scrivo ecosystem.config.js..."
su - "$APP_USER" bash -c "cat > '${APP_DIR}/ecosystem.config.js' <<EOF
module.exports = {
  apps: [{
    name: \"${PM2_APP_NAME}\",
    script: \"dist/main.js\",
    cwd: \"${APP_DIR}\",
    instances: 1,
    exec_mode: \"fork\",
    autorestart: true,
    watch: false,
    max_memory_restart: \"500M\",
    min_uptime: \"10s\",
    max_restarts: 10,
    restart_delay: 4000,
    exp_backoff_restart_delay: 100,
    cron_restart: \"0 4 * * *\",
    env: {
      NODE_ENV: \"production\",
      PORT: ${APP_PORT}
    }
  }]
}
EOF"

echo "==> Configuro l'avvio automatico al boot (systemd)..."
env PATH=$PATH:/usr/bin pm2 startup systemd -u "$APP_USER" --hp "/home/${APP_USER}"

echo "==> Avvio l'app con PM2 e salvo lo stato..."
su - "$APP_USER" -c "cd '${APP_DIR}' && pm2 start ecosystem.config.js && pm2 save"

echo ""
echo "======================================================"
echo " Deploy completato."
echo " Utente:   ${APP_USER}"
echo " Cartella: ${APP_DIR}"
echo ""
echo " Verifica con:"
echo "   systemctl status pm2-${APP_USER}.service"
echo "   su - ${APP_USER} -c 'pm2 status'"
echo "   su - ${APP_USER} -c 'pm2 logs ${PM2_APP_NAME}'   # per lo scan del QR"
echo "======================================================"
