#!/bin/sh
# =======================================================
# Varnish - avvio e sorveglianza del backend
# =======================================================
# Questo script fa tre cose:
#   1. genera il VCL dal template, con un backend per ogni indirizzo a
#      cui risponde il nome del container WordPress;
#   2. avvia varnishd;
#   3. resta in ascolto: se quegli indirizzi cambiano, rigenera il VCL e
#      lo ricarica a caldo, senza riavviare Varnish e senza perdere la
#      cache.
#
# Il punto 3 non e' un lusso. Varnish risolve il nome del backend quando
# COMPILA il VCL, non ad ogni richiesta: senza sorveglianza, basta che il
# container WordPress venga ricreato - un redeploy, un riavvio del solo
# servizio - perche' Varnish resti a puntare a un indirizzo che non
# esiste piu' e risponda 503 a tutti finche' qualcuno non lo riavvia a
# mano.
set -eu

TEMPLATE=/etc/varnish/default.vcl.template

# -------------------------------------------------------
# Directory di lavoro
# -------------------------------------------------------
# L'immagine ufficiale gira come utente "varnish", non root, e ha
# WorkingDir /etc/varnish: quella directory NON e' scrivibile.
# Tre cose ne dipendono, e sbagliarne una sola basta a non far partire
# il container:
#   1. il VCL generato da questo script;
#   2. il file secret dell'interfaccia di amministrazione;
#   3. "varnishd -C", che scrive le proprie temporanee nella directory
#      corrente - per questo ci si sposta qui dentro.
RUNTIME_DIR="${VARNISH_RUNTIME_DIR:-/tmp/varnish}"
mkdir -p "${RUNTIME_DIR}" || {
    echo "ERRORE: impossibile creare ${RUNTIME_DIR}." >&2
    exit 1
}
cd "${RUNTIME_DIR}"

TARGET="${RUNTIME_DIR}/default.vcl"

VARNISH_SIZE="${VARNISH_SIZE:-256m}"
VARNISH_TTL="${VARNISH_TTL:-6h}"
VARNISH_STATIC_TTL="${VARNISH_STATIC_TTL:-7d}"
VARNISH_GRACE="${VARNISH_GRACE:-24h}"
VARNISH_BACKEND_TIMEOUT="${VARNISH_BACKEND_TIMEOUT:-300}"
VARNISH_THREAD_POOLS="${VARNISH_THREAD_POOLS:-2}"
VARNISH_THREAD_MIN="${VARNISH_THREAD_MIN:-100}"
VARNISH_THREAD_MAX="${VARNISH_THREAD_MAX:-1000}"
COMPRESSION_PRIORITY="${COMPRESSION_PRIORITY:-br,zstd,gzip}"
BACKEND_HOST="${BACKEND_HOST:-wordpress}"
BACKEND_PORT="${BACKEND_PORT:-80}"
# Ogni quanto ricontrollare gli indirizzi del backend. 0 disattiva la
# sorveglianza e riporta al comportamento "risolvi una volta e basta".
BACKEND_RECHECK_INTERVAL="${BACKEND_RECHECK_INTERVAL:-15}"
# Segreto condiviso con WordPress per PURGE e BAN. Vuoto = solo ACL.
PURGE_TOKEN="${PURGE_TOKEN:-}"

ADMIN_ADDR=127.0.0.1:6082
SECRET_FILE="${RUNTIME_DIR}/secret"

log()  { echo "Varnish: $*"; }
warn() { echo "Varnish: $*" >&2; }

# -------------------------------------------------------
# Secret dell'interfaccia di amministrazione
# -------------------------------------------------------
# Anche questo in RUNTIME_DIR: /etc/varnish e' sola lettura. Se
# l'immagine ne fornisce gia' uno leggibile si riusa quello, cosi' un
# varnishadm lanciato a mano senza -S trova comunque la stessa chiave.
if [ ! -s "${SECRET_FILE}" ]; then
    if [ -r /etc/varnish/secret ]; then
        cp /etc/varnish/secret "${SECRET_FILE}"
    else
        dd if=/dev/urandom of="${SECRET_FILE}" bs=1 count=64 2>/dev/null
    fi
    chmod 600 "${SECRET_FILE}" 2>/dev/null || true
fi

vadm() { varnishadm -T "${ADMIN_ADDR}" -S "${SECRET_FILE}" "$@"; }

