#!/bin/bash
# =======================================================
# WordPress su nginx - avvio del container
# =======================================================
set -euo pipefail

log()  { printf '\033[1;36m[wp]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[wp]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[wp]\033[0m %s\n' "$*" >&2; exit 1; }

# =======================================================
# 0. Versione di PHP
# =======================================================
# PHP_VERSION e' solo runtime: l'immagine contiene 8.3, 8.4 e 8.5 e
# cambiarla e' un riavvio del container, non un rebuild.
# Si accettano sia "8.3" sia "83".
PHP_VERSION="${PHP_VERSION:-8.3}"

# Si accettano sia "8.4" sia "84": togliendo i punti e rimettendone uno
# dopo la prima cifra si normalizzano entrambe, e continuera' a funzionare
# per una 8.6 o una 9.0 senza toccare niente qui.
_v="${PHP_VERSION//./}"
case "${_v}" in
    [0-9][0-9]|[0-9][0-9][0-9]) PHP_VER="${_v:0:1}.${_v:1}" ;;
    *) die "PHP_VERSION='${PHP_VERSION}' non e' una versione valida. Esempi: 8.3, 8.4, 8.5 (anche 83, 84, 85)." ;;
esac

# Versioni realmente presenti nell'immagine, lette dai binari installati
# invece che da una lista scritta a mano: cosi' l'elenco nell'errore non
# puo' mentire.
AVAILABLE=$(ls /usr/sbin/php-fpm* 2>/dev/null | sed 's#.*/php-fpm##' | sort -V | tr '\n' ' ')

if [ ! -x "/usr/sbin/php-fpm${PHP_VER}" ]; then
    die "PHP ${PHP_VER} non e' in questa immagine.
   Versioni disponibili: ${AVAILABLE:-nessuna}
   O imposti PHP_VERSION su una di queste (basta riavviare il container),
   oppure ricostruisci l'immagine con PHP_VERSIONS che includa ${PHP_VER}."
fi

export PHP_VER

# php e php-fpm generici puntano alla versione scelta: WP-CLI, gli script
# di manutenzione e qualunque "php -v" dentro al container vedono la
# stessa versione che serve le pagine.
update-alternatives --set php "/usr/bin/php${PHP_VER}" >/dev/null 2>&1 || \
    ln -sf "/usr/bin/php${PHP_VER}" /usr/bin/php

# =======================================================
# 1. Valori di default
# =======================================================
: "${DOMAIN:=localhost}"
: "${ADMIN_EMAIL:=admin@${DOMAIN}}"
: "${TZ:=Europe/Rome}"
: "${WP_BASE:=/var/www/wordpress}"
: "${WP_ROOT:=${WP_BASE}/html}"

# --- PHP ---
: "${PHP_MEM_LIMIT:=512M}"
: "${PHP_CLI_MEM_LIMIT:=1024M}"
: "${PHP_CONCURRENCY:=20}"
: "${PHP_UPLOAD_LIMIT:=128M}"
: "${PHP_MAX_EXECUTION_TIME:=300}"
: "${PHP_FPM_MAX_REQUESTS:=500}"
: "${PHP_SLOWLOG_TIMEOUT:=10s}"
: "${PHP_TERMINATE_TIMEOUT:=360s}"

# Con pm=dynamic i tre valori vanno in rapporto fra loro, non scelti a
# caso: start_servers deve stare fra min_spare e max_spare, altrimenti
# PHP-FPM rifiuta la configurazione e non parte. Si ricavano da
# PHP_CONCURRENCY cosi' che nel .env resti un solo numero da toccare.
: "${PHP_FPM_MIN_SPARE:=$(( PHP_CONCURRENCY / 4 > 0 ? PHP_CONCURRENCY / 4 : 1 ))}"
: "${PHP_FPM_MAX_SPARE:=$(( PHP_CONCURRENCY / 2 > 1 ? PHP_CONCURRENCY / 2 : 2 ))}"
: "${PHP_FPM_START_SERVERS:=$(( (PHP_FPM_MIN_SPARE + PHP_FPM_MAX_SPARE) / 2 ))}"

# Funzioni bloccate nelle richieste web. La CLI non e' toccata: WP-CLI ha
# bisogno di proc_open e popen per meta' dei suoi comandi.
: "${PHP_DISABLE_FUNCTIONS:=exec,passthru,shell_exec,system,proc_open,proc_close,proc_nice,popen,pcntl_exec,pcntl_fork,dl,symlink,link,posix_kill,posix_setuid,posix_setpgid,posix_setsid,show_source,highlight_file}"

# --- OPcache ---
: "${OPCACHE_MEMORY:=192}"
: "${OPCACHE_STRINGS_BUFFER:=16}"
: "${OPCACHE_MAX_FILES:=20000}"
: "${OPCACHE_JIT:=disable}"
: "${OPCACHE_JIT_BUFFER:=0}"
: "${SESSION_COOKIE_SECURE:=1}"

# --- nginx ---
: "${NGINX_WORKER_CONNECTIONS:=4096}"
: "${LIMIT_CONN_PER_IP:=40}"
: "${RATE_LIMIT_LOGIN:=20}"
: "${RATE_LIMIT_LOGIN_BURST:=10}"
: "${RATE_LIMIT_XMLRPC:=10}"
: "${RATE_LIMIT_XMLRPC_BURST:=5}"
: "${RATE_LIMIT_API:=20}"
: "${RATE_LIMIT_API_BURST:=40}"
: "${XMLRPC_ENABLED:=0}"
: "${STATIC_BROWSER_TTL:=31536000}"
: "${FIREWALL_ENABLED:=1}"
: "${FIREWALL_BYPASS_COOKIE:=wpfw-bypass-CAMBIAMI}"

# Cartella dove un plugin di conversione (CompressX, WebP Express) scrive
# le varianti AVIF/WebP su disco. VUOTA per default: da quando c'e'
# PageSpeed, AVIF e WebP li produce il modulo al volo guardando Accept, e
# tenere in piedi anche la negoziazione su disco vorrebbe dire due strade
# che fanno la stessa cosa - con il try_files che prova prima file che non
# esistono. Si valorizza solo se PageSpeed e' spento o non licenziato.
: "${CONVERTED_DIR:=}"

# --- CORS degli asset serviti da nginx ---
# Riguarda i font e gli asset statici, che un browser rifiuta di usare da
# un altro dominio senza Access-Control-Allow-Origin. Vive qui e non nella
# bacheca perche' un file servito con sendfile non sveglia PHP: il
# mu-plugin non ha modo di metterci mano, e governa invece tutto cio' che
# genera WordPress (pagine, REST API, admin-ajax, feed).
#
#   *              (default) chiunque puo' caricarli. E' il comportamento
#                  storico di questo stack, ed e' innocuo: sono file
#                  pubblici, senza cookie e senza credenziali.
#   off            nessun header: gli asset si usano solo dal proprio sito.
#   elenco         una o piu' origini separate da spazio o virgola. nginx
#                  rimanda indietro l'origine solo se e' nell'elenco, e
#                  aggiunge "Vary: Origin".
#
# "off" e' una parola e non il valore vuoto perche' il valore vuoto non
# sopravvive al viaggio: Compose interpola "${CORS_STATIC_ORIGINS:-*}" e
# un .env con la riga vuota arriva qui identico a un .env senza la riga.
# Verificato facendolo: con la variabile vuota l'entrypoint riapplicava il
# default e il CORS restava aperto, cioe' l'impostazione non si poteva
# spegnere affatto.
: "${CORS_STATIC_ORIGINS:=*}"

# --- PageSpeed (ngx_pagespeed) ---
# Il modulo c'e' solo se l'immagine e' stata costruita con
# PAGESPEED_ENABLED=1. Qui si decide se accenderlo davvero: le direttive
# vengono emesse solo dopo aver verificato che il .so esista, esattamente
# come per Brotli e Zstandard.
: "${PAGESPEED_ENABLED:=1}"

# Livello di riscrittura. Vedi il commento nel template: qui davanti c'e'
# una cache condivisa, quindi il default tocca i byte e non la struttura
# dell'HTML.
: "${PAGESPEED_REWRITE_LEVEL:=OptimizeForBandwidth}"

# Filtri accesi in aggiunta al livello. I quattro di default sono la
# conversione di formato: sono l'unica ragione per cui questo stack non ha
# piu' bisogno di un plugin che generi AVIF e WebP su disco.
: "${PAGESPEED_FILTERS:=convert_jpeg_to_webp,convert_to_webp_lossless,convert_jpeg_to_avif,convert_to_avif_lossless}"
: "${PAGESPEED_DISABLE_FILTERS:=}"

: "${PAGESPEED_CACHE_DIR:=/var/cache/nginx/pagespeed}"
: "${PAGESPEED_CACHE_SIZE_KB:=1048576}"
: "${PAGESPEED_IMAGE_QUALITY:=85}"
: "${PAGESPEED_WEBP_QUALITY:=80}"
: "${PAGESPEED_AVIF_QUALITY:=60}"
: "${PAGESPEED_INPLACE:=on}"
: "${PAGESPEED_ADMIN_PATH:=/pagespeed_admin}"
: "${PAGESPEED_STATS_PATH:=/pagespeed_statistics}"

