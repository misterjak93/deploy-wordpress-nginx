#!/bin/bash
# =======================================================
# Esecutore del cron di WordPress
# =======================================================
# Sostituisce il cron interno, disattivato in wp-config.php. Vedi il
# commento nel blocco [program:wp-cron] di supervisord.conf.
set -u

INTERVAL="${WP_CRON_INTERVAL:-60}"
: "${WP_ROOT:=/var/www/wordpress/html}"

# Nessuna installazione, nessun cron: si aspetta senza riempire i log.
while [ ! -f "${WP_ROOT}/wp-config.php" ]; do
    sleep 30
done

echo "wp-cron: avvio, intervallo ${INTERVAL}s"

while true; do
    sleep "${INTERVAL}"

    # --quiet perche' il caso normale e' "nessun evento da eseguire" e
    # non deve produrre una riga di log al minuto.
    if ! out=$(/usr/local/bin/wp cron event run --due-now --quiet 2>&1); then
        # Un errore va mostrato, ma non deve far uscire il loop: il
        # database potrebbe essere solo temporaneamente irraggiungibile.
        echo "wp-cron: errore -> ${out}" >&2
    fi
done