# -------------------------------------------------------
# Catena di preferenza per Accept-Encoding
# -------------------------------------------------------
# Varnish normalizza l'header al primo formato della lista che il client
# dichiara di accettare. Cambiare l'ordine nel .env cambia quale
# compressione riceve un browser che le supporta tutte.
ENC_FILE="${RUNTIME_DIR}/encoding.vcl"
: > "${ENC_FILE}"
OLD_IFS=$IFS
IFS=','
for enc in ${COMPRESSION_PRIORITY}; do
    enc=$(echo "${enc}" | tr -d ' \t')
    case "${enc}" in
        br|zstd|gzip|deflate) ;;
        "") continue ;;
        *)  warn "codifica '${enc}' sconosciuta in COMPRESSION_PRIORITY, ignorata."
            continue ;;
    esac
    cat >> "${ENC_FILE}" <<EOF
        elsif (req.http.Accept-Encoding ~ "${enc}") {
            set req.http.Accept-Encoding = "${enc}";
        }
EOF
done
IFS=$OLD_IFS

if [ ! -s "${ENC_FILE}" ]; then
    warn "COMPRESSION_PRIORITY non contiene codifiche valide, si usa gzip."
    cat > "${ENC_FILE}" <<'EOF'
        elsif (req.http.Accept-Encoding ~ "gzip") {
            set req.http.Accept-Encoding = "gzip";
        }
EOF
fi

# -------------------------------------------------------
# Segreto per l'invalidazione
# -------------------------------------------------------
# Il valore finisce GREZZO dentro a una stringa VCL: un apice doppio
# chiuderebbe la stringa e il VCL non compilerebbe, cioe' Varnish non
# parte e il sito e' giu'. Si accetta quindi solo l'alfabeto sicuro, lo
# stesso di FIREWALL_BYPASS_COOKIE.
#
# Un valore non valido non blocca l'avvio e non chiude l'invalidazione:
# si torna al controllo con la sola ACL, dicendolo. Fallire chiusi qui
# vorrebbe dire una cache che non si svuota piu', in silenzio - e questo
# stack ha gia' pagato una volta quel genere di guasto.
TOKEN_FILE="${RUNTIME_DIR}/token.vcl"
: > "${TOKEN_FILE}"

case "${PURGE_TOKEN}" in
    "") ;;
    *[!A-Za-z0-9_-]*)
        warn "PURGE_TOKEN contiene caratteri non ammessi (solo lettere, numeri, '-' e '_'): ignorato."
        warn "         PURGE e BAN restano protetti dalla sola ACL."
        PURGE_TOKEN=""
        ;;
    *)
        cat > "${TOKEN_FILE}" <<EOF
        if (req.http.X-Purge-Token != "${PURGE_TOKEN}") {
            return (synth(403, "Token di invalidazione mancante o errato"));
        }
EOF
        ;;
esac

