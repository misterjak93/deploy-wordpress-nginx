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
case "${PHP_VERSION}" in
    83|8.3) PHP_VER=8.3 ;;
    84|8.4) PHP_VER=8.4 ;;
    85|8.5) PHP_VER=8.5 ;;
    *)      die "PHP_VERSION='${PHP_VERSION}' non riconosciuta. Valori ammessi: 8.3, 8.4, 8.5." ;;
esac

if [ ! -x "/usr/sbin/php-fpm${PHP_VER}" ]; then
    die "PHP ${PHP_VER} non e' in questa immagine (costruita con: ${BUILD_PHP_VERSIONS:-sconosciuto}).
   Ricostruisci l'immagine con PHP_VERSIONS che includa ${PHP_VER}."
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
: "${CONVERTED_DIR:=compressx-nextgen}"
: "${FIREWALL_ENABLED:=1}"
: "${FIREWALL_BYPASS_COOKIE:=wpfw-bypass-CAMBIAMI}"

# --- Compressione ---
: "${GZIP_LEVEL:=6}"
: "${BROTLI_LEVEL:=5}"
: "${ZSTD_LEVEL:=6}"
: "${COMPRESSION_MIN_LENGTH:=256}"
: "${COMPRESSION_PRIORITY:=br,zstd,gzip}"

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

ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime 2>/dev/null || true
echo "${TZ}" > /etc/timezone 2>/dev/null || true

log "PHP ${PHP_VER} | dominio ${DOMAIN} | worker PHP ${PHP_CONCURRENCY} | memoria ${PHP_MEM_LIMIT}"

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
if [ "${XMLRPC_ENABLED}" = "1" ]; then
    XMLRPC_DENY='# XMLRPC_ENABLED=1: endpoint attivo, protetto dal solo rate limit.'
else
    XMLRPC_DENY='return 444;'
fi
export XMLRPC_DENY

NGINX_VARS='${DOMAIN} ${WP_ROOT} ${WP_BASE} ${PHP_UPLOAD_LIMIT} ${PHP_MAX_EXECUTION_TIME}
${NGINX_WORKER_CONNECTIONS} ${LIMIT_CONN_PER_IP} ${RATE_LIMIT_LOGIN} ${RATE_LIMIT_LOGIN_BURST}
${RATE_LIMIT_XMLRPC} ${RATE_LIMIT_XMLRPC_BURST} ${RATE_LIMIT_API} ${RATE_LIMIT_API_BURST}
${XMLRPC_DENY} ${CONVERTED_DIR} ${FIREWALL_BYPASS_COOKIE}
${GZIP_LEVEL} ${BROTLI_LEVEL} ${ZSTD_LEVEL} ${COMPRESSION_MIN_LENGTH}'

export DOMAIN WP_ROOT NGINX_WORKER_CONNECTIONS LIMIT_CONN_PER_IP \
       RATE_LIMIT_LOGIN RATE_LIMIT_LOGIN_BURST RATE_LIMIT_XMLRPC RATE_LIMIT_XMLRPC_BURST \
       RATE_LIMIT_API RATE_LIMIT_API_BURST CONVERTED_DIR FIREWALL_BYPASS_COOKIE \
       GZIP_LEVEL BROTLI_LEVEL ZSTD_LEVEL COMPRESSION_MIN_LENGTH

mkdir -p /etc/nginx/conf.d
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

if [ "${FIREWALL_ENABLED}" = "1" ]; then
    envsubst "${NGINX_VARS}" < /etc/nginx/templates/firewall-8g.conf.template \
        > /etc/nginx/snippets/firewall-8g.conf
    if [ "${FIREWALL_BYPASS_COOKIE}" = "wpfw-bypass-CAMBIAMI" ]; then
        warn "FIREWALL_BYPASS_COOKIE e' ancora il valore di esempio: cambialo nel .env."
    fi
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

# wp-config.php non deve mai essere leggibile da altri utenti del
# container: contiene le credenziali del database.
[ -f "${WP_ROOT}/wp-config.php" ] && chmod 640 "${WP_ROOT}/wp-config.php"

# =======================================================
# 7. Verifica della configurazione
# =======================================================
log "Verifica della configurazione nginx..."
nginx -t

log "Verifica della configurazione PHP-FPM..."
"/usr/sbin/php-fpm${PHP_VER}" -t

# =======================================================
# 8. Avvio
# =======================================================
log "Avvio di nginx + PHP-FPM ${PHP_VER}..."
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
