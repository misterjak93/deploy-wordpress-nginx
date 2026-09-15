# =======================================================
# WordPress su nginx + PHP-FPM (8.3 / 8.4 / 8.5)
# =======================================================
# Base Debian 13 "trixie": porta ImageMagick 7 e libheif recenti nei
# pacchetti di distribuzione, quindi imagick supporta AVIF/HEIC senza
# compilare nulla a mano. Su bookworm sarebbe ImageMagick 6.
ARG DEBIAN_CODENAME=trixie

# =======================================================
# STAGE 1 - Moduli dinamici nginx: Brotli e Zstandard
# =======================================================
# Debian pacchettizza solo Brotli (e non in tutte le release), Zstandard
# mai. Invece di dipendere da quello che c'e' nel repo, i due moduli si
# compilano qui e nell'immagine finale arrivano solo i .so.
#
# Perche' basta "--with-compat": nginx dichiara compatibili fra loro tutti
# i binari costruiti con quel flag. I pacchetti nginx di Debian lo usano
# (e' cosi' che funzionano i loro libnginx-mod-*), quindi un modulo
# compilato qui con il solo --with-compat si carica nel nginx installato
# nello stage finale senza replicare la sua riga di configure.
FROM debian:${DEBIAN_CODENAME}-slim AS nginx-modules