# Invalidazione di Varnish quando PageSpeed finisce di ottimizzare una
# pagina. Senza, la prima versione servita - quella ancora da ottimizzare -
# resterebbe in cache fino alla scadenza del TTL.
: "${PAGESPEED_DOWNSTREAM_PURGE:=1}"
: "${PAGESPEED_DOWNSTREAM_THRESHOLD:=95}"

# Percorsi che PageSpeed non deve toccare, oltre a quelli gia' esclusi
# per default (amministrazione, REST API, feed, discovery).
: "${PAGESPEED_DISALLOW:=}"

# Direttive aggiuntive, una per riga, SENZA il prefisso "pagespeed" e
# senza punto e virgola. E' anche il posto dove va la riga di attivazione
# della licenza, che We-Amp documenta insieme al token: questo repository
# non ne inventa il nome.
: "${PAGESPEED_EXTRA_DIRECTIVES:=}"

# --- Compressione ---
: "${GZIP_LEVEL:=6}"
: "${BROTLI_LEVEL:=5}"
: "${ZSTD_LEVEL:=6}"
: "${COMPRESSION_MIN_LENGTH:=256}"
: "${COMPRESSION_PRIORITY:=br,zstd,gzip}"

# --- Cache di pagina su disco (secondo livello, dopo Varnish) ---
: "${FASTCGI_CACHE_ENABLED:=1}"
: "${FASTCGI_CACHE_DIR:=/var/cache/nginx/wordpress}"
: "${FASTCGI_CACHE_ZONE_SIZE:=64m}"
: "${FASTCGI_CACHE_MAX_SIZE:=2g}"
: "${FASTCGI_CACHE_INACTIVE:=60d}"
: "${FASTCGI_CACHE_TTL:=30d}"
: "${INSTALL_MU_PLUGINS:=1}"

# --- Database e cache ---
: "${DB_HOST:=mariadb}"
: "${DB_NAME:=wordpress}"
: "${DB_USER:=wordpress}"
: "${DB_PASS:=}"
: "${DB_TABLE_PREFIX:=wp_}"
: "${REDIS_HOST:=redis}"
: "${REDIS_PORT:=6379}"
: "${REDIS_PASSWORD:=}"

# --- Cron ---
: "${WP_CRON_ENABLED:=true}"
: "${WP_CRON_INTERVAL:=60}"
export WP_CRON_ENABLED WP_CRON_INTERVAL WP_ROOT WP_BASE

: "${WORDPRESS_LOCALE:=}"
: "${WP_AUTO_INSTALL:=1}"
: "${FIX_PERMISSIONS:=0}"

# Chi puo' raggiungere /wp-admin/install.php e /wp-admin/setup-config.php.
#   auto  - aperti solo finche' servono davvero (default)
#   deny  - sempre 404
#   open  - sempre raggiungibili
: "${WP_INSTALL_ACCESS:=auto}"

ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime 2>/dev/null || true
echo "${TZ}" > /etc/timezone 2>/dev/null || true

log "PHP ${PHP_VER} | dominio ${DOMAIN} | worker PHP ${PHP_CONCURRENCY} | memoria ${PHP_MEM_LIMIT}"

# Quale versione della configurazione sta girando davvero. Template e
# snippet stanno dentro l'immagine: se questa impronta non cambia dopo un
# deploy, l'immagine non e' stata ricostruita e le modifiche non ci sono.
if [ -r /etc/stack-config-version ]; then
    log "configurazione $(cat /etc/stack-config-version)"
fi

# =======================================================
# 2. Configurazione PHP
# =======================================================
# Blocco attivato solo se igbinary e' presente: la lista delle estensioni
# opzionali del Dockerfile non e' garantita per una PHP appena uscita.
if "/usr/bin/php${PHP_VER}" -m | grep -qix igbinary; then
    IGBINARY_SESSION='session.serialize_handler = igbinary'
else
    IGBINARY_SESSION='; igbinary non installato per questa versione di PHP.'
    warn "igbinary non disponibile per PHP ${PHP_VER}: Redis usera' il serializzatore PHP."
fi
export IGBINARY_SESSION

PHP_VARS='${PHP_MEM_LIMIT} ${PHP_CLI_MEM_LIMIT} ${PHP_MAX_EXECUTION_TIME} ${PHP_UPLOAD_LIMIT}
${PHP_CONCURRENCY} ${PHP_FPM_START_SERVERS} ${PHP_FPM_MIN_SPARE} ${PHP_FPM_MAX_SPARE}
${PHP_FPM_MAX_REQUESTS} ${PHP_SLOWLOG_TIMEOUT} ${PHP_TERMINATE_TIMEOUT} ${PHP_DISABLE_FUNCTIONS}
${OPCACHE_MEMORY} ${OPCACHE_STRINGS_BUFFER} ${OPCACHE_MAX_FILES} ${OPCACHE_JIT} ${OPCACHE_JIT_BUFFER}
${SESSION_COOKIE_SECURE} ${IGBINARY_SESSION} ${TZ} ${WP_BASE}'

export PHP_MEM_LIMIT PHP_CLI_MEM_LIMIT PHP_MAX_EXECUTION_TIME PHP_UPLOAD_LIMIT \
       PHP_CONCURRENCY PHP_FPM_START_SERVERS PHP_FPM_MIN_SPARE PHP_FPM_MAX_SPARE \
       PHP_FPM_MAX_REQUESTS PHP_SLOWLOG_TIMEOUT PHP_TERMINATE_TIMEOUT PHP_DISABLE_FUNCTIONS \
       OPCACHE_MEMORY OPCACHE_STRINGS_BUFFER OPCACHE_MAX_FILES OPCACHE_JIT OPCACHE_JIT_BUFFER \
       SESSION_COOKIE_SECURE TZ

envsubst "${PHP_VARS}" < /opt/php-templates/99-wordpress.ini.template \
    > "/etc/php/${PHP_VER}/fpm/conf.d/99-wordpress.ini"
envsubst "${PHP_VARS}" < /opt/php-templates/99-wordpress.ini.template \
    > "/etc/php/${PHP_VER}/cli/conf.d/99-wordpress.ini"
envsubst "${PHP_VARS}" < /opt/php-templates/99-wordpress-cli.ini.template \
    > "/etc/php/${PHP_VER}/cli/conf.d/99-wordpress-cli.ini"
envsubst "${PHP_VARS}" < /opt/php-templates/pool.conf.template \
    > "/etc/php/${PHP_VER}/fpm/pool.d/wordpress.conf"

# =======================================================
# 3. Configurazione nginx
# =======================================================
# --- Perimetro dei proxy fidati ---
# set_real_ip_from dice a nginx di quali hop fidarsi quando risale
# X-Forwarded-For. Gli hop reali sono due e sono noti - Varnish sulla rete
# del progetto, Traefik su dokploy-network - ma il secondo non e'
# deducibile da qui: questo container non sta su quella rete, di proposito.
# Il default resta quindi lo spazio privato; TRUSTED_PROXIES permette di
# stringerlo a chi conosce le sottoreti della propria macchina.
#
# Il valore finisce dentro alla configurazione di nginx, quindi si accetta
# solo cio' che e' davvero un indirizzo o una rete: un token con uno spazio
# o un punto e virgola sarebbe una direttiva in piu'. In caso di dubbio si
# torna al default, che e' largo ma non sbagliato.
: "${TRUSTED_PROXIES:=10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8}"

TRUSTED_PROXY_LINES=""
for _cidr in $(echo "${TRUSTED_PROXIES}" | tr ',' ' '); do
    # Non basta scartare i caratteri strani: "deadbeef" e' fatto di sole
    # cifre esadecimali e passerebbe, per poi far fallire "nginx -t" e non
    # far partire il container. Si pretende la forma di un indirizzo.
    if [[ ! "${_cidr}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]] \
       && [[ ! "${_cidr}" =~ ^[0-9a-fA-F:]+(/[0-9]{1,3})?$ || ! "${_cidr}" == *:* ]]; then
        warn "TRUSTED_PROXIES contiene '${_cidr}', che non e' un indirizzo o una rete: ignorato."
        continue
    fi
    TRUSTED_PROXY_LINES="${TRUSTED_PROXY_LINES}    set_real_ip_from    ${_cidr};
"
done

if [ -z "${TRUSTED_PROXY_LINES}" ]; then
    warn "TRUSTED_PROXIES non contiene nessun valore valido: uso lo spazio privato."
    TRUSTED_PROXY_LINES='    set_real_ip_from    10.0.0.0/8;
    set_real_ip_from    172.16.0.0/12;
    set_real_ip_from    192.168.0.0/16;
    set_real_ip_from    127.0.0.0/8;
'
fi
# L'ultima riga porta gia' il suo a capo: la si toglie per non lasciare una
# riga vuota in mezzo al blocco.
TRUSTED_PROXY_LINES="${TRUSTED_PROXY_LINES%$'\n'}"
export TRUSTED_PROXY_LINES

if [ "${XMLRPC_ENABLED}" = "1" ]; then
    XMLRPC_DENY='# XMLRPC_ENABLED=1: endpoint attivo, protetto dal solo rate limit.'
else
    XMLRPC_DENY='return 444;'
fi
export XMLRPC_DENY

# --- CORS degli asset statici ---
# Il valore finisce dentro alla configurazione di nginx, quindi si accetta
# solo cio' che e' davvero un'origine: schema, host e al piu' una porta.
# Un token con uno spazio o un punto e virgola sarebbe una direttiva in
# piu'. In caso di dubbio si scarta quella voce e lo si dice nei log.
CORS_ORIGIN_MAP=""
CORS_MODE="off"
case "${CORS_STATIC_ORIGINS}" in
    ""|off|none|no)
        CORS_MODE="off"
        ;;
    "*")
        CORS_MODE="any"
        ;;
    *)
        for _o in $(echo "${CORS_STATIC_ORIGINS}" | tr ',' ' '); do
            if [[ ! "${_o}" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]]; then
                warn "CORS_STATIC_ORIGINS contiene '${_o}', che non e' un'origine (schema://host[:porta]): ignorata."
                continue
            fi
            CORS_ORIGIN_MAP="${CORS_ORIGIN_MAP}    \"${_o}\" \"${_o}\";
