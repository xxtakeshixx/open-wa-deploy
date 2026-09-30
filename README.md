# OpenWA su Debian: installazione, aggiornamento e manutenzione

Documentazione dell'installazione di [OpenWA](https://github.com/rmyndharis/OpenWA) (gateway API WhatsApp self-hosted) su Debian, gestita con PM2 e due script:

| Script | A cosa serve |
|---|---|
| `deploy-openwa.sh` | Prima installazione del server |
| `update-openwa.sh` | Aggiornamenti successivi e rollback |
| `firewall-openwa.sh` | Firewall locale (nftables) |

Entrambi vanno eseguiti come **root**.

---

## 1. Struttura sul server

```
/home/nodeapp/
├── OpenWA/                 versione attiva (quella che gira in PM2)
│   ├── .env                configurazione principale
│   ├── ecosystem.config.js configurazione PM2
│   ├── dist/               backend compilato
│   └── data/               TUTTO LO STATO (vedi sotto)
├── OpenWA_old/             versione precedente, intatta, per il rollback
├── OpenWA_failed_<data>/   (solo dopo un rollback automatico, da cancellare a mano)
└── openwa-backups/         archivi di backup, uno per ogni aggiornamento
```

| Elemento | Valore |
|---|---|
| Utente di sistema | `nodeapp` (nessuna password, accesso con `su - nodeapp` da root) |
| Node.js | 22.x da NodeSource (richiesto dal progetto, file `.nvmrc`) |
| Motore WhatsApp | `whatsapp-web.js` (usa Chromium) oppure `baileys` |
| Porta | `2785` (API e dashboard sulla stessa porta) |
| Nome app PM2 | `openwa` |
| Servizio di avvio al boot | `pm2-nodeapp.service` (systemd) |

### Dove sta lo storico: la cartella `data/`

Tutti i dati che non si possono ricreare stanno in `OpenWA/data/`:

| Percorso | Contenuto |
|---|---|
| `data/main.sqlite` | API key e audit log |
| `data/openwa.sqlite` | Messaggi, webhook, sessioni registrate (se il DB è SQLite) |
| `data/sessions/` | Login WhatsApp di whatsapp-web.js (senza questa cartella serve riscansionare il QR) |
| `data/baileys/` | Login WhatsApp del motore Baileys |
| `data/media/` | Media salvati in locale |
| `data/plugins/` | Plugin installati e loro stato |
| `data/.env.generated` | Impostazioni salvate dalla dashboard (Infrastructure) |
| `data/.api-key` | Chiave admin generata al primo avvio |

Oltre a `data/` servono `.env` ed `ecosystem.config.js`. Tutto il resto (codice, `node_modules`, `dist`) si ricrea da GitHub.

> **Con `update-openwa.sh` a ogni aggiornamento si riparte puliti:** della cartella `data/` vengono conservati solo `main.sqlite` e `.api-key` (le API key). Vedi sezione 3.

> Ordine di priorità della configurazione: variabili d'ambiente > `.env` > `data/.env.generated`.
> Un valore scritto in `.env` vince sempre su quello impostato dalla dashboard.

---

## 2. Prima installazione (`deploy-openwa.sh`)

```bash
chmod +x deploy-openwa.sh
./deploy-openwa.sh
```

Cosa fa:

1. installa `git`, `curl`, `openssl`, Node.js 22 (se manca o è più vecchio) e PM2;
2. installa Chromium se il motore è `whatsapp-web.js`;
3. crea l'utente `nodeapp`;
4. clona il repository in `/home/nodeapp/OpenWA` ed esegue `npm install`;
5. crea `.env` da `.env.example` con una API key casuale, `NODE_ENV=production`, porta ed engine;
6. compila backend e dashboard;
7. scrive `ecosystem.config.js`, configura l'avvio al boot e avvia l'app con PM2.

Dopo il deploy, per collegare il numero guarda il QR nei log:

```bash
su - nodeapp -c 'pm2 logs openwa'
```

### Correzioni da applicare allo script di deploy

La versione attuale dello script ha due problemi da sistemare prima di riusarlo:

- **`su - "$APP_USER" bash -c "..."` non funziona** (nelle sezioni `.env` ed `ecosystem.config.js`): la shell di login riceve `bash` come nome di uno script da eseguire e fallisce. Va scritto `su - "$APP_USER" -c "..."`.
- **`sudo useradd`**: lo script gira già come root e su una Debian minimale `sudo` può mancare. Togliere `sudo`.

---

## 3. Aggiornamento (`update-openwa.sh`)

### Uso normale

```bash
chmod +x update-openwa.sh   # solo la prima volta
./update-openwa.sh
```

Senza argomenti lo script cerca **l'ultima release pubblicata** su GitHub (tag `vX.Y.Z`), mostra versione attuale e destinazione con i link a changelog e rischi noti, chiede conferma e procede. Se sei già all'ultima versione esce senza fare nulla, quindi si può lanciare quante volte si vuole.

### Opzioni

| Comando | Effetto |
|---|---|
| `./update-openwa.sh` | Aggiorna all'ultima release (consigliato) |
| `./update-openwa.sh -y` | Come sopra, senza chiedere conferma (per cron) |
| `./update-openwa.sh --ref v0.24.0` | Aggiorna a una release precisa (il tag deve esistere su GitHub) |
| `./update-openwa.sh --ref main` | Aggiorna all'ultimo codice di `main`, anche non rilasciato |
| `./update-openwa.sh --force` | Reinstalla anche se la versione è già quella richiesta |
| `./update-openwa.sh --rollback` | Torna alla versione in `OpenWA_old` |
| `./update-openwa.sh --help` | Mostra l'aiuto |

> **Release o `main`?** Le release sono versioni dichiarate stabili. `main` riceve le modifiche prima del rilascio: subito dopo un merge di rilascio coincide con la nuova versione, ma nei giorni successivi contiene codice non ancora rilasciato. Con `--ref main` lo script aggiorna ogni volta, perché non ha un numero di versione da confrontare.
>
> **Sconsigliato `--force`** se non serve: reinstallando la stessa versione, `OpenWA_old` diventa una copia di quella attuale e si perde la versione precedente vera.

### Cosa fa, passo per passo

Lo script segue il runbook ufficiale del progetto (`docs/11-operational-runbooks.md`, "Version Upgrade"):

0. **Controlla lo spazio su disco** prima di iniziare (circa 2 volte `data/` senza sessioni, più 1,5 GB). Tutti i file temporanei vanno in `/home/nodeapp/.openwa-tmp` invece che in `/tmp`.
1. **Prepara la nuova versione mentre l'app vecchia gira ancora.** Clona la release in `OpenWA_new`, copia `.env` ed `ecosystem.config.js`, esegue `npm ci`, `npm run build` e `npm run dashboard:build`. Se qualcosa fallisce qui, la produzione non viene toccata.
2. **Ferma l'app e fa il backup.** Usa lo script ufficiale `scripts/backup.sh` del progetto (installa `sqlite3` se manca, per una copia consistente dei database). L'archivio finisce in `/home/nodeapp/openwa-backups/`; vengono conservati gli ultimi 10.
3. **Riparte pulito, tranne le API key.** Nella nuova versione vengono portati solo `data/main.sqlite` (API key e audit log) e `data/.api-key`, oltre a `.env` ed `ecosystem.config.js`. Tutto il resto viene ricreato vuoto: **sessioni** (da riabbinare con il QR), **webhook**, messaggi salvati, media, plugin e impostazioni salvate dalla dashboard (`data/.env.generated`). Le API key continuano a funzionare, ma quelle limitate a sessioni specifiche (`allowedSessions`) vanno aggiornate con gli id delle sessioni nuove. `OpenWA` viene rinominato in `OpenWA_old` senza toccarne i dati, quindi un rollback riporta tutto com'era, sessioni escluse.
4. **Esegue le migrazioni del database** (`npm run migration:run:prod`) sulla copia.
5. **Scambia le cartelle:** cancella il vecchio `OpenWA_old`, rinomina `OpenWA` in `OpenWA_old` e `OpenWA_new` in `OpenWA`.
6. **Riavvia con PM2** e verifica `http://127.0.0.1:2785/api/health` per massimo 2 minuti.
7. **Se l'app non risponde, torna da sola alla versione precedente** e mostra le ultime righe di log.

