#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Aggiornamento di OpenWA (installazione PM2 su Debian)
#
# Uso (come root):
#   ./update-openwa.sh                 aggiorna all'ultima release (tag vX.Y.Z)
#   ./update-openwa.sh --ref v0.24.0   aggiorna a una release precisa
#   ./update-openwa.sh --ref main      aggiorna al branch main (sconsigliato in produzione)
#   ./update-openwa.sh -y              senza chiedere conferma
#   ./update-openwa.sh --force         anche se la versione e' gia' quella richiesta
#   ./update-openwa.sh --rollback      torna alla versione in OpenWA_old
#
# Segue il runbook ufficiale "Version Upgrade" (docs/11-operational-runbooks.md):
#   1. clona la nuova versione in OpenWA_new e la compila (l'app attuale gira ancora)
#   2. ferma l'app (nessun backup: la copia di sicurezza e' OpenWA_old)
#   3. la nuova versione riparte PULITA: data/ viene ricreata vuota (nessun
#      database copiato). La API key admin resta la stessa perche' viene scritta
#      in .env come API_MASTER_KEY: al primo avvio OpenWA la ricrea identica.
#   4. esegue le migrazioni del database (npm run migration:run:prod)
#   5. OpenWA -> OpenWA_old, OpenWA_new -> OpenWA, riavvio con PM2
#   6. controlla /api/health; se non risponde torna da solo alla versione precedente
#
# OpenWA_old contiene i dati precedenti, quindi un rollback riporta tutto com'era
# (sessioni escluse).
# ============================================================

# ---- Configurazione ----
APP_USER="nodeapp"
APP_DIR="/home/${APP_USER}/OpenWA"
NEW_DIR="${APP_DIR}_new"
OLD_DIR="${APP_DIR}_old"
# Cartella temporanea su disco, usata SOLO da npm durante l'aggiornamento
# (/tmp su Debian 13 e' in RAM). Viene cancellata a fine script, quindi l'app
# non deve mai ereditarla: i comandi PM2 usano TMPDIR=/tmp (vedi as_app_pm2).
# Nome diverso dal vecchio ".openwa-tmp", che le versioni precedenti dello script
# lasciavano come TMPDIR dell'app: cosi' questo script non lo cancella mai.
WORK_TMP="/home/${APP_USER}/.openwa-update-tmp"
REPO_URL="https://github.com/rmyndharis/OpenWA.git"
PM2_APP_NAME="openwa"
RUN_MIGRATIONS=1
HEALTH_TIMEOUT=120                               # secondi di attesa per /api/health

# File di configurazione da portare nella nuova versione (obbligatori)
KEEP_FILES=(".env" "ecosystem.config.js")
# Nessun file di data/ viene portato nella nuova versione: si riparte puliti.
# La API key admin viene conservata tramite API_MASTER_KEY in .env (vedi sotto).
BOOTSTRAP_KEY_FILE="data/.api-key"
# Cartelle grandi cancellate da OpenWA_old ad aggiornamento
# riuscito (data/sessions = profili Chromium di whatsapp-web.js, diversi GB).
DROP_DATA=("data/sessions")
# -------------------------

REF=""
ASSUME_YES=0
FORCE=0
MODE="update"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) REF="${2:?--ref richiede un valore}"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    --force) FORCE=1; shift ;;
    --rollback) MODE="rollback"; shift ;;
    -h|--help) sed -n '4,13p' "$0"; exit 0 ;;
    *) echo "Opzione sconosciuta: $1" >&2; exit 1 ;;
  esac
done

as_app() { su - "$APP_USER" -c "export TMPDIR='${WORK_TMP}' TMP='${WORK_TMP}' TEMP='${WORK_TMP}'; $1"; }
log() { echo "==> $*"; }
warn() { echo "!!  $*" >&2; }

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  read -r -p "$1 [s/N] " ans
  [[ "$ans" =~ ^[sSyY]$ ]]
}

app_version() {
  node -p "require('$1/package.json').version" 2>/dev/null || echo "?"
}