"
        done
        if [ -n "${CORS_ORIGIN_MAP}" ]; then
            CORS_MODE="list"
        else
            warn "CORS_STATIC_ORIGINS non contiene nessuna origine valida: nessun header CORS sugli asset."
            CORS_MODE="off"
        fi
        ;;
esac

case "${CORS_MODE}" in
    any)
        CORS_STATIC_LINES='        add_header      Access-Control-Allow-Origin "*" always;'
        ;;
    list)
        # "Vary: Origin" e' obbligatorio con un elenco: senza, Varnish
        # servirebbe a tutti la risposta costruita per la prima origine
        # che ha chiesto quel file. Il prezzo e' una copia in cache per
        # origine, ed e' il motivo per cui "*" resta il default: su file
        # pubblici non c'e' niente da proteggere.
        CORS_STATIC_LINES='        add_header      Access-Control-Allow-Origin $cors_static_origin always;
        add_header      Vary Origin always;'
        ;;
    *)
        CORS_STATIC_LINES='        # CORS_STATIC_ORIGINS vuoto: nessun header CORS su questi file.'
        ;;
esac
export CORS_STATIC_LINES

# --- Negoziazione delle immagini su disco ---
# Con CONVERTED_DIR vuoto il try_files si riduce all'originale: le
# varianti le produce PageSpeed al volo, e nginx non deve cercare su disco
# file che nessuno scrive.
if [ -n "${CONVERTED_DIR}" ]; then
    IMG_TRY_FILES="/wp-content/${CONVERTED_DIR}/\$img_path.\$img_ext\$img_avif
                        /wp-content/${CONVERTED_DIR}/\$img_path.\$img_ext\$img_webp
                        \$uri
                        =404"
    IMG_VARY_LINE='    add_header      Vary Accept;'
else
    IMG_TRY_FILES="\$uri =404"
    IMG_VARY_LINE='    # Vary: Accept lo emette PageSpeed quando converte. Vedi CONVERTED_DIR.'
fi
export IMG_TRY_FILES IMG_VARY_LINE

NGINX_VARS='${DOMAIN} ${WP_ROOT} ${WP_BASE} ${PHP_UPLOAD_LIMIT} ${PHP_MAX_EXECUTION_TIME}
${NGINX_WORKER_CONNECTIONS} ${LIMIT_CONN_PER_IP} ${RATE_LIMIT_LOGIN} ${RATE_LIMIT_LOGIN_BURST}
${RATE_LIMIT_XMLRPC} ${RATE_LIMIT_XMLRPC_BURST} ${RATE_LIMIT_API} ${RATE_LIMIT_API_BURST}
${XMLRPC_DENY} ${CONVERTED_DIR} ${STATIC_BROWSER_TTL} ${FIREWALL_BYPASS_COOKIE}
${TRUSTED_PROXY_LINES} ${CORS_STATIC_LINES} ${IMG_TRY_FILES} ${IMG_VARY_LINE}
${GZIP_LEVEL} ${BROTLI_LEVEL} ${ZSTD_LEVEL} ${COMPRESSION_MIN_LENGTH}
${FASTCGI_CACHE_DIR} ${FASTCGI_CACHE_ZONE_SIZE} ${FASTCGI_CACHE_MAX_SIZE}
${FASTCGI_CACHE_INACTIVE} ${FASTCGI_CACHE_TTL}
${PAGESPEED_CACHE_DIR} ${PAGESPEED_CACHE_SIZE_KB} ${PAGESPEED_REWRITE_LEVEL}
${PAGESPEED_FILTERS_LINE} ${PAGESPEED_DISABLE_LINE} ${PAGESPEED_INPLACE}
${PAGESPEED_IMAGE_QUALITY} ${PAGESPEED_WEBP_QUALITY} ${PAGESPEED_AVIF_QUALITY}
${PAGESPEED_ADMIN_PATH} ${PAGESPEED_STATS_PATH}
${PAGESPEED_DOWNSTREAM_BLOCK} ${PAGESPEED_DISALLOW_BLOCK} ${PAGESPEED_EXTRA_BLOCK}'

export FASTCGI_CACHE_DIR FASTCGI_CACHE_ZONE_SIZE FASTCGI_CACHE_MAX_SIZE \
       FASTCGI_CACHE_INACTIVE FASTCGI_CACHE_TTL
export DOMAIN WP_ROOT NGINX_WORKER_CONNECTIONS LIMIT_CONN_PER_IP \
       RATE_LIMIT_LOGIN RATE_LIMIT_LOGIN_BURST RATE_LIMIT_XMLRPC RATE_LIMIT_XMLRPC_BURST \
       RATE_LIMIT_API RATE_LIMIT_API_BURST CONVERTED_DIR STATIC_BROWSER_TTL \
       FIREWALL_BYPASS_COOKIE \
       GZIP_LEVEL BROTLI_LEVEL ZSTD_LEVEL COMPRESSION_MIN_LENGTH \
       PAGESPEED_CACHE_DIR PAGESPEED_CACHE_SIZE_KB PAGESPEED_REWRITE_LEVEL \
       PAGESPEED_INPLACE PAGESPEED_IMAGE_QUALITY PAGESPEED_WEBP_QUALITY \
       PAGESPEED_AVIF_QUALITY PAGESPEED_ADMIN_PATH PAGESPEED_STATS_PATH

mkdir -p /etc/nginx/conf.d

# --- Cache di pagina su disco ---
# I due file vanno tenuti coerenti: la zona si dichiara nel contesto http,
# l'uso dentro alle location. Se la cache e' spenta si scrive comunque la
# coppia, ma vuota e con "fastcgi_cache off", altrimenti le location
# includerebbero un file inesistente e nginx non partirebbe.
if [ "${FASTCGI_CACHE_ENABLED}" = "1" ]; then
    mkdir -p "${FASTCGI_CACHE_DIR}"
    # La passata ricorsiva solo quando serve davvero, cioe' la prima volta,
    # quando il volume nasce di root. Farla sempre significa toccare ogni
    # inode della cache ad ogni avvio del container: con
    # FASTCGI_CACHE_MAX_SIZE a 2g sono decine di migliaia di file, e il
    # tempo si paga prima ancora che nginx venga validato.
    # E' lo stesso schema gia' usato per WP_ROOT piu' sotto.
    if [ "$(stat -c '%U' "${FASTCGI_CACHE_DIR}" 2>/dev/null)" != "www-data" ]; then
        log "Correzione proprietario della cache su disco..."
        chown -R www-data:www-data "$(dirname "${FASTCGI_CACHE_DIR}")" 2>/dev/null || true
    fi
    envsubst "${NGINX_VARS}" < /etc/nginx/templates/fastcgi-cache.conf.template \
        > /etc/nginx/snippets/fastcgi-cache.conf
    envsubst "${NGINX_VARS}" < /etc/nginx/templates/fastcgi-cache-use.conf.template \
        > /etc/nginx/snippets/fastcgi-cache-use.conf
    log "cache su disco attiva: ${FASTCGI_CACHE_DIR} | max ${FASTCGI_CACHE_MAX_SIZE} | ttl ${FASTCGI_CACHE_TTL}"
else
    : > /etc/nginx/snippets/fastcgi-cache.conf
    printf '# Cache su disco disattivata (FASTCGI_CACHE_ENABLED=0).\nfastcgi_cache off;\n' \
        > /etc/nginx/snippets/fastcgi-cache-use.conf
    warn "cache su disco disattivata: ogni MISS di Varnish arrivera' a PHP."
fi

envsubst "${NGINX_VARS}" < /etc/nginx/templates/nginx.conf.template      > /etc/nginx/nginx.conf
envsubst "${NGINX_VARS}" < /etc/nginx/templates/wordpress.conf.template  > /etc/nginx/conf.d/wordpress.conf

# --- Compressione ---
# Un blocco per codifica, e ciascuno viene emesso solo se il modulo
# corrispondente e' davvero caricato. Scrivere "brotli on" senza il modulo
# non degraderebbe la compressione: farebbe fallire nginx all'avvio con
# "unknown directive", cioe' sito giu'.
{
    cat <<'HEADER'
# =======================================================
# Compressione - generato da entrypoint.sh
# =======================================================
# Ogni risposta compressa esce con "Vary: Accept-Encoding", quindi Varnish
# tiene in cache una copia per ogni valore distinto di quell'header. Per
# questo Varnish normalizza Accept-Encoding a una sola codifica prima di
# inoltrare (COMPRESSION_PRIORITY nel .env): senza, la stessa homepage
# occuperebbe decine di entry, una per ogni variante testuale dell'header.
#
# Vedi anche: http_gzip_support=off in varnish-entrypoint.sh.
HEADER
    envsubst "${NGINX_VARS}" < /etc/nginx/templates/compression-gzip.conf.template
    ACTIVE_ENCODINGS="gzip"

    if nginx -V 2>&1 | grep -q brotli || [ -f /usr/lib/nginx/modules/ngx_http_brotli_filter_module.so ]; then
        envsubst "${NGINX_VARS}" < /etc/nginx/templates/compression-brotli.conf.template
        ACTIVE_ENCODINGS="br, ${ACTIVE_ENCODINGS}"
    fi

    if [ -f /usr/lib/nginx/modules/ngx_http_zstd_filter_module.so ]; then
        envsubst "${NGINX_VARS}" < /etc/nginx/templates/compression-zstd.conf.template
        ACTIVE_ENCODINGS="zstd, ${ACTIVE_ENCODINGS}"
    fi
} > /etc/nginx/snippets/compression.conf

