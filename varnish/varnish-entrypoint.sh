#!/bin/sh
# =======================================================
# Varnish - avvio
# =======================================================
# L'immagine ufficiale di Varnish non ha envsubst (niente gettext-base),
# quindi i segnaposto del VCL li sostituisce sed: e' presente ovunque e
# non aggiunge un pacchetto solo per questo.
set -eu

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
#      corrente - per questo piu' sotto ci si sposta qui dentro.
RUNTIME_DIR="${VARNISH_RUNTIME_DIR:-/tmp/varnish}"
mkdir -p "${RUNTIME_DIR}" || {
    echo "ERRORE: impossibile creare ${RUNTIME_DIR}." >&2
    exit 1
}
cd "${RUNTIME_DIR}"

TEMPLATE=/etc/varnish/default.vcl.template
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

# -------------------------------------------------------
# Catena di preferenza per Accept-Encoding
# -------------------------------------------------------
# Varnish normalizza l'header al primo formato della lista che il client
# dichiara di accettare. Cambiare l'ordine nel .env cambia quale
# compressione riceve un browser che le supporta tutte.
ENC_FILE=$(mktemp)
OLD_IFS=$IFS
IFS=','
for enc in ${COMPRESSION_PRIORITY}; do
    enc=$(echo "${enc}" | tr -d ' \t')
    case "${enc}" in
        br|zstd|gzip|deflate) ;;
        "") continue ;;
        *)  echo "AVVISO: codifica '${enc}' sconosciuta in COMPRESSION_PRIORITY, ignorata." >&2
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
    echo "AVVISO: COMPRESSION_PRIORITY non contiene codifiche valide, si usa gzip." >&2
    cat > "${ENC_FILE}" <<'EOF'
        elsif (req.http.Accept-Encoding ~ "gzip") {
            set req.http.Accept-Encoding = "gzip";
        }
EOF
fi

# -------------------------------------------------------
# Backend: un blocco per ogni indirizzo del nome
# -------------------------------------------------------
# Varnish risolve il nome del backend quando COMPILA il VCL, non ad ogni
# richiesta, e accetta un solo IPv4 per backend. Qui si enumerano tutti
# gli indirizzi a cui risponde il nome e si genera un backend per
# ciascuno, poi messi dietro a un director (vedi default.vcl.template).
BACKEND_HOST="${BACKEND_HOST:-wordpress}"
BACKEND_PORT="${BACKEND_PORT:-80}"

# Attesa del DNS: normalmente il depends_on la rende istantanea, serve
# nei riavvii in cui l'ordine non e' garantito.
tries=60
BACKEND_IPS=""
while [ "${tries}" -gt 0 ]; do
    BACKEND_IPS=$(getent ahostsv4 "${BACKEND_HOST}" 2>/dev/null | awk '{print $1}' | sort -u)
    [ -n "${BACKEND_IPS}" ] && break
    tries=$(( tries - 1 ))
    [ "${tries}" -eq 55 ] && echo "In attesa che '${BACKEND_HOST}' sia risolvibile..."
    sleep 2
done

if [ -z "${BACKEND_IPS}" ]; then
    echo "ERRORE: '${BACKEND_HOST}' non risolvibile dopo 120s. Varnish non puo' compilare il VCL." >&2
    exit 1
fi

BACKENDS_FILE=$(mktemp)
MEMBERS_FILE=$(mktemp)
n=0
for ip in ${BACKEND_IPS}; do
    n=$(( n + 1 ))
    cat >> "${BACKENDS_FILE}" <<EOF
backend wp_${n} {
    .host                   = "${ip}";
    .port                   = "${BACKEND_PORT}";
    .connect_timeout        = 5s;
    .first_byte_timeout     = ${VARNISH_BACKEND_TIMEOUT}s;
    .between_bytes_timeout  = 60s;
    .max_connections        = 500;
    .probe                  = wp_healthz;
}

EOF
    echo "    wp_cluster.add_backend(wp_${n});" >> "${MEMBERS_FILE}"
done

if [ "${n}" -eq 1 ]; then
    echo "Varnish: backend ${BACKEND_HOST} -> ${BACKEND_IPS}"