app_port() {
  local p
  p="$(grep -E '^[[:space:]]*PORT[[:space:]]*=' "$1/.env" 2>/dev/null | tail -n 1 | sed 's/#.*//; s/.*=//; s/[[:space:]"]//g')" || true
  echo "${p:-2785}"
}

# Chromium (whatsapp-web.js) puo' sopravvivere allo stop di PM2 o lasciare i file
# di blocco "Singleton*" nel profilo: al riavvio darebbe "The browser is already
# running for .../data/sessions/...". Il server e' dedicato, quindi si chiudono
# tutti i Chromium dell'utente e si tolgono i blocchi prima di ogni avvio.
cleanup_browsers() {
  pkill -u "$APP_USER" -f 'chrom(e|ium)' 2>/dev/null || true
  sleep 2
  pkill -9 -u "$APP_USER" -f 'chrom(e|ium)' 2>/dev/null || true
  if [[ -d "$1/data/sessions" ]]; then
    find "$1/data/sessions" -maxdepth 2 -name 'Singleton*' -delete 2>/dev/null || true
  fi
}

# Comandi PM2 SENZA la cartella temporanea dello script: l'app eredita l'ambiente
# di "pm2 start", e WORK_TMP viene cancellata a fine script. Con TMPDIR inesistente
# Chrome non riesce a creare il suo lock e Puppeteer risponde, in modo fuorviante,
# "The browser is already running for .../data/sessions/...".
as_app_pm2() { su - "$APP_USER" -c "export TMPDIR=/tmp TMP=/tmp TEMP=/tmp; $1"; }

pm2_restart_from() {
  as_app_pm2 "pm2 delete '${PM2_APP_NAME}' >/dev/null 2>&1 || true"
  cleanup_browsers "$1"
  as_app_pm2 "cd '$1' && pm2 start ecosystem.config.js && pm2 save"
}