log "Compressione attiva: ${ACTIVE_ENCODINGS}"

# COMPRESSION_PRIORITY e' letta da Varnish, che gira in un altro container
# e non puo' sapere cosa nginx sappia produrre. Se chiede una codifica che
# qui manca, normalizzera' Accept-Encoding su quella e i browser che la
# annunciano riceveranno risposte NON compresse: peggio che non avere
# affatto br o zstd. Meglio dirlo qui, nei log di avvio.
for enc in $(echo "${COMPRESSION_PRIORITY:-br,zstd,gzip}" | tr ',' ' '); do
    case " ${ACTIVE_ENCODINGS} " in
        *" ${enc},"*|*" ${enc} "*) ;;
        *) warn "COMPRESSION_PRIORITY contiene '${enc}', che nginx non sa produrre: i client che lo annunciano riceveranno risposte non compresse." ;;
    esac
done

# --- CORS degli asset: la mappa ---
# Il file si scrive sempre, anche vuoto di voci: nginx.conf lo include
# sempre, e la location degli asset puo' riferirsi a $cors_static_origin.
# Una mappa dichiarata e mai valorizzata non costa nulla; un include che
# punta a un file inesistente impedisce l'avvio.
{
    cat <<'HEADER'
# =======================================================
# CORS degli asset statici - generato da entrypoint.sh
# =======================================================
# Riguarda solo i file che serve nginx (font, CSS, JavaScript, immagini).
# Tutto cio' che genera WordPress - pagine, REST API, admin-ajax, feed -
# lo governa il mu-plugin dalla scheda "Header e CORS", perche' li' la
# politica puo' dipendere dal contenuto e cambiare senza ricaricare nginx.
#
# Con un elenco di origini la risposta varia per origine, quindi la
# location aggiunge anche "Vary: Origin": senza, la prima origine che
# chiede un file deciderebbe l'header per tutte le altre.
HEADER
    printf 'map $http_origin $cors_static_origin {\n    default "";\n'
    printf '%s' "${CORS_ORIGIN_MAP}"
    printf '}\n'
} > /etc/nginx/snippets/cors.conf

case "${CORS_MODE}" in
    any)  log "CORS asset statici: aperto a tutti (CORS_STATIC_ORIGINS=*)." ;;
    list) log "CORS asset statici: solo le origini elencate in CORS_STATIC_ORIGINS." ;;
    *)    log "CORS asset statici: nessun header (CORS_STATIC_ORIGINS=off)." ;;
esac

envsubst "${NGINX_VARS}" < /etc/nginx/templates/image-negotiation.conf.template \
    > /etc/nginx/snippets/image-negotiation.conf

# =======================================================
# 3-bis. PageSpeed
# =======================================================
# Stessa regola dei moduli di compressione: le direttive si emettono solo
# dopo aver verificato che il modulo ci sia davvero. "pagespeed on" senza
# il .so caricato non degrada l'ottimizzazione, fa fallire l'avvio con
# "unknown directive" - cioe' sito giu'.
#
# In piu' qui il modulo si CARICA solo quando serve: sono circa 60 MB
# mappati in ogni worker, che a PAGESPEED_ENABLED=0 sarebbero sprecati.
PAGESPEED_MODULE_SO=/usr/lib/nginx/modules/ngx_pagespeed_module.so
PAGESPEED_LOAD_FILE=/etc/nginx/modules-enabled/50-mod-pagespeed.conf
PAGESPEED_ACTIVE=0

if [ "${PAGESPEED_ENABLED}" = "1" ] && [ -f "${PAGESPEED_MODULE_SO}" ]; then
    PAGESPEED_ACTIVE=1
elif [ "${PAGESPEED_ENABLED}" = "1" ]; then
    warn "PAGESPEED_ENABLED=1 ma il modulo non e' in questa immagine."
    warn "         Ricostruiscila con --build-arg PAGESPEED_ENABLED=1, oppure metti PAGESPEED_ENABLED=0 nel .env."
fi

if [ "${PAGESPEED_ACTIVE}" = "1" ]; then
    if [ -n "${PAGESPEED_FILTERS}" ]; then
        PAGESPEED_FILTERS_LINE="pagespeed EnableFilters ${PAGESPEED_FILTERS//[[:space:]]/};"
    else
        PAGESPEED_FILTERS_LINE="# PAGESPEED_FILTERS vuoto: solo i filtri del livello qui sopra."
    fi
    if [ -n "${PAGESPEED_DISABLE_FILTERS}" ]; then
        PAGESPEED_DISABLE_LINE="pagespeed DisableFilters ${PAGESPEED_DISABLE_FILTERS//[[:space:]]/};"
    else
        PAGESPEED_DISABLE_LINE="# PAGESPEED_DISABLE_FILTERS vuoto: nessun filtro tolto a mano."
    fi

    # Invalidazione di Varnish a ottimizzazione finita.
    #
    # La prima volta che una pagina passa di qui, PageSpeed la serve
    # mentre sta ancora ottimizzando le risorse che contiene: quella
    # versione, meno ottimizzata, e' anche quella che finisce in Varnish.
    # Con questo blocco il modulo manda un PURGE quando ha finito, e la
    # richiesta successiva rigenera la pagina completa.
    #
    # Il PURGE arriva dall'indirizzo di questo container, che e' esattamente
    # cio' che l'ACL di Varnish elenca, e non ha virgole in X-Forwarded-For
    # perche' non passa da Traefik: sono le due condizioni del VCL. La terza,
    # PURGE_TOKEN, il modulo non la puo' soddisfare - vedi l'avviso sotto.
    if [ "${PAGESPEED_DOWNSTREAM_PURGE}" = "1" ]; then
        PAGESPEED_DOWNSTREAM_BLOCK="
# --- Invalidazione della cache a valle (Varnish) ---
pagespeed DownstreamCachePurgeLocationPrefix http://${VARNISH_HOST:-varnish}:80;
pagespeed DownstreamCachePurgeMethod PURGE;
pagespeed DownstreamCacheRewrittenPercentageThreshold ${PAGESPEED_DOWNSTREAM_THRESHOLD};"
        if [ -n "${PURGE_TOKEN:-}" ]; then
            warn "PURGE_TOKEN e' impostato: i PURGE di PageSpeed verso Varnish riceveranno 403."
            warn "         Il modulo non sa mandare l'header X-Purge-Token. In cache resterebbe"
            warn "         la prima versione della pagina, quella non ancora ottimizzata."
            warn "         Scegli: o PURGE_TOKEN vuoto, o PAGESPEED_DOWNSTREAM_PURGE=0."
        fi
    else
        PAGESPEED_DOWNSTREAM_BLOCK="
# PAGESPEED_DOWNSTREAM_PURGE=0: Varnish non viene invalidato dal modulo."
    fi

    # Percorsi che non devono essere toccati. Sono gli stessi che i due
    # livelli di cache gia' escludono: amministrazione, REST API in
    # entrambe le forme di URL, feed, documenti di discovery. Elencarli
    # anche qui non e' una ripetizione inutile - la' si decide se
    # MEMORIZZARE, qui se RISCRIVERE, e riscrivere un JSON non ha senso in
    # nessun caso.
    PAGESPEED_DISALLOW_BLOCK="
# --- Percorsi esclusi ---
pagespeed Disallow \"*/wp-admin/*\";
pagespeed Disallow \"*/wp-login.php*\";
pagespeed Disallow \"*/wp-json/*\";
pagespeed Disallow \"*rest_route=*\";
pagespeed Disallow \"*/feed/*\";
pagespeed Disallow \"*/.well-known/*\";
pagespeed Disallow \"*/xmlrpc.php*\";"
    for _p in ${PAGESPEED_DISALLOW}; do
        case "${_p}" in
            *[\"\;]*)
                warn "PAGESPEED_DISALLOW contiene '${_p}', che chiuderebbe la direttiva: ignorato."
                ;;
            *)
                PAGESPEED_DISALLOW_BLOCK="${PAGESPEED_DISALLOW_BLOCK}
pagespeed Disallow \"${_p}\";"
                ;;
        esac
    done

    # Direttive extra dal .env, una per riga. Qui dentro passa anche la
    # riga di attivazione della licenza.
    if [ -n "${PAGESPEED_EXTRA_DIRECTIVES}" ]; then
        PAGESPEED_EXTRA_BLOCK="
# --- Direttive da PAGESPEED_EXTRA_DIRECTIVES ---"
        while IFS= read -r _d; do
            _d="${_d#"${_d%%[![:space:]]*}"}"
            [ -z "${_d}" ] && continue
            PAGESPEED_EXTRA_BLOCK="${PAGESPEED_EXTRA_BLOCK}
