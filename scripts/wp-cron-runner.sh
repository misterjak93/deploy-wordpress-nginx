#!/bin/bash
# =======================================================
# Esecutore del cron di WordPress
# =======================================================
# Sostituisce il cron interno, disattivato in wp-config.php. Vedi il
# commento nel blocco [program:wp-cron] di supervisord.conf.
set -u

INTERVAL="${WP_CRON_INTERVAL:-60}"
: "${WP_ROOT:=/var/www/wordpress/html}"

log()  { printf 'wp-cron: %s\n' "$*"; }
warn() { printf 'wp-cron: %s\n' "$*" >&2; }

# -------------------------------------------------------
# Attesa dell'installazione
# -------------------------------------------------------
# Non basta che wp-config.php esista: finche' l'installazione non viene
# completata dal browser le tabelle non ci sono, e ogni esecuzione
# fallirebbe con "The site you have requested is not installed".
# Senza questa attesa il log si riempie di un errore al minuto per tutto
# il tempo in cui il sito resta da configurare - che puo' essere giorni.
attesa_segnalata=0
while true; do
    if [ -f "${WP_ROOT}/wp-config.php" ] \
       && /usr/local/bin/wp core is-installed > /dev/null 2>&1; then
        break
    fi
    if [ "${attesa_segnalata}" -eq 0 ]; then
        log "WordPress non ancora installato: in attesa. Questo messaggio non verra' ripetuto."
        attesa_segnalata=1
    fi
    sleep 30
done

log "avvio, intervallo ${INTERVAL}s"

# -------------------------------------------------------
# Ciclo
# -------------------------------------------------------
# ultimo_errore serve a non ripetere la stessa riga ogni minuto: un
# problema persistente (database irraggiungibile, sito disinstallato) si
# segnala una volta, e si torna a segnalare solo quando cambia o quando
# rientra.
ultimo_errore=""

while true; do
    sleep "${INTERVAL}"

    # Il sito puo' sparire sotto i piedi: ripristino di un backup,
    # database svuotato, credenziali cambiate.
    if ! /usr/local/bin/wp core is-installed > /dev/null 2>&1; then
        if [ "${ultimo_errore}" != "__non_installato__" ]; then
            warn "il sito non risulta installato, cron in pausa."
            ultimo_errore="__non_installato__"
        fi
        continue
    fi

    # --quiet perche' il caso normale e' "nessun evento da eseguire" e
    # non deve produrre una riga di log al minuto.
    if out=$(/usr/local/bin/wp cron event run --due-now --quiet 2>&1); then
        [ -n "${ultimo_errore}" ] && log "ripreso."
        ultimo_errore=""
    else
        # Un errore non deve far uscire dal ciclo: il database potrebbe
        # essere solo temporaneamente irraggiungibile.
        if [ "${out}" != "${ultimo_errore}" ]; then
            warn "errore -> ${out}"
            ultimo_errore="${out}"
        fi
    fi
done