Se un errore avviene dopo lo stop ma prima dello scambio (backup, spazio, migrazioni), lo script riavvia la versione vecchia senza aver modificato nulla. La cartella `OpenWA_new` rimane per capire cosa è andato storto e viene cancellata al lancio successivo.

### Parametri modificabili

In testa allo script:

| Variabile | Default | Significato |
|---|---|---|
| `APP_USER` | `nodeapp` | Utente che esegue l'app |
| `APP_DIR` | `/home/nodeapp/OpenWA` | Cartella della versione attiva |
| `BACKUP_DIR` | `/home/nodeapp/openwa-backups` | Dove vanno gli archivi |
| `KEEP_BACKUPS` | `10` | Quanti archivi conservare |
| `WORK_TMP` | `/home/nodeapp/.openwa-tmp` | Cartella temporanea su disco usata da npm e backup al posto di `/tmp` (cancellata a fine script) |
| `PM2_APP_NAME` | `openwa` | Nome dell'app in PM2 |
| `RUN_MIGRATIONS` | `1` | `0` per saltare le migrazioni |
| `HEALTH_TIMEOUT` | `120` | Secondi di attesa per `/api/health` |
| `KEEP_FILES` | `.env`, `ecosystem.config.js` | File di configurazione da portare |
| `KEEP_STATE` | `data/main.sqlite` (+ `-wal`/`-shm`), `data/.api-key` | Unico stato portato nella nuova versione: le API key |
| `DROP_DATA` | `data/sessions` | Cartelle escluse dal backup e cancellate da `OpenWA_old` ad aggiornamento riuscito |

---

## 4. PM2

L'aggiornamento **non sporca PM2**:

- esiste sempre una sola app `openwa`, che punta a `/home/nodeapp/OpenWA`;
- lo script elimina e ricrea l'app invece di fare `pm2 restart`, perché dopo lo spostamento il processo vecchio punterebbe ancora alla cartella rinominata in `OpenWA_old`;
- `pm2 save` finale aggiorna lo stato salvato, quindi al riavvio del server parte la versione nuova;
- il servizio `pm2-nodeapp.service`, i log e le impostazioni di `ecosystem.config.js` restano gli stessi;
- cambiano solo l'id numerico in `pm2 status` e il contatore dei riavvii;
- eventuali altre app PM2 dell'utente `nodeapp` non vengono toccate.

Impostazioni in `ecosystem.config.js`:

| Parametro | Valore | Note |
|---|---|---|
| `script` / `cwd` | `dist/main.js` in `/home/nodeapp/OpenWA` | Percorso fisso, resta valido dopo gli aggiornamenti |
| `max_memory_restart` | `500M` | Basso per whatsapp-web.js (300–500 MB per sessione): verificare con `pm2 monit` |
| `cron_restart` | `0 4 * * *` | Riavvio ogni notte alle 4 |
| `restart_delay` / `exp_backoff_restart_delay` | `4000` / `100` | Due strategie alternative: conviene tenerne una sola |

Comandi utili:

```bash
su - nodeapp -c 'pm2 status'                              # una sola riga "openwa", online
su - nodeapp -c 'pm2 logs openwa'                         # log in tempo reale (QR, errori)
su - nodeapp -c 'pm2 describe openwa' | grep -E 'status|exec cwd'
systemctl status pm2-nodeapp.service                      # avvio al boot
```

I log stanno in `/home/nodeapp/.pm2/logs/openwa-out.log` e `openwa-error.log`.

---

## 5. Node.js

`update-openwa.sh` **non aggiorna Node.js**.

- **Aggiornamenti di Node 22.x:** arrivano con Debian, dal repository NodeSource aggiunto dal deploy:

  ```bash
  apt-get update && apt-get upgrade
  su - nodeapp -c 'pm2 update'   # riavvia PM2 e l'app con il nuovo Node
  ```

- **Cambio di versione principale (es. 22 → 24):** va fatto a mano, se una release futura lo richiede (controllare `.nvmrc` nel repo e il changelog). Se Node è troppo vecchio la build fallisce al passo 1 e la produzione resta attiva:

  ```bash
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
  apt-get install -y nodejs
  su - nodeapp -c 'pm2 update'
  ```

---

## 6. Rollback

### Automatico