else
    echo "Varnish: '${BACKEND_HOST}' risolve a ${n} indirizzi, generati ${n} backend dietro a un director."
    echo "         $(echo ${BACKEND_IPS} | tr '\n' ' ')"
    echo "         Se non ti aspetti ${n} container, controlla che non ne siano"
    echo "         rimasti attaccati alla rete da un deploy precedente."
fi

# -------------------------------------------------------
# Generazione del VCL
# -------------------------------------------------------
if [ ! -r "${TEMPLATE}" ]; then
    echo "ERRORE: ${TEMPLATE} non leggibile. Verifica il mount in docker-compose.yml." >&2
    exit 1
fi

sed -e "s|@DEFAULT_TTL@|${VARNISH_TTL}|g" \
    -e "s|@STATIC_TTL@|${VARNISH_STATIC_TTL}|g" \
    -e "s|@GRACE@|${VARNISH_GRACE}|g" \
    "${TEMPLATE}" > "${TARGET}"

sed -i -e "/@ENCODING_BLOCK@/r ${ENC_FILE}" -e "/@ENCODING_BLOCK@/d" "${TARGET}"
sed -i -e "/@BACKENDS@/r ${BACKENDS_FILE}" -e "/@BACKENDS@/d" "${TARGET}"
sed -i -e "/@DIRECTOR_MEMBERS@/r ${MEMBERS_FILE}" -e "/@DIRECTOR_MEMBERS@/d" "${TARGET}"
rm -f "${ENC_FILE}" "${BACKENDS_FILE}" "${MEMBERS_FILE}"

if grep -q '@[A-Z_]\{3,\}@' "${TARGET}"; then
    echo "ERRORE: segnaposto non sostituiti nel VCL:" >&2
    grep -n '@[A-Z_]\{3,\}@' "${TARGET}" >&2
    exit 1
fi

# Compilazione di prova: un VCL rotto deve fermare il deploy con l'errore
# del compilatore, non lasciare Varnish in crash loop senza spiegazioni.
#
# L'output va catturato, non rediretto a /dev/null: "varnishd -C" stampa
# il sorgente C generato (circa 110 KB) su STDERR, non su stdout. Un
# ">/dev/null" non lo intercetta e ad ogni avvio il log del container si
# riempie di codice C. Cosi' invece in caso di successo non si stampa
# nulla, e in caso di errore si stampa tutto.
if ! vcc_output=$(varnishd -C -f "${TARGET}" 2>&1); then
    echo "ERRORE: il VCL non compila." >&2
    echo "${vcc_output}" >&2
    exit 1
fi

echo "Varnish: cache ${VARNISH_SIZE} | ttl ${VARNISH_TTL} | statici ${VARNISH_STATIC_TTL} | grace ${VARNISH_GRACE}"
echo "Varnish: priorita' compressione ${COMPRESSION_PRIORITY}"

# Interfaccia di amministrazione su loopback. Serve all'healthcheck
# ("varnishadm ping") e ai comandi manuali di invalidazione; non e'
# raggiungibile da fuori dal container.
# Anche il secret sta in RUNTIME_DIR: /etc/varnish e' sola lettura.
# Se l'immagine ne fornisce gia' uno leggibile si riusa quello, cosi' un
# varnishadm lanciato a mano senza -S trova comunque la stessa chiave.
SECRET_FILE="${RUNTIME_DIR}/secret"
if [ ! -s "${SECRET_FILE}" ]; then
    if [ -r /etc/varnish/secret ]; then
        cp /etc/varnish/secret "${SECRET_FILE}"
    else
        dd if=/dev/urandom of="${SECRET_FILE}" bs=1 count=64 2>/dev/null
    fi
    chmod 600 "${SECRET_FILE}" 2>/dev/null || true
fi

# -------------------------------------------------------
# Avvio
# -------------------------------------------------------
# http_gzip_support=off e' la scelta chiave di tutto lo stack.
# Acceso (default), Varnish riscrive Accept-Encoding a "gzip" su ogni
# richiesta al backend: nginx non vedrebbe mai br o zstd e li produrrebbe
# per nessuno. Spegnendolo, Varnish smette di interpretare le codifiche e
# si limita a conservare per ogni variante di Accept-Encoding l'oggetto
# che nginx ha prodotto - che e' esattamente quello che serve qui.
exec varnishd \
    -F \
    -f "${TARGET}" \
    -a "http=:80,HTTP" \
    -T 127.0.0.1:6082 \
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
    "$@"