pagespeed ${_d%;};"
        done <<< "${PAGESPEED_EXTRA_DIRECTIVES}"
    else
        PAGESPEED_EXTRA_BLOCK="
# PAGESPEED_EXTRA_DIRECTIVES vuoto."
    fi

    export PAGESPEED_FILTERS_LINE PAGESPEED_DISABLE_LINE \
           PAGESPEED_DOWNSTREAM_BLOCK PAGESPEED_DISALLOW_BLOCK PAGESPEED_EXTRA_BLOCK

    printf 'load_module modules/ngx_pagespeed_module.so;\n' > "${PAGESPEED_LOAD_FILE}"
    envsubst "${NGINX_VARS}" < /etc/nginx/templates/pagespeed.conf.template \
        > /etc/nginx/snippets/pagespeed.conf
    envsubst "${NGINX_VARS}" < /etc/nginx/templates/pagespeed-locations.conf.template \
        > /etc/nginx/snippets/pagespeed-locations.conf

    log "PageSpeed attivo: livello ${PAGESPEED_REWRITE_LEVEL} | cache ${PAGESPEED_CACHE_DIR} ($(( PAGESPEED_CACHE_SIZE_KB / 1024 )) MB)"
    [ -r /etc/stack-pagespeed-version ] && log "  modulo $(cat /etc/stack-pagespeed-version)"
    if [ -z "${PAGESPEED_EXTRA_DIRECTIVES}" ]; then
        warn "PageSpeed senza licenza: il modulo si carica e risponde, ma gira in pass-through"
        warn "         e non ottimizza niente. La riga di attivazione del token va in"
        warn "         PAGESPEED_EXTRA_DIRECTIVES. Senza, e con CONVERTED_DIR vuoto, nessuno"
        warn "         produce AVIF o WebP."
    fi
else
    # I due file devono esistere comunque: nginx.conf e il server block li
    # includono sempre. Stesso schema della coppia fastcgi-cache*.conf.
    rm -f "${PAGESPEED_LOAD_FILE}"
    printf '# PageSpeed non attivo (PAGESPEED_ENABLED=%s).\n' "${PAGESPEED_ENABLED}" \
        > /etc/nginx/snippets/pagespeed.conf
    printf '# PageSpeed non attivo: nessuna location da dichiarare.\n' \
        > /etc/nginx/snippets/pagespeed-locations.conf

    if [ -z "${CONVERTED_DIR}" ]; then
        warn "PageSpeed spento e CONVERTED_DIR vuoto: nessuno produce AVIF o WebP."
        warn "         O accendi PAGESPEED_ENABLED, o rimetti un plugin di conversione"
        warn "         (CompressX, WebP Express) e la sua cartella in CONVERTED_DIR."
    fi
fi

if [ "${FIREWALL_ENABLED}" = "1" ]; then
    # Il cookie di bypass spegne TUTTO il firewall, quindi due cose devono
    # essere vere prima di scriverlo nella configurazione.
    #
    # 1. Il valore di esempio non deve essere funzionante. E' pubblicato in
    #    tre punti di questo repository (.env.example, docker-compose.yml e
    #    qui sopra come default): lasciarlo attivo significa distribuire una
    #    chiave che chiunque conosca il progetto puo' usare. Un avviso nei
    #    log non basta - si legge una volta, il default resta.
    #
    # 2. Il valore finisce GREZZO dentro a una PCRE
    #    ("~*${FIREWALL_BYPASS_COOKIE}" in firewall-8g.conf.template).
    #    Una parentesi tonda, che un generatore di password produce senza
    #    pensarci, rende la mappa non compilabile e nginx non parte: sito
    #    giu' al deploy, con un errore che non nomina il .env. Un punto o
    #    un asterisco, al contrario, allargano il bypass a quasi qualunque
    #    cookie.
    #
    # In entrambi i casi si fallisce CHIUSI: il bypass si disattiva, il
    # firewall resta in piedi.
    case "${FIREWALL_BYPASS_COOKIE}" in
        ""|"wpfw-bypass-CAMBIAMI")
            warn "FIREWALL_BYPASS_COOKIE non impostato (o ancora il valore di esempio): bypass del firewall DISATTIVATO."
            warn "         Mettine uno tuo nel .env per poterlo usare."
            FIREWALL_BYPASS_COOKIE=""
            ;;
        *[!A-Za-z0-9_-]*)
            warn "FIREWALL_BYPASS_COOKIE contiene caratteri non ammessi: bypass del firewall DISATTIVATO."
            warn "         Sono ammessi solo lettere, numeri, '-' e '_': il valore finisce dentro a"
            warn "         un'espressione regolare di nginx, e un carattere come '(' impedirebbe l'avvio."
            FIREWALL_BYPASS_COOKIE=""
            ;;
    esac

    if [ -z "${FIREWALL_BYPASS_COOKIE}" ]; then
        # Il template dichiara sempre la mappa, quindi non si puo' toglierla:
        # le si da' un valore che nessun client puo' indovinare.
        FIREWALL_BYPASS_COOKIE="bypass-disattivato-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    fi
    export FIREWALL_BYPASS_COOKIE

    envsubst "${NGINX_VARS}" < /etc/nginx/templates/firewall-8g.conf.template \
        > /etc/nginx/snippets/firewall-8g.conf
else
    # Il file deve esistere comunque: nginx.conf lo include sempre.
    # $fw_block a 0 costante fa saltare ogni controllo.
    warn "FIREWALL_ENABLED=0: il firewall applicativo e' disattivato."
    printf 'map $host $fw_block {\n    default 0;\n}\n' > /etc/nginx/snippets/firewall-8g.conf
fi

# =======================================================
# 4. Cartelle e permessi
# =======================================================
mkdir -p "${WP_ROOT}" "${WP_BASE}/logs" /run/php /tmp/opcache /var/lib/nginx/body
chown www-data:www-data /tmp/opcache /run/php "${WP_BASE}" "${WP_BASE}/logs"
chmod 755 "${WP_BASE}"

# I volumi Docker nascono di root: senza questo, la prima installazione di
# WordPress non riuscirebbe a scrivere nulla.
if [ "$(stat -c '%U' "${WP_ROOT}")" != "www-data" ]; then
    log "Correzione proprietario di ${WP_ROOT}..."
    chown -R www-data:www-data "${WP_ROOT}"
fi

# Passata completa su permessi: su un sito grande costa parecchi secondi
# ad ogni avvio, quindi e' opt-in. Serve dopo un ripristino da backup o un
# upload fatto da un altro utente.
if [ "${FIX_PERMISSIONS}" = "1" ]; then
    log "FIX_PERMISSIONS=1: normalizzazione di proprietario e permessi..."
    chown -R www-data:www-data "${WP_ROOT}"
    find "${WP_ROOT}" -type d -exec chmod 755 {} +
    find "${WP_ROOT}" -type f -exec chmod 644 {} +
fi

# =======================================================
# 5. Attesa del database
# =======================================================
wait_for_db() {
    local tries=60
    while [ "${tries}" -gt 0 ]; do
        if "/usr/bin/php${PHP_VER}" -r '
            $c = @mysqli_connect(getenv("DB_HOST"), getenv("DB_USER"), getenv("DB_PASS"));
            exit($c ? 0 : 1);
        ' 2>/dev/null; then
            return 0
        fi
        tries=$(( tries - 1 ))
        sleep 2
    done
    return 1
}

export DB_HOST DB_NAME DB_USER DB_PASS REDIS_HOST REDIS_PORT REDIS_PASSWORD

if [ "${WP_AUTO_INSTALL}" = "1" ]; then
    log "Attesa del database ${DB_HOST}..."
    if wait_for_db; then
        log "Database raggiungibile."
    else
        # Non e' fatale: nginx puo' comunque servire, e il messaggio di
        # errore di WordPress e' piu' utile di un container che non parte.
        warn "Database non raggiungibile dopo 120s. Si prosegue: controlla DB_HOST, DB_USER e DB_PASS."
    fi
fi

# =======================================================
# 6. Installazione di WordPress
# =======================================================
generate_salt() {
    # Salt generati in locale invece che dall'API di wordpress.org: un
    # deploy non deve dipendere dalla raggiungibilita' di un servizio
    # esterno. I caratteri esclusi sono quelli che romperebbero la
    # stringa PHP fra apici singoli.
    tr -dc 'A-Za-z0-9!@#%^&*()_+=~,.<>?/|:;{}[]-' < /dev/urandom | head -c 64
}

if [ "${WP_AUTO_INSTALL}" = "1" ] && [ ! -f "${WP_ROOT}/index.php" ]; then
    log "WordPress non trovato: scaricamento in corso..."
    LOCALE_ARG=()
    [ -n "${WORDPRESS_LOCALE}" ] && LOCALE_ARG=(--locale="${WORDPRESS_LOCALE}")
    /usr/local/bin/wp core download "${LOCALE_ARG[@]}" \
        || die "Scaricamento di WordPress fallito. Verifica la connettivita' in uscita del container."
    log "WordPress scaricato."
fi

