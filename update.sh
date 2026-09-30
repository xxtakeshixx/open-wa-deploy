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
#   2. ferma l'app e fa un backup completo con scripts/backup.sh del progetto
#      (main.sqlite, openwa.sqlite, sessioni, media, plugin, .env.generated, .api-key)
#   3. COPIA data/ nella nuova versione (OpenWA_old resta intatto per il rollback)
#   4. esegue le migrazioni del database (npm run migration:run:prod)
#   5. OpenWA -> OpenWA_old, OpenWA_new -> OpenWA, riavvio con PM2
#   6. controlla /api/health; se non risponde torna da solo alla versione precedente
#
# Lo storico (chat, sessioni WhatsApp, API key, audit log, media) sta tutto in data/:
# viene copiato, mai spostato, e ogni aggiornamento lascia un archivio in BACKUP_DIR.
# ============================================================

# ---- Configurazione ----
APP_USER="nodeapp"
APP_DIR="/home/${APP_USER}/OpenWA"
NEW_DIR="${APP_DIR}_new"
OLD_DIR="${APP_DIR}_old"
BACKUP_DIR="/home/${APP_USER}/openwa-backups"   # fuori dal repo, sopravvive agli aggiornamenti
# Cartella temporanea su disco, usata al posto di /tmp da npm e da backup.sh.
# /tmp su Debian 13 e' in RAM (meta' della memoria): il backup dei media la riempie.
WORK_TMP="/home/${APP_USER}/.openwa-tmp"
KEEP_BACKUPS=10                                  # archivi da conservare
REPO_URL="https://github.com/rmyndharis/OpenWA.git"
PM2_APP_NAME="openwa"
RUN_MIGRATIONS=1
HEALTH_TIMEOUT=120                               # secondi di attesa per /api/health

# File di configurazione da portare nella nuova versione (obbligatori)
KEEP_FILES=(".env" "ecosystem.config.js")
# Cartelle di stato da copiare (se esistono). "plugins" e' la vecchia posizione
# dei plugin (fino alla 0.12.1), oggi stanno in data/plugins.
KEEP_DATA=("data" "plugins")
# Sottocartelle da NON portare nella nuova versione (percorsi relativi a OpenWA/).
# data/sessions = login WhatsApp di whatsapp-web.js: senza, ogni sessione
# va riabbinata con il QR dopo l'aggiornamento. Sono escluse anche dal backup
# (possono pesare diversi GB) e, ad aggiornamento riuscito, cancellate da OpenWA_old.
EXCLUDE_DATA=("data/sessions")
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