# -------------------------------------------------------
# Risoluzione del backend
# -------------------------------------------------------
resolve_backend() {
    getent ahostsv4 "${BACKEND_HOST}" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# -------------------------------------------------------
# Generazione del VCL
# -------------------------------------------------------
# $1 = file di destinazione, $2 = elenco di indirizzi separati da spazio
render_vcl() {
    _out="$1"
    _ips="$2"
    _backends="${RUNTIME_DIR}/.backends.vcl"
    _members="${RUNTIME_DIR}/.members.vcl"
    _acl="${RUNTIME_DIR}/.acl.vcl"
    : > "${_backends}"
    : > "${_members}"
    : > "${_acl}"

    _n=0
    for _ip in ${_ips}; do
        _n=$(( _n + 1 ))
        # Gli stessi indirizzi sono anche i soli autorizzati a invalidare:
        # sono i container WordPress di questo progetto, non "chiunque
        # stia su una rete privata".
        echo "    \"${_ip}\";" >> "${_acl}"
        cat >> "${_backends}" <<EOF
backend wp_${_n} {
    .host                   = "${_ip}";
    .port                   = "${BACKEND_PORT}";
    .connect_timeout        = 5s;
    .first_byte_timeout     = ${VARNISH_BACKEND_TIMEOUT}s;
    .between_bytes_timeout  = 60s;
    .max_connections        = 500;
    .probe                  = wp_healthz;
}

EOF
        echo "    wp_cluster.add_backend(wp_${_n});" >> "${_members}"
    done

    sed -e "s|@DEFAULT_TTL@|${VARNISH_TTL}|g" \
        -e "s|@STATIC_TTL@|${VARNISH_STATIC_TTL}|g" \
        -e "s|@GRACE@|${VARNISH_GRACE}|g" \
        "${TEMPLATE}" > "${_out}"

    sed -i -e "/@ENCODING_BLOCK@/r ${ENC_FILE}"   -e "/@ENCODING_BLOCK@/d"   "${_out}"
    sed -i -e "/@BACKENDS@/r ${_backends}"        -e "/@BACKENDS@/d"         "${_out}"
    sed -i -e "/@DIRECTOR_MEMBERS@/r ${_members}" -e "/@DIRECTOR_MEMBERS@/d" "${_out}"
    sed -i -e "/@PURGER_ACL@/r ${_acl}"           -e "/@PURGER_ACL@/d"       "${_out}"
    # Il blocco del token puo' essere vuoto: "r" su un file vuoto non
    # inserisce niente, e la riga del segnaposto sparisce comunque.
    sed -i -e "/@PURGE_TOKEN_CHECK@/r ${TOKEN_FILE}" -e "/@PURGE_TOKEN_CHECK@/d" "${_out}"
    rm -f "${_backends}" "${_members}" "${_acl}"

    if grep -q '@[A-Z_]\{3,\}@' "${_out}"; then
        warn "segnaposto non sostituiti nel VCL:"
        grep -n '@[A-Z_]\{3,\}@' "${_out}" >&2
        return 1
    fi
    return 0
}

# -------------------------------------------------------
# Primo avvio
# -------------------------------------------------------
if [ ! -r "${TEMPLATE}" ]; then
    echo "ERRORE: ${TEMPLATE} non leggibile. Verifica il mount in docker-compose.yml." >&2
    exit 1
fi

# Attesa del DNS: normalmente il depends_on la rende istantanea, serve
# nei riavvii in cui l'ordine non e' garantito.
tries=60
CURRENT_IPS=""
while [ "${tries}" -gt 0 ]; do
    CURRENT_IPS=$(resolve_backend)
    [ -n "${CURRENT_IPS}" ] && break
    tries=$(( tries - 1 ))
    [ "${tries}" -eq 55 ] && log "in attesa che '${BACKEND_HOST}' sia risolvibile..."
    sleep 2
done

if [ -z "${CURRENT_IPS}" ]; then
    echo "ERRORE: '${BACKEND_HOST}' non risolvibile dopo 120s. Varnish non puo' compilare il VCL." >&2
    exit 1
fi

annuncia_backend() {
    _c=$(echo "$1" | wc -w)
    if [ "${_c}" -eq 1 ]; then
        log "backend ${BACKEND_HOST} -> $1"
    else
        log "'${BACKEND_HOST}' risolve a ${_c} indirizzi, generati ${_c} backend dietro a un director."
        log "         $1"
        log "         Se non ti aspetti ${_c} container, controlla che non ne siano"
        log "         rimasti attaccati alla rete da un deploy precedente."
    fi
}
annuncia_backend "${CURRENT_IPS}"

render_vcl "${TARGET}" "${CURRENT_IPS}" || exit 1

# Compilazione di prova: un VCL rotto deve fermare il deploy con l'errore
# del compilatore, non lasciare Varnish in crash loop senza spiegazioni.
#
# L'output va catturato, non rediretto a /dev/null: "varnishd -C" stampa
# il sorgente C generato (circa 110 KB) su STDERR, non su stdout. Un
# ">/dev/null" non lo intercetta e ad ogni avvio il log del container si
# riempie di codice C.
if ! vcc_output=$(varnishd -C -f "${TARGET}" 2>&1); then
    echo "ERRORE: il VCL non compila." >&2
    echo "${vcc_output}" >&2
    exit 1
fi

log "cache ${VARNISH_SIZE} | ttl ${VARNISH_TTL} | statici ${VARNISH_STATIC_TTL} | grace ${VARNISH_GRACE}"
log "priorita' compressione ${COMPRESSION_PRIORITY}"
if [ -n "${PURGE_TOKEN}" ]; then
    log "invalidazione: ACL sui backend + segreto condiviso."
else
    log "invalidazione: ACL sui soli backend di questo progetto (PURGE_TOKEN non impostato)."
fi

# -------------------------------------------------------
# Avvio di varnishd
# -------------------------------------------------------
# http_gzip_support=off e' la scelta chiave di tutto lo stack.
# Acceso (default), Varnish riscrive Accept-Encoding a "gzip" verso il
# backend: nginx non vedrebbe mai br o zstd e li produrrebbe per nessuno.
# Spegnendolo, Varnish smette di interpretare le codifiche e si limita a
# conservare per ogni variante l'oggetto che nginx ha prodotto.
#
# varnishd NON viene lanciato con exec: lo script deve restare vivo per
# sorvegliare gli indirizzi del backend. I segnali vengono inoltrati.
varnishd \
    -F \
    -f "${TARGET}" \
    -a "http=:80,HTTP" \
    -T "${ADMIN_ADDR}" \
    -S "${SECRET_FILE}" \
    -s "malloc,${VARNISH_SIZE}" \
    -p http_gzip_support=off \
    -p thread_pools="${VARNISH_THREAD_POOLS}" \
    -p thread_pool_min="${VARNISH_THREAD_MIN}" \
    -p thread_pool_max="${VARNISH_THREAD_MAX}" \
    -p workspace_client=256k \
    -p workspace_backend=256k \
    -p http_resp_hdr_len=32k \
    -p http_resp_size=128k \
    "$@" &

VARNISHD_PID=$!

arresta() {
    kill -TERM "${VARNISHD_PID}" 2>/dev/null || true
    wait "${VARNISHD_PID}" 2>/dev/null || true
    exit 0
}
trap arresta TERM INT

# -------------------------------------------------------
# Sorveglianza degli indirizzi del backend
# -------------------------------------------------------
if [ "${BACKEND_RECHECK_INTERVAL}" -le 0 ]; then
    log "sorveglianza del backend disattivata (BACKEND_RECHECK_INTERVAL=0)."
    wait "${VARNISHD_PID}"
    exit $?
fi

log "sorveglianza di '${BACKEND_HOST}' ogni ${BACKEND_RECHECK_INTERVAL}s."

# Varnish chiama "boot" il VCL iniziale: scartarlo al primo reload evita
# di tenerne in memoria uno che non servira' mai piu'.
VCL_PRECEDENTE="boot"
attesa=0
backend_giu=0

# Un 503 con Varnish vivo e' il guasto peggiore da diagnosticare: il
# container risulta sano, l'healthcheck passa, e nei log non c'e' niente
# che spieghi perche' il sito e' giu'. Succede quando nessun backend
# supera la probe - per esempio se il nome risolve a container di un
# altro progetto, che rispondono ma non hanno /healthz. Meglio dirlo.
controlla_salute() {
    _lista=$(vadm backend.list 2>/dev/null) || return 0
    _sani=$(echo "${_lista}" | grep -c 'wp_[0-9][0-9]*  *probe.*healthy' || true)
    if [ "${_sani}" -eq 0 ]; then
        if [ "${backend_giu}" -eq 0 ]; then
            warn "NESSUN backend sano: il sito sta rispondendo 503."
            warn "         Indirizzi in uso per '${BACKEND_HOST}': ${CURRENT_IPS}"
            warn "         Se non sono i container di questo progetto, il nome sta"
            warn "         risolvendo a container omonimi di un altro stack sulla"
            warn "         stessa dokploy-network."
            echo "${_lista}" >&2
            backend_giu=1
        fi
    elif [ "${backend_giu}" -eq 1 ]; then
        log "backend di nuovo raggiungibili (${_sani} sani)."
        backend_giu=0
    fi
}

# Il sonno e' spezzato in tranche da 5s per non ritardare la risposta a
# SIGTERM: "docker stop" aspetta 10s prima di uccidere il container, e un
# "sleep 60" lo farebbe scadere ad ogni arresto.
while kill -0 "${VARNISHD_PID}" 2>/dev/null; do
    sleep 5
    attesa=$(( attesa + 5 ))
    [ "${attesa}" -lt "${BACKEND_RECHECK_INTERVAL}" ] && continue
    attesa=0

    controlla_salute

    NUOVI_IPS=$(resolve_backend)

    # Risoluzione vuota: quasi sempre il backend si sta riavviando. Si
    # tiene il VCL corrente, perche' un VCL senza backend non si puo'
    # nemmeno compilare e perderemmo anche la cache.
    [ -z "${NUOVI_IPS}" ] && continue
    [ "${NUOVI_IPS}" = "${CURRENT_IPS}" ] && continue

    log "gli indirizzi di '${BACKEND_HOST}' sono cambiati."
    log "         prima: ${CURRENT_IPS}"
    log "         ora:   ${NUOVI_IPS}"

    NUOVO_VCL="${RUNTIME_DIR}/default.vcl.new"
    if ! render_vcl "${NUOVO_VCL}" "${NUOVI_IPS}"; then
        warn "rigenerazione del VCL fallita, resto sulla configurazione precedente."
        continue
    fi

    ETICHETTA="reload_$(date +%s)"
    if vadm vcl.load "${ETICHETTA}" "${NUOVO_VCL}" > /dev/null 2>&1 \
       && vadm vcl.use "${ETICHETTA}" > /dev/null 2>&1; then
        mv "${NUOVO_VCL}" "${TARGET}"
        CURRENT_IPS="${NUOVI_IPS}"
        log "VCL ricaricato a caldo, cache conservata."
        # Il VCL precedente si scarta solo dopo che il nuovo e' in uso, e
        # solo se non e' ancora in raffreddamento: un fallimento qui non
        # e' un problema, Varnish lo liberera' da solo.
        [ -n "${VCL_PRECEDENTE}" ] && vadm vcl.discard "${VCL_PRECEDENTE}" > /dev/null 2>&1 || true
        VCL_PRECEDENTE="${ETICHETTA}"
    else
        warn "ricarica del VCL fallita, resto sulla configurazione precedente."
        rm -f "${NUOVO_VCL}"
    fi
done

wait "${VARNISHD_PID}"
exit $?