Se dopo l'aggiornamento `/api/health` non risponde entro 2 minuti, lo script:

1. ferma l'app;
2. sposta la versione nuova in `OpenWA_failed_<data>`;
3. rimette `OpenWA_old` al posto di `OpenWA` e riavvia.

### Manuale

Se l'app parte ma qualcosa non va:

```bash
./update-openwa.sh --rollback
```

Da sapere:

- `OpenWA_old` contiene i dati com'erano **prima** dell'aggiornamento. I messaggi ricevuti mentre girava la versione nuova restano in `OpenWA_failed_<data>/data`.
- Il progetto avverte che, tornando a una versione precedente alla 0.23.5, servono le sessioni salvate prima dell'aggiornamento (cambiano i nomi delle cartelle di sessione e la versione di Chrome). `OpenWA_old` le contiene intatte, quindi il rollback funziona.
- Tornare a una versione precedente alla 0.23.6 fa perdere le restrizioni per chat delle API key.
- Le cartelle `OpenWA_failed_*` non vengono cancellate da sole: eliminarle quando non servono più.

### Ripristino da un archivio di backup

Se `OpenWA_old` non basta (per esempio serve un backup più vecchio), si usa lo script ufficiale del progetto con l'app ferma:

```bash
su - nodeapp -c 'pm2 stop openwa'
su - nodeapp -c 'cd /home/nodeapp/OpenWA && ./scripts/restore.sh /home/nodeapp/openwa-backups/openwa-backup-<data>.tar.gz --force'
su - nodeapp -c 'pm2 start openwa'
```

`restore.sh` fa prima una copia di sicurezza dei dati attuali (`data.pre-restore-<data>`). `--force` serve perché i database esistenti contengono già dati.

---

## 7. Backup

- Ogni aggiornamento crea un archivio `openwa-backup-<data>.tar.gz` in `/home/nodeapp/openwa-backups/` (permessi `700`).
- Gli archivi contengono database, sessioni, API key e segreti: vanno trattati come dati riservati e copiati anche fuori dal server.
- Per un backup fuori dagli aggiornamenti:

  ```bash
  su - nodeapp -c 'cd /home/nodeapp/OpenWA && BACKUP_DIR=/home/nodeapp/openwa-backups ./scripts/backup.sh'
  ```

  Con l'app attiva il backup dei database è comunque consistente (grazie a `sqlite3`), mentre le sessioni WhatsApp potrebbero essere copiate a metà scrittura: nel peggiore dei casi, dopo un ripristino, una sessione va riabbinata.

---

## 8. Controlli dopo un aggiornamento

```bash
su - nodeapp -c 'pm2 status'                                  # openwa online
curl http://127.0.0.1:2785/api/health                         # risponde
curl -H "X-API-Key: $API_KEY" http://127.0.0.1:2785/api/health | jq '.version'
curl -H "X-API-Key: $API_KEY" http://127.0.0.1:2785/api/sessions   # sessioni riconnesse
```

Se le sessioni tornano al QR invece di riconnettersi, controllare i log e, se serve, fare rollback.

---

## 9. Note sulla versione 0.24.0

Dal changelog del progetto (sezione "Known Upgrade Hazards" in `docs/14-migration-guide.md`):