pm2_restart_from() {
  as_app "cd '$1' && (pm2 delete '${PM2_APP_NAME}' >/dev/null 2>&1 || true) && pm2 start ecosystem.config.js && pm2 save"
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
  as_app "pm2 stop '${PM2_APP_NAME}'" || true
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

# sqlite3 permette a backup.sh di fare una copia consistente dei database
if ! command -v sqlite3 &>/dev/null; then
  log "Installo sqlite3 (serve per un backup consistente)..."
  apt-get install -y sqlite3 >/dev/null
fi

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
# Servono circa: staging del backup + archivio + copia di data/ + nuova versione (~1.5 GB)
DATA_KB=0
for d in "${KEEP_DATA[@]}"; do
  if [[ -e "${APP_DIR}/${d}" ]]; then
    DATA_KB=$((DATA_KB + $(du -sk "${APP_DIR}/${d}" | cut -f1)))
  fi
done
for x in "${EXCLUDE_DATA[@]}"; do
  if [[ -e "${APP_DIR}/${x}" ]]; then
    DATA_KB=$((DATA_KB - $(du -sk "${APP_DIR}/${x}" | cut -f1)))
  fi
done
NEED_KB=$((DATA_KB * 3 + 1536000))
FREE_KB="$(df -Pk "/home/${APP_USER}" | awk 'NR==2 {print $4}')"
echo " Dati da copiare: $((DATA_KB / 1024)) MB, spazio necessario ~$((NEED_KB / 1024)) MB, libero $((FREE_KB / 1024)) MB"
if (( FREE_KB < NEED_KB )); then
  warn "Spazio su disco insufficiente: libera spazio (vecchi backup, cartelle OpenWA_failed_*) e riprova."
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

log "Installo le dipendenze e compilo (l'app attuale resta attiva)..."
as_app "cd '${NEW_DIR}' && npm ci && npm run build && npm run dashboard:build"

# ---- 2. Stop + backup ----
log "Fermo l'app..."
APP_STOPPED=1
as_app "pm2 stop '${PM2_APP_NAME}'" || true

log "Backup completo in ${BACKUP_DIR}..."
mkdir -p "$BACKUP_DIR"
chown "$APP_USER": "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
if [[ -x "${APP_DIR}/scripts/backup.sh" ]]; then
  # Le cartelle escluse non entrano nemmeno nel backup: backup.sh salta le sessioni
  # se SESSION_DATA_PATH punta a una cartella inesistente.
  SKIP_ENV=""
  for x in "${EXCLUDE_DATA[@]}"; do
    if [[ "$x" == "data/sessions" ]]; then
      SKIP_ENV="SESSION_DATA_PATH='${WORK_TMP}/nessuna-sessione'"
    fi
  done
  as_app "cd '${APP_DIR}' && ${SKIP_ENV} BACKUP_DIR='${BACKUP_DIR}' ./scripts/backup.sh"
else
  # versioni precedenti alla 0.19.0 non hanno backup.sh
  ARCHIVE="${BACKUP_DIR}/openwa-backup-$(date +%Y%m%d-%H%M%S)-data.tar.gz"
  EXCL_ARGS=()
  for x in "${EXCLUDE_DATA[@]}"; do EXCL_ARGS+=("--exclude=./${x}"); done
  as_app "cd '${APP_DIR}' && tar ${EXCL_ARGS[*]} -czf '${ARCHIVE}' ./data ./.env"
  echo "    ${ARCHIVE}"
fi

log "Tengo solo gli ultimi ${KEEP_BACKUPS} backup..."
ls -1t "${BACKUP_DIR}"/openwa-backup-*.tar.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f -- || true

# ---- 3. Dati ----
log "Copio i dati (storico, database, media, plugin)..."
for x in "${EXCLUDE_DATA[@]}"; do echo "    escluso: ${x}"; done
for d in "${KEEP_DATA[@]}"; do
  if [[ -e "${APP_DIR}/${d}" ]]; then
    rm -rf "${NEW_DIR:?}/${d}"
    EXCL_ARGS=()
    for x in "${EXCLUDE_DATA[@]}"; do EXCL_ARGS+=("--exclude=./${x}"); done
    (cd "$APP_DIR" && tar "${EXCL_ARGS[@]}" -cf - "./${d}") | (cd "$NEW_DIR" && tar -xpf -)
    echo "    ${d}"
  fi
done

# ---- 4. Migrazioni (sulla copia: OpenWA resta intatto) ----
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
  as_app "pm2 logs '${PM2_APP_NAME}' --lines 40 --nostream" || true
  warn "Torno automaticamente alla versione precedente."
  do_rollback
  wait_healthy "$APP_DIR" || warn "Anche la versione precedente non risponde: controlla pm2 logs."
  exit 1
fi

# Le cartelle escluse non servono piu' nemmeno in OpenWA_old: libero spazio
for x in "${EXCLUDE_DATA[@]}"; do
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
echo " Backup:              ${BACKUP_DIR}"
echo ""
echo " Le sessioni WhatsApp vanno riabbinate: apri la dashboard e scansiona il QR."
echo "   su - ${APP_USER} -c 'pm2 logs ${PM2_APP_NAME}'"
echo "   curl -H \"X-API-Key: \$API_KEY\" http://127.0.0.1:$(app_port "$APP_DIR")/api/sessions"
echo ""
echo " Per tornare indietro:  $0 --rollback"
echo "======================================================"