wait_healthy() {
  local url="http://127.0.0.1:$(app_port "$1")/api/health" waited=0
  log "Attendo che ${url} risponda (max ${HEALTH_TIMEOUT}s)..."
  while (( waited < HEALTH_TIMEOUT )); do
    if curl -fsS -o /dev/null --max-time 5 "$url"; then
      echo "    OK dopo ${waited}s"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

do_rollback() {
  if [[ ! -d "$OLD_DIR" ]]; then
    warn "${OLD_DIR} non esiste: niente a cui tornare."
    return 1
  fi
  local failed="${APP_DIR}_failed_$(date +%Y%m%d-%H%M%S)"
  log "Rollback: $(app_version "$APP_DIR") -> $(app_version "$OLD_DIR")"
  as_app_pm2 "pm2 stop '${PM2_APP_NAME}'" || true
  mv "$APP_DIR" "$failed"
  mv "$OLD_DIR" "$APP_DIR"
  pm2_restart_from "$APP_DIR"
  echo "    Versione non funzionante conservata in: ${failed}"
  echo "    (i messaggi ricevuti mentre girava sono in ${failed}/data)"
}

# ---------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Questo script va eseguito come root." >&2
  exit 1
fi

mkdir -p "$WORK_TMP"
chown "$APP_USER": "$WORK_TMP"
chmod 700 "$WORK_TMP"
trap 'rm -rf "${WORK_TMP:?}"' EXIT

if [[ "$MODE" == "rollback" ]]; then
  confirm "Tornare alla versione in ${OLD_DIR}?" || exit 0
  do_rollback
  wait_healthy "$APP_DIR" || warn "L'app non risponde, controlla: su - ${APP_USER} -c 'pm2 logs ${PM2_APP_NAME}'"
  exit 0
fi

[[ -d "$APP_DIR" ]] || { echo "Cartella ${APP_DIR} non trovata: usa prima lo script di deploy." >&2; exit 1; }
for f in "${KEEP_FILES[@]}"; do
  [[ -f "${APP_DIR}/${f}" ]] || { echo "File ${APP_DIR}/${f} mancante, interrompo." >&2; exit 1; }
done

# ---- Versione di destinazione ----
CURRENT_VERSION="$(app_version "$APP_DIR")"
if [[ -z "$REF" ]]; then
  TAGS="$(git -c versionsort.suffix=- ls-remote --tags --refs --sort=-v:refname "$REPO_URL" 'v*')"
  REF="$(echo "$TAGS" | sed 's#.*refs/tags/##' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)"
  [[ -n "$REF" ]] || { echo "Nessuna release trovata su ${REPO_URL}" >&2; exit 1; }
fi

echo ""
echo " Versione installata: ${CURRENT_VERSION}"
echo " Destinazione:        ${REF}"
echo " Note di rilascio:    https://github.com/rmyndharis/OpenWA/blob/${REF}/CHANGELOG.md"
echo " Rischi noti:         https://github.com/rmyndharis/OpenWA/blob/${REF}/docs/14-migration-guide.md#known-upgrade-hazards"
echo ""

if [[ "$REF" == "v${CURRENT_VERSION}" && $FORCE -eq 0 ]]; then
  echo "Sei gia' alla versione ${REF}. Usa --force per reinstallarla."
  exit 0
fi
confirm "Procedo con l'aggiornamento?" || exit 0

# ---- Gestione errori: riavvia la versione vecchia se non e' ancora stata sostituita ----
APP_STOPPED=0
SWAPPED=0
on_error() {
  local rc=$?
  trap - ERR
  warn "Errore durante l'aggiornamento (riga ${BASH_LINENO[0]}, codice ${rc})."
  if [[ $APP_STOPPED -eq 1 && $SWAPPED -eq 0 ]]; then
    warn "Riavvio la versione precedente, non e' stato modificato nulla in ${APP_DIR}."
    pm2_restart_from "$APP_DIR" || true
  fi
  [[ $SWAPPED -eq 0 ]] && warn "La cartella ${NEW_DIR} e' rimasta per analizzare il problema."
  exit "$rc"
}
trap on_error ERR

# ---- Spazio su disco ----
# Serve spazio per la nuova versione (codice, node_modules, build): ~1.5 GB
NEED_KB=1536000
FREE_KB="$(df -Pk "/home/${APP_USER}" | awk 'NR==2 {print $4}')"
echo " Spazio necessario ~$((NEED_KB / 1024)) MB, libero $((FREE_KB / 1024)) MB"
if (( FREE_KB < NEED_KB )); then
  warn "Spazio su disco insufficiente: libera spazio (cartelle OpenWA_failed_*) e riprova."
  exit 1
fi

# ---- 1. Nuova versione ----
log "Clono ${REF} in ${NEW_DIR}..."
rm -rf "$NEW_DIR"
as_app "git clone --quiet --depth 1 --branch '${REF}' '${REPO_URL}' '${NEW_DIR}'"

log "Copio la configurazione..."
for f in "${KEEP_FILES[@]}"; do
  cp -a "${APP_DIR}/${f}" "${NEW_DIR}/${f}"
  echo "    ${f}"
done
echo "ecosystem.config.js" >> "${NEW_DIR}/.git/info/exclude"

# ---- API key: la stessa anche su un'installazione pulita ----
# Al primo avvio, se non esistono API key, OpenWA crea la chiave admin usando
# API_MASTER_KEY. Mettendo li' la chiave attuale, la nuova versione la ricrea identica.
if grep -qE '^[[:space:]]*API_MASTER_KEY=[^[:space:]#]' "${NEW_DIR}/.env"; then
  echo "    API key admin: gia' fissata in .env (API_MASTER_KEY)"
elif [[ -s "${APP_DIR}/${BOOTSTRAP_KEY_FILE}" ]]; then
  CURRENT_KEY="$(tr -d '[:space:]' < "${APP_DIR}/${BOOTSTRAP_KEY_FILE}")"
  sed -i '/^[[:space:]]*API_MASTER_KEY=/d' "${NEW_DIR}/.env"
  printf '\n# API key admin, conservata da update-openwa.sh\nAPI_MASTER_KEY=%s\n' "$CURRENT_KEY" >> "${NEW_DIR}/.env"
  echo "    API key admin: copiata da ${BOOTSTRAP_KEY_FILE} in .env (API_MASTER_KEY)"
else
  warn "Nessuna API key trovata (${BOOTSTRAP_KEY_FILE} e API_MASTER_KEY assenti):"
  warn "la nuova versione generera' una nuova chiave admin in data/.api-key."
fi

log "Installo le dipendenze e compilo (l'app attuale resta attiva)..."
as_app "cd '${NEW_DIR}' && npm ci && npm run build && npm run dashboard:build"

# ---- 2. Stop ----
log "Fermo l'app..."
APP_STOPPED=1
as_app_pm2 "pm2 stop '${PM2_APP_NAME}'" || true

# ---- 3. Dati: si riparte puliti ----
log "Creo data/ vuota (nessun database copiato)..."
rm -rf "${NEW_DIR:?}/data"
mkdir -p "${NEW_DIR}/data"
chown "$APP_USER": "${NEW_DIR}/data"
chmod 700 "${NEW_DIR}/data"

# ---- 4. Migrazioni (nella nuova versione: OpenWA resta intatto) ----
if [[ $RUN_MIGRATIONS -eq 1 ]]; then
  log "Eseguo le migrazioni del database..."
  as_app "cd '${NEW_DIR}' && NODE_ENV=production npm run migration:run:prod"
fi

# ---- 5. Scambio e riavvio ----
log "Sostituisco le cartelle..."
rm -rf "$OLD_DIR"
mv "$APP_DIR" "$OLD_DIR"
mv "$NEW_DIR" "$APP_DIR"
SWAPPED=1
trap - ERR

log "Avvio la nuova versione con PM2..."
if ! pm2_restart_from "$APP_DIR" || ! wait_healthy "$APP_DIR"; then
  warn "La nuova versione non risponde. Ultime righe di log:"
  as_app_pm2 "pm2 logs '${PM2_APP_NAME}' --lines 40 --nostream" || true
  warn "Torno automaticamente alla versione precedente."
  do_rollback
  wait_healthy "$APP_DIR" || warn "Anche la versione precedente non risponde: controlla pm2 logs."
  exit 1
fi

# Controllo: l'app deve avere una cartella temporanea che esiste davvero,
# altrimenti Chrome non parte ("The browser is already running for ...").
APP_PID="$(pgrep -u "$APP_USER" -f 'dist/main' | head -n 1 || true)"
if [[ -n "$APP_PID" ]]; then
  APP_TMP="$(tr '\0' '\n' < "/proc/${APP_PID}/environ" | sed -n 's/^TMPDIR=//p' | head -n 1)"
  APP_TMP="${APP_TMP:-/tmp}"
  if [[ -d "$APP_TMP" ]]; then
    echo "    Cartella temporanea dell'app: ${APP_TMP} (ok)"
  else
    warn "L'app usa TMPDIR=${APP_TMP}, che non esiste: le sessioni non partiranno."
    warn "Controlla il file /home/${APP_USER}/.pm2/dump.pm2 e l'ambiente di PM2."
  fi
fi

# Le sessioni non servono piu' nemmeno in OpenWA_old: libero spazio
for x in "${DROP_DATA[@]}"; do
  if [[ -e "${OLD_DIR}/${x}" ]]; then
    log "Libero spazio: elimino ${OLD_DIR}/${x}"
    rm -rf "${OLD_DIR:?}/${x}"
  fi
done

echo ""
echo "======================================================"
echo " Aggiornamento completato: ${CURRENT_VERSION} -> $(app_version "$APP_DIR")"
echo " Versione attiva:     ${APP_DIR}"
echo " Versione precedente: ${OLD_DIR}"
echo ""
echo " Installazione pulita: la API key admin e' la stessa; sessioni, webhook,"
echo " altre API key e impostazioni della dashboard vanno ricreati (QR da scansionare)."
echo "   su - ${APP_USER} -c 'pm2 logs ${PM2_APP_NAME}'"
echo "   curl -H \"X-API-Key: \$API_KEY\" http://127.0.0.1:$(app_port "$APP_DIR")/api/sessions"
echo ""
echo " Per tornare indietro:  $0 --rollback"
echo "======================================================"