if [ "${WP_AUTO_INSTALL}" = "1" ] && [ ! -f "${WP_ROOT}/wp-config.php" ]; then
    log "Generazione di wp-config.php..."

    REDIS_PASS_DEFINE="// Redis senza password."
    if [ -n "${REDIS_PASSWORD}" ]; then
        REDIS_PASS_DEFINE="define( 'WP_REDIS_PASSWORD', '${REDIS_PASSWORD}' );"
    fi

    /usr/local/bin/wp config create \
        --dbname="${DB_NAME}" \
        --dbuser="${DB_USER}" \
        --dbpass="${DB_PASS}" \
        --dbhost="${DB_HOST}" \
        --dbprefix="${DB_TABLE_PREFIX}" \
        --dbcharset=utf8mb4 \
        --dbcollate=utf8mb4_unicode_ci \
        --skip-salts \
        --skip-check \
        --force \
        --extra-php <<PHPEOF
/**
 * -------------------------------------------------------
 * Configurazione dello stack (generata da entrypoint.sh)
 * -------------------------------------------------------
 * Queste define vengono scritte una volta sola, alla prima installazione.
 * Modificarle qui e' permanente: al riavvio il file non viene riscritto.
 */

/* --- URL del sito --- */
/* Fissarli evita il redirect loop classico dietro a un reverse proxy e
   impedisce a un attaccante di avvelenare l'URL del sito via header Host. */
define( 'WP_HOME',    'https://${DOMAIN}' );
define( 'WP_SITEURL', 'https://${DOMAIN}' );

/* --- Object cache Redis --- */
/* Richiede il plugin "Redis Object Cache". Il prefisso col dominio tiene
   separate piu' installazioni che condividono lo stesso Redis. */
define( 'WP_REDIS_HOST',     '${REDIS_HOST}' );
define( 'WP_REDIS_PORT',     ${REDIS_PORT} );
${REDIS_PASS_DEFINE}
define( 'WP_REDIS_PREFIX',   '${DOMAIN}' );
define( 'WP_REDIS_DATABASE', 0 );
define( 'WP_REDIS_TIMEOUT',      1 );
define( 'WP_REDIS_READ_TIMEOUT', 1 );
define( 'WP_CACHE_KEY_SALT', '${DOMAIN}' );
define( 'WP_CACHE', true );

/* --- Varnish --- */
/* Il plugin "Proxy Cache Purge" manda i PURGE a questo host invece che
   all'URL pubblico: passando da Traefik verrebbero rifiutati, perche'
   Varnish accetta le invalidazioni solo dalla rete interna. */
define( 'VHP_VARNISH_IP', 'varnish' );

/* --- Cron --- */
/* Il cron interno parte dentro alle richieste dei visitatori. Con Varnish
   davanti le richieste che arrivano a PHP sono poche e irregolari, quindi
   i job non partirebbero con regolarita'. Li esegue supervisord. */
define( 'DISABLE_WP_CRON', true );

/* --- Filesystem --- */
/* I file appartengono all'utente con cui gira PHP: nessuna richiesta di
   credenziali FTP durante gli aggiornamenti. */
define( 'FS_METHOD', 'direct' );

/* --- Sicurezza --- */
/* L'editor di temi e plugin del pannello trasforma un account
   amministratore rubato in esecuzione di codice arbitrario. */
define( 'DISALLOW_FILE_EDIT', true );
define( 'WP_AUTO_UPDATE_CORE', 'minor' );

/* --- Memoria e manutenzione --- */
define( 'WP_MEMORY_LIMIT',     '${PHP_MEM_LIMIT}' );
define( 'WP_MAX_MEMORY_LIMIT', '${PHP_CLI_MEM_LIMIT}' );
define( 'WP_POST_REVISIONS', 10 );
define( 'EMPTY_TRASH_DAYS',  30 );
define( 'AUTOSAVE_INTERVAL', 120 );
define( 'IMAGE_EDIT_OVERWRITE', true );

/* --- Debug --- */
define( 'WP_DEBUG', false );
define( 'WP_DEBUG_LOG', false );
define( 'WP_DEBUG_DISPLAY', false );
PHPEOF

    SALT_FILE="$(mktemp /tmp/wp-salts.XXXXXX)"
    {
        echo ""
        echo "/* --- Chiavi e salt (generati localmente) --- */"
        for key in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY \
                   AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
            printf "define( '%s', '%s' );\n" "${key}" "$(generate_salt)"
        done
    } > "${SALT_FILE}"

    # I salt vanno prima di "That's all, stop editing": dopo quella riga
    # WordPress ha gia' caricato wp-settings.php e le define non avrebbero
    # piu' effetto.
    awk -v saltfile="${SALT_FILE}" '
        !done && /\$table_prefix/ {
            while ((getline line < saltfile) > 0) print line
            print ""
            done = 1
        }
        { print }
    ' "${WP_ROOT}/wp-config.php" > "${WP_ROOT}/wp-config.php.new"

    mv "${WP_ROOT}/wp-config.php.new" "${WP_ROOT}/wp-config.php"
    rm -f "${SALT_FILE}"
    chown www-data:www-data "${WP_ROOT}/wp-config.php"
    chmod 640 "${WP_ROOT}/wp-config.php"

    log "wp-config.php creato."
    log "Apri https://${DOMAIN} per completare l'installazione dal browser."
fi