- una API key rifiutata per IP (`allowedIps`) o per sessione (`allowedSessions`) risponde `403` invece di `401`;
- `main.sqlite` esegue le proprie migrazioni a ogni avvio; se trova una migrazione sconosciuta si ferma con `MainSchemaMismatchError` (per questo il backup prima dell'aggiornamento è importante);
- `POST /mcp` richiede sempre una API key valida;
- il controllo dei numeri (`contacts/check`) richiede una chiave OPERATOR;
- modificare il proxy di una sessione richiede una chiave ADMIN;
- cancellare una chat elimina anche le copie dei messaggi e dei media salvate dal gateway.

Prima di ogni aggiornamento conviene leggere la stessa sezione per la versione di destinazione: lo script ne stampa il link.

---

## 10. Problemi frequenti

| Sintomo | Causa probabile | Cosa fare |
|---|---|---|
| Lo script si ferma al clone | Il tag passato con `--ref` non esiste | Lanciare senza `--ref`, o verificare i tag su GitHub |
| Errore in `npm ci` o nella build | Versione di Node non adatta, rete, dipendenze | La produzione è ancora attiva; controllare l'output e Node (sezione 5) |
| "Spazio su disco insufficiente" all'avvio | Servono circa 2 volte `data/` (sessioni escluse) più 1,5 GB | Liberare spazio o cancellare vecchi backup / `OpenWA_failed_*` |
| Errori "No space left" o "Permission denied" su file temporanei | `/tmp` in RAM (Debian 13) o montato `noexec` | Già risolto: lo script usa `WORK_TMP` su disco |
| Errore nelle migrazioni | Schema del database non compatibile | L'app vecchia viene riavviata; leggere l'errore e la guida di migrazione |
| Rollback automatico | La nuova versione non risponde a `/api/health` | Vedere i log stampati e quelli in `OpenWA_failed_<data>` |
| Riavvii continui in PM2 | `max_memory_restart` troppo basso | Alzare il limite in `ecosystem.config.js` |
| Sessioni tornano al QR | `data/sessions` mancante o rovinato | Rollback, o ripristino da backup |

---

## 11. Firewall (`firewall-openwa.sh`)

Il server è raggiungibile solo dalla rete locale e sta dietro un firewall perimetrale che non lo espone su internet. Il firewall sul server (nftables, quello standard di Debian) è una seconda barriera, per esempio contro altri dispositivi compromessi nella LAN.

### Regole

| Direzione | Cosa passa |
|---|---|
| Ingresso | SSH e OpenWA (porta `2785`, API e dashboard) **solo dalle reti locali**; ping dalla LAN; ICMPv6 indispensabile; risposte a connessioni già aperte |
| Ingresso, tutto il resto | Scartato |
| Inoltro (forward) | Bloccato (il server non fa da router) |
| Uscita | Libera: serve per WhatsApp, GitHub, npm, apt e l'invio dei webhook |

### Uso

```bash
chmod +x firewall-openwa.sh
./firewall-openwa.sh            # configura e attiva
./firewall-openwa.sh --status   # mostra le regole attive e i pacchetti scartati
./firewall-openwa.sh --off      # disattiva il firewall (tutto aperto)
```

Lo script rileva da solo:

- la **sottorete locale**, dall'interfaccia di rete principale;
- la **porta SSH**, dalla configurazione di `sshd`;
- la **porta di OpenWA**, da `.env`.

Mostra i valori trovati e chiede conferma. Se l'IP da cui sei collegato in SSH non rientra nelle reti ammesse, si ferma prima di applicare qualsiasi regola.

### Protezione contro il blocco dell'accesso

1. Salva le regole attuali in `/root/nftables.backup-<data>.nft`.
2. Applica le nuove regole (la sessione SSH in corso resta aperta).
3. Chiede di provare **una nuova sessione SSH** e l'accesso alla dashboard da un PC della rete locale, poi di confermare entro 60 secondi.
4. Senza conferma ripristina le regole precedenti. Solo con la conferma le salva in `/etc/nftables.conf` e attiva il servizio `nftables`, così restano dopo il riavvio.

### Reti aggiuntive

Di default è ammessa solo la sottorete del server. Se client, gestionali o altri server che chiamano l'API stanno in **altre sottoreti o VLAN**, vanno aggiunte in testa allo script:

```bash
LAN_NETS="192.168.1.0/24 10.10.0.0/16"
```

Poi rilanciare lo script. Lo stesso vale se la porta di OpenWA cambia.

### Note

- Lo script si rifiuta di partire se sono attivi `ufw` o `firewalld`, per non avere due firewall in conflitto.
- Gli aggiornamenti di OpenWA non richiedono modifiche al firewall, perché il traffico in uscita è libero.
- Se OpenWA non risponde dalla LAN, verificare con `./firewall-openwa.sh --status` che la rete del client sia nel set `lan4` e guardare il contatore della regola `drop`.

---

## Riferimenti

- Repository: <https://github.com/rmyndharis/OpenWA>
- Runbook operativi: `docs/11-operational-runbooks.md`
- Guida di migrazione e rischi noti: `docs/14-migration-guide.md`
- Script ufficiali di backup e ripristino: `scripts/backup.sh`, `scripts/restore.sh`