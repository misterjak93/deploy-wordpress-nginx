#!/bin/sh
# =======================================================
# Varnish - avvio
# =======================================================
# L'immagine ufficiale di Varnish non ha envsubst (niente gettext-base),
# quindi i segnaposto del VCL li sostituisce sed: e' presente ovunque e
# non aggiunge un pacchetto solo per questo.
set -eu

TEMPLATE=/etc/varnish/default.vcl.template
TARGET=/etc/varnish/default.vcl

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
# Generazione del VCL
# -------------------------------------------------------
sed -e "s|@BACKEND_TIMEOUT@|${VARNISH_BACKEND_TIMEOUT}|g" \
    -e "s|@DEFAULT_TTL@|${VARNISH_TTL}|g" \
    -e "s|@STATIC_TTL@|${VARNISH_STATIC_TTL}|g" \
    -e "s|@GRACE@|${VARNISH_GRACE}|g" \
    "${TEMPLATE}" > "${TARGET}"

sed -i -e "/@ENCODING_BLOCK@/r ${ENC_FILE}" -e "/@ENCODING_BLOCK@/d" "${TARGET}"
rm -f "${ENC_FILE}"

if grep -q '@[A-Z_]\{3,\}@' "${TARGET}"; then
    echo "ERRORE: segnaposto non sostituiti nel VCL:" >&2
    grep -n '@[A-Z_]\{3,\}@' "${TARGET}" >&2
    exit 1
fi

# Varnish risolve il nome del backend quando COMPILA il VCL, non ad ogni
# richiesta. Se "wordpress" non e' ancora nel DNS di Docker la
# compilazione fallisce e il container muore, quindi si aspetta.
# Normalmente il depends_on rende l'attesa istantanea; serve nei riavvii
# in cui l'ordine non e' garantito.
BACKEND_HOST="${BACKEND_HOST:-wordpress}"
tries=60
while [ "${tries}" -gt 0 ]; do
    getent hosts "${BACKEND_HOST}" > /dev/null 2>&1 && break
    tries=$(( tries - 1 ))
    [ "${tries}" -eq 55 ] && echo "In attesa che '${BACKEND_HOST}' sia risolvibile..."
    sleep 2
done
if [ "${tries}" -eq 0 ]; then
    echo "ERRORE: '${BACKEND_HOST}' non risolvibile dopo 120s. Varnish non puo' compilare il VCL." >&2
    exit 1
fi

# Compilazione di prova: un VCL rotto deve fermare il deploy con l'errore
# del compilatore, non lasciare Varnish in crash loop senza spiegazioni.
varnishd -C -f "${TARGET}" > /dev/null

echo "Varnish: cache ${VARNISH_SIZE} | ttl ${VARNISH_TTL} | statici ${VARNISH_STATIC_TTL} | grace ${VARNISH_GRACE}"
echo "Varnish: priorita' compressione ${COMPRESSION_PRIORITY}"

# Interfaccia di amministrazione su loopback. Serve all'healthcheck
# ("varnishadm ping") e ai comandi manuali di invalidazione; non e'
# raggiungibile da fuori dal container.
SECRET_FILE=/etc/varnish/secret
if [ ! -s "${SECRET_FILE}" ]; then
    dd if=/dev/urandom of="${SECRET_FILE}" bs=1 count=64 2>/dev/null
    chmod 600 "${SECRET_FILE}"
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