# =======================================================
# 6.1 Must-use plugin di gestione delle cache
# =======================================================
# Copiato ad OGNI avvio, non solo alla prima installazione: e' parte
# dell'infrastruttura e deve seguire la versione dell'immagine, non
# restare all'ultima versione installata per caso.
#
# Sta in mu-plugins e non in plugins perche' non deve poter essere
# disattivato dalla bacheca: se sparisse, i due livelli di cache
# smetterebbero di ricevere istruzioni sui TTL e sulle invalidazioni
# senza che nessun errore lo segnali.
if [ "${INSTALL_MU_PLUGINS}" = "1" ] && [ -d "${WP_ROOT}/wp-content" ]; then
    MU_DIR="${WP_ROOT}/wp-content/mu-plugins"
    mkdir -p "${MU_DIR}"
    if cp -f /opt/wordpress/mu-plugins/*.php "${MU_DIR}/" 2>/dev/null; then
        chown -R www-data:www-data "${MU_DIR}"
        chmod 644 "${MU_DIR}"/*.php
        log "must-use plugin aggiornati: $(ls -1 /opt/wordpress/mu-plugins/*.php 2>/dev/null | wc -l) file."
    else
        warn "impossibile copiare i must-use plugin in ${MU_DIR}."
    fi
fi

# wp-config.php non deve mai essere leggibile da altri utenti del
# container: contiene le credenziali del database.
[ -f "${WP_ROOT}/wp-config.php" ] && chmod 640 "${WP_ROOT}/wp-config.php"

# =======================================================
# 6.2 Dominio: allineamento di un sito gia' installato
# =======================================================
# WP_HOME e WP_SITEURL vengono scritti in wp-config.php una volta sola,
# alla prima installazione: cambiare DOMAIN nel .env non li tocca, e
# quelle due define VINCONO sui valori nel database. Il sito continua
# quindi a generare link e redirect verso il dominio vecchio, e nulla lo
# segnala - si scopre dal browser, a deploy fatto.
#
# WP_DOMAIN_SYNC decide cosa fare quando i due non coincidono:
#
#   off     (default) lo dice nei log, con le istruzioni. Non scrive nulla.
#   config  aggiorna le define in wp-config.php e svuota le cache. I link
#           DENTRO ai contenuti restano al dominio vecchio.
#   full    come config, piu' una search-replace su tutto il database.
#
# "full" riscrive il database, quindi e' opt-in e non parte mai senza
# aver prima esportato un dump: se qualcosa va storto, il dump e' l'unica
# strada indietro. Se l'export fallisce, non si tocca niente.
: "${WP_DOMAIN_SYNC:=off}"

case "${WP_DOMAIN_SYNC}" in
    off|config|full) ;;
    *)
        warn "WP_DOMAIN_SYNC='${WP_DOMAIN_SYNC}' non e' un valore valido (off, config, full): uso 'off'."
        WP_DOMAIN_SYNC=off
        ;;
esac

# Il dominio con cui il sito sta girando davvero. Si legge da
# wp-config.php, non dal database, perche' e' la define a comandare; il
# database e' il ripiego per un'installazione che non la usa.
# "wp config get" non tocca il database, quindi risponde anche a
# MariaDB irraggiungibile.
dominio_attuale() {
    local _v
    _v="$(timeout 20 /usr/local/bin/wp config get WP_HOME --type=constant 2>/dev/null || true)"
    if [ -z "${_v}" ]; then
        _v="$(timeout 20 /usr/local/bin/wp option get home 2>/dev/null || true)"
    fi
    # Resta il solo host: niente schema, niente porta, niente percorso.
    printf '%s' "${_v}" \
        | sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#/.*$##' -e 's#:[0-9]*$##'
}

svuota_cache_dominio() {
    timeout 60 /usr/local/bin/wp cache flush >/dev/null 2>&1 \
        && log "  object cache svuotata." \
        || warn "  object cache non svuotata (Redis irraggiungibile?)."

    if [ -d "${FASTCGI_CACHE_DIR}" ]; then
        find "${FASTCGI_CACHE_DIR}" -mindepth 1 -delete 2>/dev/null || true
        log "  cache di pagina su disco svuotata."
    fi

    # Varnish sta in un altro container e puo' non essere ancora in
    # piedi: best effort, con un timeout corto. Se non risponde, o e'
    # appena partito (cache vuota) o lo si svuota dalla bacheca.
    _ban_headers=(-H "Host: ${DOMAIN}" -H "X-Ban-Expression: ." -H "X-Forwarded-Proto: https")
    [ -n "${PURGE_TOKEN:-}" ] && _ban_headers+=(-H "X-Purge-Token: ${PURGE_TOKEN}")
    if curl -fsS -m 3 -X BAN "${_ban_headers[@]}" "http://${VARNISH_HOST:-varnish}/" >/dev/null 2>&1; then
        log "  cache di Varnish invalidata."
    else
        warn "  Varnish non raggiungibile: se era gia' in piedi, svuotalo dalla bacheca."
    fi
}

if [ -f "${WP_ROOT}/wp-config.php" ]; then
    DOMINIO_VECCHIO="$(dominio_attuale)"
else
    DOMINIO_VECCHIO=""
fi

if [ -n "${DOMINIO_VECCHIO}" ] && [ "${DOMINIO_VECCHIO}" != "${DOMAIN}" ]; then

    warn "il sito gira su '${DOMINIO_VECCHIO}', ma DOMAIN dice '${DOMAIN}'."

    # Un DOMAIN non impostato vale "localhost" per via del default in
    # cima a questo script. Prenderlo per buono vorrebbe dire riscrivere
    # il database di un sito vero verso localhost per una variabile
    # dimenticata: non si fa, in nessuna modalita'.
    if [ "${DOMAIN}" = "localhost" ]; then
        warn "         DOMAIN non e' impostato (vale 'localhost'): non tocco niente."
        warn "         Impostalo nel .env, o il sito resta su '${DOMINIO_VECCHIO}'."
        WP_DOMAIN_SYNC=off
    fi

    case "${WP_DOMAIN_SYNC}" in
        off)
            warn "         WP_DOMAIN_SYNC=off: wp-config.php non viene toccato e il sito"
            warn "         continuera' a rimandare a '${DOMINIO_VECCHIO}'."
            warn "         Per farlo fare all'avvio: WP_DOMAIN_SYNC=full (riscrive il"
            warn "         database, dopo un dump) oppure =config (solo le define)."
            ;;

        config|full)
            if ! timeout 20 /usr/local/bin/wp core is-installed >/dev/null 2>&1; then
                warn "         sito non installato o database irraggiungibile: rimando al prossimo avvio."
            else
                log "Allineamento del dominio: ${DOMINIO_VECCHIO} -> ${DOMAIN} (WP_DOMAIN_SYNC=${WP_DOMAIN_SYNC})"
                SYNC_OK=1

                if [ "${WP_DOMAIN_SYNC}" = "full" ]; then
                    # Il dump PRIMA di qualunque scrittura, e fuori dalla
                    # docroot: contiene gli hash delle password.
                    BACKUP_DIR="${WP_BASE}/backups"
                    mkdir -p "${BACKUP_DIR}"
                    chown www-data:www-data "${BACKUP_DIR}" 2>/dev/null || true
                    BACKUP_FILE="${BACKUP_DIR}/pre-dominio-${DOMINIO_VECCHIO}-$(date +%Y%m%d-%H%M%S).sql"

                    log "  dump del database in ${BACKUP_FILE}..."
                    if timeout 600 /usr/local/bin/wp db export "${BACKUP_FILE}" >/dev/null 2>&1; then
                        chmod 600 "${BACKUP_FILE}" 2>/dev/null || true
                        log "  dump riuscito ($(du -h "${BACKUP_FILE}" 2>/dev/null | cut -f1))."
                    else
                        warn "  DUMP FALLITO: non riscrivo il database. Il sito resta su '${DOMINIO_VECCHIO}'."
                        rm -f "${BACKUP_FILE}"
                        SYNC_OK=0
                    fi

                    if [ "${SYNC_OK}" = "1" ]; then
                        # Si sostituisce "//vecchio", non "https://vecchio":
                        # cosi' cadono insieme http://, https:// e i link
                        # protocol-relative, in una passata sola.
                        #
                        # --skip-columns=guid non e' opzionale: i GUID dei
                        # contenuti sono identificatori storici, non
                        # indirizzi, e i lettori di feed si accorgono se
                        # cambiano.
                        #
                        # L'output va in un file invece che in una pipe:
                        # in pipe l'esito del comando sarebbe quello di
                        # "sed", e la riuscita dipenderebbe da pipefail.
                        # Una search-replace fallita che risulta riuscita
                        # e' esattamente il guasto da non avere qui.
                        log "  search-replace su tutte le tabelle..."
                        SR_LOG="$(mktemp)"
                        if timeout 1800 /usr/local/bin/wp search-replace \
                                "//${DOMINIO_VECCHIO}" "//${DOMAIN}" \
                                --all-tables --precise --skip-columns=guid \
                                --report-changed-only > "${SR_LOG}" 2>&1; then
                            sed 's/^/     /' "${SR_LOG}"
                            log "  database allineato."
                        else
                            sed 's/^/     /' "${SR_LOG}" >&2
                            warn "  SEARCH-REPLACE FALLITA. Il dump e' in ${BACKUP_FILE}."
                            warn "  wp-config.php non viene toccato, cosi' al prossimo avvio si riprova."
                            SYNC_OK=0
                        fi
                        rm -f "${SR_LOG}"
                    fi
                fi

                # Le define per ultime, e solo se tutto il resto e'
                # andato: sono loro il marcatore di "dominio corrente".
                # Finche' restano vecchie, un avvio successivo riprova;
                # aggiornarle dopo un fallimento vorrebbe dire un sito a
                # meta' che non si segnala piu'.
                if [ "${SYNC_OK}" = "1" ]; then
                    /usr/local/bin/wp config set WP_HOME    "https://${DOMAIN}" >/dev/null
                    /usr/local/bin/wp config set WP_SITEURL "https://${DOMAIN}" >/dev/null
                    log "  WP_HOME e WP_SITEURL aggiornate."

                    # Prefissi di chiave: si spostano solo se erano il
                    # dominio vecchio, cioe' se li aveva scritti questo
                    # entrypoint. Cambiarli equivale a buttare l'object
                    # cache, che tanto va buttata comunque.
                    for _c in WP_REDIS_PREFIX WP_CACHE_KEY_SALT; do
                        if [ "$(/usr/local/bin/wp config get "${_c}" --type=constant 2>/dev/null || true)" = "${DOMINIO_VECCHIO}" ]; then
                            /usr/local/bin/wp config set "${_c}" "${DOMAIN}" >/dev/null
                        fi
                    done

                    svuota_cache_dominio

                    if [ "${WP_DOMAIN_SYNC}" = "config" ]; then
                        warn "  WP_DOMAIN_SYNC=config: i link dentro ai contenuti puntano ancora a"
                        warn "  '${DOMINIO_VECCHIO}'. Per spostarli: WP_DOMAIN_SYNC=full, oppure"
                        warn "  wp search-replace '//${DOMINIO_VECCHIO}' '//${DOMAIN}' --all-tables --precise --skip-columns=guid"
                    fi

                    log "Dominio allineato. Ricordati del dominio nuovo anche su Dokploy (rotta e certificato)."
                    log "  Rimetti WP_DOMAIN_SYNC=off: fatto il trasloco, quel valore serve solo a far"
                    log "  riscrivere il database al prossimo DOMAIN sbagliato per errore."
                fi
            fi
            ;;
    esac
fi

# =======================================================
# 6.3 Accesso all'installer
# =======================================================
# Su un sito installato /wp-admin/install.php e /wp-admin/setup-config.php
# vanno chiusi: sono la porta d'ingresso classica di chi trova un sito con
# il database vuoto, e ci ripunta WordPress su un database proprio
# diventando amministratore.
#
# Ma finche' il sito NON e' installato quella stessa porta e' l'unico modo
# di installarlo dal browser, che e' proprio cio' che l'entrypoint dice di
# fare dopo aver creato wp-config.php. Chiuderla sempre - com'era - dava
# 404 su /wp-admin/install.php al primo accesso: sito non installabile
# affatto, con l'unica via d'uscita "wp core install" dalla CLI.
#
# Il guard viene quindi generato ad ogni avvio in base allo stato reale:
# aperto solo finche' serve, richiuso da solo al riavvio successivo.
# Nessuna finestra aggiuntiva: dopo l'installazione install.php risponde
# comunque "Gia' installato" senza toccare niente.
case "${WP_INSTALL_ACCESS}" in
    auto|deny|open) ;;
    *)
        warn "WP_INSTALL_ACCESS='${WP_INSTALL_ACCESS}' non e' un valore valido (auto, deny, open): uso 'auto'."
        WP_INSTALL_ACCESS=auto
        ;;
esac

# Un timeout esplicito perche' qui si interroga il database: senza, un
# database irraggiungibile ritarderebbe l'avvio di nginx di un minuto
# buono. Il fallimento vale "non installato", che e' anche il caso in cui
# l'installer serve.
if timeout 20 /usr/local/bin/wp core is-installed >/dev/null 2>&1; then
    WP_IS_INSTALLED=1
else
    WP_IS_INSTALLED=0
fi

case "${WP_INSTALL_ACCESS}" in
    open)
        OPEN_INSTALL=1
        OPEN_SETUP=1
        ;;
    deny)
        OPEN_INSTALL=0
        OPEN_SETUP=0
        ;;
    *)
        # install.php serve finche' le tabelle non ci sono; setup-config.php
        # solo se manca wp-config.php (con WP_AUTO_INSTALL=1 non succede mai:
        # lo genera l'entrypoint qui sopra).
        if [ "${WP_IS_INSTALLED}" = "1" ]; then OPEN_INSTALL=0; else OPEN_INSTALL=1; fi
        if [ -f "${WP_ROOT}/wp-config.php" ]; then OPEN_SETUP=0; else OPEN_SETUP=1; fi
        ;;
esac

# L'installer sta dietro allo stesso rate limit di wp-login.php: e' una
# pagina che un utente legittimo carica una manciata di volte, e lasciarla
# aperta a raffica sarebbe un invito.
install_guard_open() {
    cat <<EOF
location = $1 {
    limit_req       zone=wp_login burst=${RATE_LIMIT_LOGIN_BURST} nodelay;
    include         /etc/nginx/snippets/security-headers.conf;
    include         /etc/nginx/snippets/fastcgi-php.conf;
    fastcgi_pass    unix:/run/php/php-fpm.sock;
}
EOF
}

install_guard_deny() {
    printf 'location = %s { deny all; return 404; }\n' "$1"
}

if [ "${WP_IS_INSTALLED}" = "1" ]; then
    INSTALL_STATE="installato"
else
    INSTALL_STATE="non installato (o database non raggiungibile)"
fi

{
    printf '# Generato da entrypoint.sh: WP_INSTALL_ACCESS=%s, WordPress %s.\n' \
        "${WP_INSTALL_ACCESS}" "${INSTALL_STATE}"
    if [ "${OPEN_INSTALL}" = "1" ]; then
        install_guard_open /wp-admin/install.php
    else
        install_guard_deny /wp-admin/install.php
    fi
    if [ "${OPEN_SETUP}" = "1" ]; then
        install_guard_open /wp-admin/setup-config.php
    else
        install_guard_deny /wp-admin/setup-config.php
    fi
} > /etc/nginx/snippets/install-guard.conf

if [ "${OPEN_INSTALL}" = "1" ] && [ "${WP_INSTALL_ACCESS}" = "open" ]; then
    warn "WP_INSTALL_ACCESS=open: /wp-admin/install.php resta raggiungibile anche a sito installato."
elif [ "${OPEN_INSTALL}" = "1" ]; then
    log "Installer aperto: completa l'installazione su https://${DOMAIN}/wp-admin/install.php (si richiude da solo al riavvio successivo)."
else
    log "Installer chiuso: /wp-admin/install.php risponde 404."
fi

# =======================================================
# 7. Verifica della configurazione
# =======================================================
log "Verifica della configurazione nginx..."

# PageSpeed e' l'unico pezzo di questa configurazione che arriva da un
# pacchetto di terzi, quindi e' anche l'unico di cui non possiamo sapere
# in anticipo se ogni direttiva esiste nella versione installata. Una
# direttiva sconosciuta fa fallire l'avvio di nginx: sito giu' per una
# ottimizzazione, che e' il rapporto sbagliato fra rischio e guadagno.
#
# Qui nginx -t viene quindi usato come oracolo: se si lamenta di una riga
# di pagespeed.conf, quella riga viene commentata e si riprova. Se dopo
# qualche giro non ne esce, PageSpeed si spegne del tutto e il sito parte
# senza. In entrambi i casi la cosa e' scritta nei log e visibile nella
# scheda PageSpeed della bacheca: il guasto che questo stack non tollera
# e' quello silenzioso, non quello dichiarato.
disattiva_pagespeed() {
    rm -f "${PAGESPEED_LOAD_FILE}"
    printf '# PageSpeed disattivato all%savvio: nginx ha rifiutato la configurazione.\n' "'" \
        > /etc/nginx/snippets/pagespeed.conf
    printf '# PageSpeed disattivato all%savvio: nessuna location da dichiarare.\n' "'" \
        > /etc/nginx/snippets/pagespeed-locations.conf
    PAGESPEED_ACTIVE=0
}

if [ "${PAGESPEED_ACTIVE}" = "1" ]; then
    _tentativi=0
    while [ "${_tentativi}" -lt 6 ]; do
        NGINX_TEST_OUT="$(nginx -t 2>&1)" && break
        _riga="$(printf '%s\n' "${NGINX_TEST_OUT}" \
            | sed -n 's#.*/etc/nginx/snippets/pagespeed\.conf:\([0-9][0-9]*\).*#\1#p' | head -1)"
        [ -z "${_riga}" ] && break
        warn "PageSpeed: $(printf '%s\n' "${NGINX_TEST_OUT}" | grep -m1 -i 'emerg' || true)"
        warn "         Riga scartata: $(sed -n "${_riga}p" /etc/nginx/snippets/pagespeed.conf)"
        sed -i "${_riga}s|^|# scartata all'avvio: |" /etc/nginx/snippets/pagespeed.conf
        _tentativi=$(( _tentativi + 1 ))
    done

    # L'esito si cattura in una variabile invece di mettere "nginx -t" in
    # una pipe: con "set -o pipefail" una pipeline vale l'errore del
    # comando che fallisce, quindi "nginx -t | grep pagespeed" risultava
    # SEMPRE fallita proprio nel caso che qui interessa - quello in cui
    # nginx -t fallisce - e la disattivazione non scattava mai.
    NGINX_TEST_OUT="$(nginx -t 2>&1 || true)"
    if printf '%s\n' "${NGINX_TEST_OUT}" | grep -qi 'is successful'; then
        :
    elif printf '%s\n' "${NGINX_TEST_OUT}" | grep -qi 'pagespeed'; then
        warn "PageSpeed: nginx continua a rifiutare la configurazione. Lo disattivo e proseguo senza."
        warn "         $(printf '%s\n' "${NGINX_TEST_OUT}" | grep -m1 -i 'emerg' || true)"
        disattiva_pagespeed
    fi