ARG NGX_BROTLI_REF=master
ARG NGX_ZSTD_REF=master
ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential cmake git curl ca-certificates \
        libpcre2-dev zlib1g-dev libssl-dev libzstd-dev; \
    rm -rf /var/lib/apt/lists/*

# La versione di nginx da compilare non e' scelta a mano: si installa lo
# stesso pacchetto dello stage finale e si legge da li'. Cosi' un
# aggiornamento di Debian non lascia i moduli disallineati dal server,
# caso in cui nginx si rifiuta di partire ("module is not binary
# compatible").
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends nginx-core; \
    nginx -v 2>&1 | sed -n 's#.*nginx/##p' > /tmp/nginx.version; \
    echo "nginx di distribuzione: $(cat /tmp/nginx.version)"; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    NGINX_VERSION="$(cat /tmp/nginx.version)"; \
    cd /usr/src; \
    curl -fsSL "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" | tar -xz; \
    git clone --depth=1 --branch "${NGX_BROTLI_REF}" --recurse-submodules --shallow-submodules \
        https://github.com/google/ngx_brotli.git; \
    git clone --depth=1 --branch "${NGX_ZSTD_REF}" \
        https://github.com/tokers/zstd-nginx-module.git

# libbrotli viene compilata statica dentro al modulo: nell'immagine finale
# non serve nessuna libreria brotli a runtime.
RUN set -eux; \
    cd /usr/src/ngx_brotli/deps/brotli; \
    mkdir -p out; cd out; \
    cmake -DCMAKE_BUILD_TYPE=Release \
          -DBUILD_SHARED_LIBS=OFF \
          -DCMAKE_C_FLAGS="-O2 -fPIC" \
          -DCMAKE_CXX_FLAGS="-O2 -fPIC" \
          ..; \
    cmake --build . --config Release --target brotlienc brotlidec brotlicommon -j "$(nproc)"

RUN set -eux; \
    NGINX_VERSION="$(cat /tmp/nginx.version)"; \
    cd "/usr/src/nginx-${NGINX_VERSION}"; \
    ./configure --with-compat \
        --add-dynamic-module=../ngx_brotli \
        --add-dynamic-module=../zstd-nginx-module; \
    make -j "$(nproc)" modules; \
    mkdir -p /out; \
    cp objs/ngx_http_brotli_filter_module.so \
       objs/ngx_http_brotli_static_module.so \
       objs/ngx_http_zstd_filter_module.so \
       objs/ngx_http_zstd_static_module.so \
       /out/; \
    ls -l /out

# =======================================================
# STAGE 2 - Immagine finale
# =======================================================
# Le tre versioni di PHP finiscono TUTTE nell'immagine. Quale viene
# avviata la decide PHP_VERSION a runtime: cambiarla e' un riavvio del
# container, non un rebuild. E' la differenza principale rispetto allo
# stack OpenLiteSpeed, dove PHP_VERSION era anche un build arg.
FROM debian:${DEBIAN_CODENAME}-slim

# Versioni PHP da installare. Sovrascrivibile a build time per snellire
# l'immagine (es. PHP_VERSIONS="8.3") o per aggiungerne una futura.
# Separatore virgola o spazio, indifferentemente.
ARG PHP_VERSIONS="8.3,8.4,8.5"

ENV DEBIAN_FRONTEND=noninteractive \
    BUILD_PHP_VERSIONS="${PHP_VERSIONS}" \
    WP_BASE=/var/www/wordpress \
    WP_ROOT=/var/www/wordpress/html

# -------------------------------------------------------
# 1. Dipendenze di base + repository deb.sury.org
# -------------------------------------------------------
# Debian non pacchettizza 8.4/8.5: arrivano da sury, che e' il repo di
# riferimento (stesso maintainer dei pacchetti php ufficiali Debian).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg unzip zip less procps \
        supervisor gettext-base tzdata openssl mariadb-client \
        libzstd1 libfcgi-bin; \
    install -d -m 0755 /usr/share/keyrings; \
    curl -fsSL https://packages.sury.org/php/apt.gpg -o /usr/share/keyrings/deb.sury.org-php.gpg; \
    . /etc/os-release; \
    echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ ${VERSION_CODENAME} main" \
        > /etc/apt/sources.list.d/php.list; \
    rm -rf /var/lib/apt/lists/*

# -------------------------------------------------------
# 2. nginx + moduli di compressione
# -------------------------------------------------------
# nginx dai pacchetti Debian: e' quello che porta con se' l'ecosistema dei
# moduli dinamici (/etc/nginx/modules-enabled) e le security update della
# distribuzione. Brotli e Zstandard arrivano dallo stage precedente.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends nginx; \
    rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf; \
    rm -rf /var/lib/apt/lists/*

COPY --from=nginx-modules /out/*.so /usr/lib/nginx/modules/

# Verifica che i moduli si carichino davvero: un .so incompatibile deve
# fermare il build, non il primo deploy.
RUN set -eux; \
    printf 'load_module modules/%s;\n' \
        ngx_http_brotli_filter_module.so \
        ngx_http_brotli_static_module.so \
        ngx_http_zstd_filter_module.so \
        ngx_http_zstd_static_module.so \
        > /etc/nginx/modules-enabled/10-compression.conf; \
    nginx -t -c /etc/nginx/nginx.conf

# -------------------------------------------------------
# 3. PHP-FPM
# -------------------------------------------------------
# I pacchetti si dividono in due liste, e la differenza non e' cosmetica.
#
# OBBLIGATORI: se ne manca uno il build si ferma, elencandoli tutti in un
# colpo solo invece di morire sul primo (apt si ferma al primo e non dice
# quanti altri ne mancano).
#
# OPZIONALI: pacchetti che possono non esistere per una certa versione di
# PHP, senza che questo significhi un problema.
#   - opcache: fino a PHP 8.4 e' un pacchetto a se'; da PHP 8.5 sury lo
#     compila STATICAMENTE dentro al binario e "php8.5-opcache" non viene
#     piu' pubblicato. Chiederlo faceva fallire il build con
#     "Unable to locate package". Che OPcache ci sia davvero non e'
#     comunque lasciato al caso: lo verifica lo step 4 interrogando
#     l'interprete, che e' la prova che conta a prescindere da come il
#     pacchettizzatore abbia deciso di distribuirlo.
#   - imagick, igbinary, zstd: per una PHP appena uscita possono non
#     essere ancora ricompilati.
RUN set -eux; \
    REQUIRED="fpm cli common mysql curl gd intl mbstring xml zip bcmath soap redis"; \
    OPTIONAL="opcache imagick igbinary zstd"; \
    apt-get update; \
    for v in $(echo "${PHP_VERSIONS}" | tr ',' ' '); do \
        missing=""; \
        for p in ${REQUIRED}; do \
            apt-cache show "php${v}-${p}" > /dev/null 2>&1 || missing="${missing} php${v}-${p}"; \
        done; \
        if [ -n "${missing}" ]; then \
            echo "ERRORE: PHP ${v} non e' installabile, mancano questi pacchetti nel repository:${missing}"; \
            echo "       Verifica che la versione esista su deb.sury.org per questa release Debian."; \
            exit 1; \
        fi; \
        pkgs=""; \
        for p in ${REQUIRED}; do pkgs="${pkgs} php${v}-${p}"; done; \
        apt-get install -y --no-install-recommends ${pkgs}; \
        for p in ${OPTIONAL}; do \
            if apt-cache show "php${v}-${p}" > /dev/null 2>&1; then \
                apt-get install -y --no-install-recommends "php${v}-${p}"; \
            else \
                echo "NOTA: php${v}-${p} non e' pubblicato per questa versione, si prosegue."; \
            fi; \
        done; \
        rm -f "/etc/php/${v}/fpm/pool.d/www.conf"; \
    done; \
    apt-get install -y --no-install-recommends \
        libheif-plugin-aomenc libheif-plugin-libde265 libheif-plugin-x265 \
        || echo "AVVISO: plugin libheif non disponibili, AVIF/HEIC in scrittura potrebbero mancare."; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# -------------------------------------------------------
# 4. Verifica estensioni
# -------------------------------------------------------
# Meglio un build rosso di un'immagine che parte e sbaglia in silenzio.
RUN set -eux; \
    for v in $(echo "${PHP_VERSIONS}" | tr ',' ' '); do \
        bin="/usr/bin/php${v}"; \
        for ext in redis mysqli curl gd intl mbstring xml zip bcmath; do \
            "$bin" -m | grep -qix "$ext" || { echo "ERRORE: estensione $ext mancante in php${v}"; exit 1; }; \
        done; \
        "$bin" -v | grep -q "OPcache" || { echo "ERRORE: OPcache non disponibile in php${v} (ne' come pacchetto ne' compilato nel binario)"; exit 1; }; \
        if "$bin" -m | grep -qix imagick; then \
            "$bin" -r 'echo "php", PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION, " | imagick ", phpversion("imagick"), " | ", Imagick::getVersion()["versionString"], PHP_EOL;'; \
        else \
            echo "AVVISO: imagick non caricato in php${v} (si usera' GD)."; \
        fi; \
    done

# -------------------------------------------------------
# 5. WP-CLI
# -------------------------------------------------------
# Il wrapper degrada a www-data quando lo si lancia da root: WP-CLI si
# rifiuta di girare come root e, soprattutto, i file creati da un comando
# lanciato come root resterebbero non scrivibili da PHP.
# Il phar viene verificato prima di renderlo eseguibile: e' codice di terzi
# che gira con i permessi di www-data su tutta la docroot, e "l'ho scaricato
# in HTTPS" dice solo da quale host arriva, non che sia quello atteso.
# wp-cli pubblica lo sha512 accanto al file, quindi costa due righe.
RUN set -eux; \
    curl -fsSL -o /usr/local/bin/wp-cli.phar \
        https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar; \
    curl -fsSL -o /tmp/wp-cli.phar.sha512 \
        https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar.sha512; \
    atteso="$(awk '{print $1}' /tmp/wp-cli.phar.sha512)"; \
    ottenuto="$(sha512sum /usr/local/bin/wp-cli.phar | awk '{print $1}')"; \
    if [ -z "${atteso}" ] || [ "${atteso}" != "${ottenuto}" ]; then \
        echo "ERRORE: wp-cli.phar non corrisponde allo sha512 pubblicato."; \
        echo "        atteso:   ${atteso}"; \
        echo "        ottenuto: ${ottenuto}"; \
        exit 1; \
    fi; \
    rm -f /tmp/wp-cli.phar.sha512; \
    chmod +x /usr/local/bin/wp-cli.phar

# -------------------------------------------------------
# 6. Configurazione
# -------------------------------------------------------
COPY nginx/templates/     /etc/nginx/templates/
COPY wordpress/mu-plugins/ /opt/wordpress/mu-plugins/
COPY nginx/snippets/      /etc/nginx/snippets/
COPY php/                 /opt/php-templates/
COPY supervisord.conf     /etc/supervisor/supervisord.conf
COPY scripts/             /usr/local/bin/
COPY entrypoint.sh        /entrypoint.sh

RUN set -eux; \
    chmod +x /entrypoint.sh /usr/local/bin/wp /usr/local/bin/*.sh; \
    mkdir -p /var/www/wordpress/html /var/www/wordpress/logs /run/php /var/lib/nginx \
             /var/cache/nginx/wordpress; \
    chown -R www-data:www-data /var/www/wordpress /run/php /var/cache/nginx

# Impronta della configurazione: i template e gli script nginx vivono
# DENTRO l'immagine, quindi una loro modifica richiede un rebuild. Senza
# un modo per vedere quale versione sta girando, capire se una correzione
# e' arrivata davvero costa un giro di deploy alla cieca - e' gia'
# successo. L'entrypoint stampa questa impronta all'avvio.
RUN cat /etc/nginx/templates/* /etc/nginx/snippets/* /entrypoint.sh \
        /opt/wordpress/mu-plugins/* 2>/dev/null \
    | sha256sum | cut -c1-12 > /etc/stack-config-version

EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD curl -fsS http://127.0.0.1/healthz || exit 1

ENTRYPOINT ["/entrypoint.sh"]