fi

nginx -t

# --- Stato per la bacheca ---
# Il mu-plugin gira dentro PHP e non puo' leggere la configurazione di
# nginx: senza questo file dovrebbe indovinare, e una schermata di stato
# che indovina e' peggio di una che non c'e'. Sta fuori dalla docroot -
# accanto a logs/ e backups/ - quindi non e' scaricabile dal web.
_json_esc() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'
}
_json_bool() { [ "$1" = "1" ] && printf 'true' || printf 'false'; }

cat > "${WP_BASE}/stack-state.json" <<JSONEOF
{
  "generato": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "configurazione": "$( [ -r /etc/stack-config-version ] && cat /etc/stack-config-version || echo sconosciuta )",
  "php": "${PHP_VER}",
  "compressione": "$(_json_esc "${ACTIVE_ENCODINGS}")",
  "static_browser_ttl": ${STATIC_BROWSER_TTL},
  "converted_dir": "$(_json_esc "${CONVERTED_DIR}")",
  "cors_statico": {
    "modo": "${CORS_MODE}",
    "origini": "$(_json_esc "${CORS_STATIC_ORIGINS}")"
  },
  "varnish_host": "$(_json_esc "${VARNISH_HOST:-varnish}")",
  "purge_token": $(_json_bool "$( [ -n "${PURGE_TOKEN:-}" ] && echo 1 || echo 0 )"),
  "pagespeed": {
    "richiesto": $(_json_bool "${PAGESPEED_ENABLED}"),
    "modulo_presente": $(_json_bool "$( [ -f "${PAGESPEED_MODULE_SO}" ] && echo 1 || echo 0 )"),
    "attivo": $(_json_bool "${PAGESPEED_ACTIVE}"),
    "versione": "$( [ -r /etc/stack-pagespeed-version ] && cat /etc/stack-pagespeed-version || echo '' )",
    "livello": "$(_json_esc "${PAGESPEED_REWRITE_LEVEL}")",
    "filtri": "$(_json_esc "${PAGESPEED_FILTERS}")",
    "filtri_esclusi": "$(_json_esc "${PAGESPEED_DISABLE_FILTERS}")",
    "cache_dir": "$(_json_esc "${PAGESPEED_CACHE_DIR}")",
    "cache_size_kb": ${PAGESPEED_CACHE_SIZE_KB},
    "qualita_immagini": ${PAGESPEED_IMAGE_QUALITY},
    "qualita_webp": ${PAGESPEED_WEBP_QUALITY},
    "qualita_avif": ${PAGESPEED_AVIF_QUALITY},
    "admin_path": "$(_json_esc "${PAGESPEED_ADMIN_PATH}")",
    "stats_path": "$(_json_esc "${PAGESPEED_STATS_PATH}")",
    "purge_a_valle": $(_json_bool "${PAGESPEED_DOWNSTREAM_PURGE}"),
    "soglia_purge": ${PAGESPEED_DOWNSTREAM_THRESHOLD},
    "licenza_configurata": $(_json_bool "$( [ -n "${PAGESPEED_EXTRA_DIRECTIVES}" ] && echo 1 || echo 0 )")
  }
}
JSONEOF
chown www-data:www-data "${WP_BASE}/stack-state.json" 2>/dev/null || true
chmod 644 "${WP_BASE}/stack-state.json"

log "Verifica della configurazione PHP-FPM..."
"/usr/sbin/php-fpm${PHP_VER}" -t

# =======================================================
# 8. Avvio
# =======================================================
log "Avvio di nginx + PHP-FPM ${PHP_VER}..."
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
