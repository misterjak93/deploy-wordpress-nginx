# **WordPress Stack: nginx, PHP-FPM, Varnish, Redis, MariaDB**

Stack ad alte prestazioni per Dokploy, pensato per WordPress: cache di pagina in RAM, object cache, compressione moderna (Zstandard, Brotli, gzip), firewall applicativo e supporto a **PHP 8.3, 8.4 e 8.5** commutabili senza rebuild.

È la controparte nginx dello stack OpenLiteSpeed: stessa filosofia (tutto dalla GUI di Dokploy, risorse dimensionabili da variabili d'ambiente), motore diverso.

---

## **🏗 1. Architettura**

```
Internet
   │
   ▼
Traefik ............ TLS, certificati, dominio           (Dokploy)
   │  http
   ▼
Varnish ............ full page cache in RAM              :80
   │  http
   ▼
nginx .............. statici, compressione, firewall     :80
   │  fastcgi (socket unix)
   ▼
PHP-FPM ............ 8.3 / 8.4 / 8.5
   │
   ├──▶ MariaDB ..... dati
   └──▶ Redis ....... object cache
```

Tre decisioni che spiegano il resto della configurazione:

**Il dominio pubblico punta su `varnish`, non su `wordpress`.** Il container `wordpress` non è sulla rete `dokploy-network`: non è raggiungibile da fuori, quindi non esiste un modo per scavalcare la cache per sbaglio.

**nginx e PHP-FPM stanno nello stesso container.** Parlano su socket unix invece che in TCP, condividono la docroot senza volumi incrociati e si riavviano insieme quando cambia la versione di PHP. Il prezzo è un supervisore (`supervisord`), necessario perché un container non si accorgerebbe da solo della morte di uno dei due processi.

**Varnish non termina TLS e non deve.** Lo fa Traefik, che passa a Varnish la richiesta in chiaro sulla rete interna insieme a `X-Forwarded-Proto`. nginx ricostruisce da lì `$_SERVER['HTTPS']` per PHP, così in `wp-config.php` non serve il solito blocco sul reverse proxy.

---

## **📊 2. Profili risorse**

Valori di riferimento per la tab **Environment** di Dokploy, su una VPS da 4 GB.

| **Parametro** | **VETRINA** | **BLOG** | **ECOMMERCE** |
| --- | --- | --- | --- |
| `WP_MEM_LIMIT` | 512M | 1024M | 1536M |
| `PHP_MEM_LIMIT` | 256M | 384M | 512M |
| `PHP_CONCURRENCY` | 5 | 15 | 30 |
| `OPCACHE_MEMORY` | 128 | 192 | 256 |
| `VARNISH_SIZE` | 128m | 256m | 512m |
| `VARNISH_MEM_LIMIT` | 256M | 512M | 1024M |
| `DB_MEM_LIMIT` | 512M | 768M | 1024M |
| `DB_BUFFER_POOL` | 128M | 256M | 512M |
| `DB_CONNECTIONS` | 50 | 150 | 250 |
| `REDIS_MEM_LIMIT` | 64mb | 128mb | 256mb |

Il vincolo da rispettare è uno solo:

> `PHP_CONCURRENCY` × `PHP_MEM_LIMIT` deve stare **sotto** `WP_MEM_LIMIT`.

Se lo si supera, sotto carico l'OOM killer termina i worker nel mezzo delle richieste, e nei log si vede un 502 senza alcun errore PHP che lo spieghi.

Con Varnish davanti, `PHP_CONCURRENCY` può stare molto più basso che in uno stack senza cache di pagina: a PHP arrivano solo i MISS e le richieste degli utenti loggati.

---

## **🌐 3. Domini su Dokploy**

Tab **Domains** del progetto. Nessun file di configurazione da toccare.

| **Cosa** | **Service Name** | **Port** | **Dominio** |
| --- | --- | --- | --- |
| Sito WordPress | `varnish` | 80 | `tuosito.com` |
| Adminer (database) | `adminer` | 8080 | `db.tuosito.com` |
| FileBrowser (file) | `files` | 8080 | `files.tuosito.com` |

Su tutti: **HTTPS ✅ + Automatic SSL**.

⚠️ Il sito va su **`varnish`**. Puntandolo su `wordpress` il deploy fallisce, perché quel container non è sulla rete di Traefik — ed è voluto: è ciò che impedisce di servire traffico bypassando la cache.

Serve un accesso diretto per diagnosi? Aggiungi `dokploy-network` alle reti del servizio `wordpress` e un dominio dedicato, sapendo che quelle richieste saltano Varnish.

---

## **🐘 4. PHP 8.3 / 8.4 / 8.5**

```
PHP_VERSION=8.4
```

**Cambiare versione è un riavvio del container, non un rebuild.** L'immagine contiene tutte e tre le versioni, ciascuna con il suo set di estensioni; l'entrypoint avvia il `php-fpm` corrispondente e allinea `/usr/bin/php` (quindi anche WP-CLI usa la stessa versione che serve le pagine).

È la differenza principale rispetto allo stack OpenLiteSpeed, dove `PHP_VERSION` era anche un argomento di build e cambiarla imponeva un redeploy completo.

Si accettano sia `8.4` sia `84`. Una versione non presente nell'immagine ferma l'avvio con un messaggio esplicito, invece di partire mal configurata.

### **Ridurre il peso dell'immagine**

```
PHP_VERSIONS=8.3,8.4      # questo sì, richiede rebuild
```

Ogni versione pesa qualche centinaio di MB. Se non ti serve commutare, installane una sola.

Separate da **virgola**: il valore attraversa il `.env`, il parser di Compose e la riscrittura che Dokploy fa del file per iniettare le label Traefik, e uno spazio ha più occasioni di perdersi per strada. Lo spazio funziona comunque.

L'entrypoint non ha una lista di versioni ammesse scritta a mano: accetta qualunque `X.Y` e controlla se il binario esiste davvero nell'immagine, elencando quelli presenti se non lo trova. Aggiungere una versione futura è quindi solo questione di metterla in `PHP_VERSIONS`.

Vale però la pena verificarlo prima di provarci. `deb.sury.org` pubblica già **8.6**, ma al momento senza `php8.6-redis`, che per questo stack è obbligatorio: il build si ferma dicendo esattamente quello.

```
ERRORE: PHP 8.6 non è installabile, mancano questi pacchetti nel repository: php8.6-redis
```

### **Estensioni**

Da `deb.sury.org`, il repository di riferimento (stesso maintainer dei pacchetti php ufficiali Debian): `mysqli`, `curl`, `gd`, `intl`, `mbstring`, `xml`, `zip`, `bcmath`, `soap`, `opcache`, `redis`, più `imagick` e `igbinary` quando disponibili.

Il build **verifica** che le estensioni obbligatorie siano caricate in ogni interprete: se una manca, fallisce il build invece di produrre un'immagine rotta in silenzio. `imagick` e `igbinary` sono trattate come opzionali, perché per una PHP appena uscita possono non essere ancora pubblicate; in quel caso l'entrypoint lo segnala all'avvio.

### **OPcache: un pacchetto che da 8.5 non esiste più**

Fino a PHP 8.4, OPcache arriva dal pacchetto `phpX.Y-opcache`. **Da PHP 8.5 sury lo compila staticamente dentro al binario** e quel pacchetto non viene più pubblicato: chiederlo fa fallire il build con `Unable to locate package php8.5-opcache`.

Per questo il pacchetto sta fra gli opzionali, mentre OPcache resta obbligatorio come *capacità*: lo step di verifica del build interroga l'interprete (`php -v`), che è la prova che conta a prescindere da come il pacchettizzatore abbia deciso di distribuirlo. Se un domani OPcache tornasse pacchetto separato, o sparisse davvero, il build se ne accorge in entrambi i casi.

Se una versione di PHP non è installabile, il build elenca **tutti** i pacchetti mancanti in una volta invece di fermarsi al primo, che è l'unico che `apt` mostrerebbe.

### **JIT**

```
OPCACHE_JIT=disable
```

Default spento, e non per prudenza generica: su WordPress il collo di bottiglia sono query e I/O, non il calcolo, quindi il guadagno è vicino a zero mentre la superficie di bug non lo è. Se fai elaborazione numerica pesante: `OPCACHE_JIT=tracing` con `OPCACHE_JIT_BUFFER=64M`.

---

## **⚡ 5. Varnish (cache di pagina)**

Una pagina in HIT esce in pochi millisecondi senza svegliare né PHP né il database. È il singolo componente che sposta di più il tempo di risposta.

### **Cosa non viene mai messo in cache**

- `/wp-admin`, `wp-login.php`, `wp-cron.php`, `xmlrpc.php`
- richieste con cookie di sessione (`wordpress_logged_in_`, `wp-postpass_`, `comment_author_`, carrello WooCommerce/EDD)
- richieste con `Authorization` o `X-WP-Nonce`
- anteprime, customizer, `?wc-ajax=`, `?add-to-cart=`
- `/cart`, `/checkout`, `/my-account` (e gli equivalenti italiani)
- media pesanti: video, audio, archivi, PDF — un solo file da 200 MB sfratterebbe migliaia di pagine HTML, e nginx li serve comunque con `sendfile`

### **La RAM è riservata al pubblico**

Le prime due voci della lista non sono una semplice esclusione: chi ha
una sessione WordPress aperta **esce dalla catena alla prima riga utile
del VCL**, prima di qualunque normalizzazione, lookup o chiave di cache.
Varnish per lui è un tubo, e in RAM non resta niente — nemmeno un
hit-for-miss, nemmeno per i duecento `.css` e `.js` che l'editor a
blocchi richiede all'apertura.

È una decisione di bilancio. La cache di Varnish è la risorsa più cara
dello stack e le pagine di un amministratore non potrebbero comunque
essere condivise con nessun altro: ogni byte speso per loro è sottratto
alle pagine che i visitatori vedono davvero.

Per l'area di amministrazione il livello di cache è **nginx**, e basta:
la sua sta su disco, dove lo spazio non è prezioso, e gli asset di
`wp-admin` li serve con `sendfile` e `open_file_cache` senza mai
svegliare PHP. Sotto, OPcache e l'object cache Redis — che per una
bacheca sono i due livelli che contano davvero.

Per il visitatore anonimo invece **non cambia nulla**: Varnish, poi
nginx, poi PHP.

Si legge dalla risposta: le richieste amministrative escono con
`X-Cache: BYPASS`, distinto da `MISS` (cercata in cache e non trovata).

```bash
curl -sI https://tuosito.com/wp-admin/ | grep -i x-cache
# X-Cache: BYPASS
```

### **Cosa viene normalizzato prima della cache**

Tre normalizzazioni che decidono l'hit rate reale:

| **Cosa** | **Perché** |
| --- | --- |
| Cookie di analytics (`_ga`, `_fbp`, `_hj*`, consensi…) | Rimossi. Sono la ragione numero uno per cui una cache di pagina "non prende mai": basta un `_ga` per rendere ogni visitatore unico. |
| Parametri di tracciamento (`utm_*`, `gclid`, `fbclid`…) | Rimossi dall'URL. Non cambiano la pagina servita, ma cambiano la chiave di cache: ogni campagna creerebbe una copia della stessa homepage. |
| `Accept-Encoding` e `Accept` | Ridotti a pochi valori canonici. Vedi la sezione 6. |

`Vary: User-Agent`, se un tema o un plugin lo aggiunge, viene rimosso: le varianti di user agent sono praticamente infinite e quell'header da solo annulla qualunque cache.

### **Grace: il sito resta in piedi se PHP cade**

```
VARNISH_GRACE=24h
```

Per 24 ore dopo la scadenza Varnish continua a servire la copia vecchia mentre ne richiede una nuova in background. Due effetti:

- nessun visitatore aspetta mai la rigenerazione di una pagina;
- se il backend smette di rispondere, il sito resta navigabile in sola lettura invece di dare 503.

### **Invalidare la cache**

Installa **Proxy Cache Purge** (Mika Epstein). `wp-config.php` contiene già:

```php
define( 'VHP_VARNISH_IP', 'varnish' );
```

Senza questa define il plugin manderebbe i `PURGE` all'URL pubblico, quindi attraverso Traefik, e verrebbero **rifiutati**.

Il motivo è nel VCL e vale la pena capirlo: l'ACL sulle reti private da sola non basterebbe, perché le richieste che arrivano da Traefik hanno come IP sorgente proprio Traefik, che sta in `172.16.0.0/12`. Chiunque da Internet potrebbe mandare un PURGE e superare l'ACL. Il discriminante vero è `X-Forwarded-For`: Varnish accoda sempre l'IP del chiamante all'header in arrivo, quindi una chiamata interna (`wordpress` → `varnish`) ne produce uno con **un solo** indirizzo, una passata da Traefik ne ha **almeno due**, separati da virgola. Se c'è una virgola, la richiesta viene da fuori e viene respinta.

A mano, dal terminale del servizio **varnish**:

```bash
# Svuotare tutto
varnishadm 'ban req.url ~ .'

# Solo una sezione
varnishadm 'ban req.url ~ ^/blog/'

# Statistiche: hit rate, oggetti, memoria
varnishstat -1 | grep -E 'cache_hit|cache_miss|n_object'

# Richieste in tempo reale
varnishlog -g request -q 'ReqURL ~ "/"'
```

### **Perché l'HTML esce con `max-age=0`**

Varnish imposta `Cache-Control: public, max-age=0, s-maxage=0, must-revalidate` sull'HTML. Non è una svista: la cache condivisa è Varnish, ed è l'unica che sappiamo invalidare. Se l'HTML restasse anche nel browser, un articolo corretto resterebbe vecchio per ore su quel dispositivo e nessun purge potrebbe raggiungerlo.

Gli asset statici, che sono versionati da WordPress via `?ver=`, escono invece con un anno di `immutable`.

---

## **🗜 6. Compressione: Zstandard, Brotli, gzip**

Tutte e tre attive insieme. Il browser dichiara cosa accetta, nginx risponde con la migliore che entrambi conoscono.

| **Codifica** | **Modulo** | **Quando viene usata** |
| --- | --- | --- |
| Zstandard | `zstd-nginx-module` (compilato) | Chrome/Edge 123+, Firefox 126+ |
| Brotli | `ngx_brotli` (compilato) | Praticamente ogni browser in circolazione |
| gzip | integrato in nginx | Tutto il resto, e i client vecchi |

I due moduli non stanno nei pacchetti Debian (Brotli non in tutte le release, Zstandard mai): vengono compilati in uno stage dedicato del Dockerfile e nell'immagine finale arrivano solo i `.so`. Basta `--with-compat` perché nginx dichiara compatibili fra loro tutti i binari costruiti con quel flag, e i pacchetti nginx di Debian lo usano.

### **La parte che è facile sbagliare**

Ogni risposta compressa esce con `Vary: Accept-Encoding`. Varnish tiene quindi **una copia in cache per ogni valore distinto di quell'header** — e `Accept-Encoding` nel mondo reale ha decine di varianti testuali (`gzip, deflate, br, zstd`, `br;q=1.0, gzip;q=0.8`, …) che esprimono la stessa identica capacità.

Senza contromisure, la stessa homepage occuperebbe la cache decine di volte e l'hit rate crollerebbe.

Le contromisure sono due, e sono entrambe necessarie:

**1. Varnish normalizza `Accept-Encoding`** al primo formato di `COMPRESSION_PRIORITY` che il client dichiara di accettare. Le varianti possibili scendono da decine a un massimo di quattro.

**2. `http_gzip_support=off`.** È la scelta chiave di tutto lo stack. Acceso (il default), Varnish riscrive `Accept-Encoding` a `gzip` su ogni richiesta al backend: nginx non vedrebbe mai `br` né `zstd` e non li produrrebbe per nessuno. Spegnendolo, Varnish smette di interpretare le codifiche e si limita a conservare, per ogni variante, l'oggetto che nginx ha prodotto.

### **Scegliere l'ordine**

```
COMPRESSION_PRIORITY=br,zstd,gzip
```

| **Valore** | **Effetto** |
| --- | --- |
| `br,zstd,gzip` (default) | Miglior rapporto di compressione, supporto più ampio |
| `zstd,br,gzip` | Decompressione molto più rapida lato client. Su mobile di fascia bassa quel tempo entra dritto nel Largest Contentful Paint |
| `gzip` | Una sola variante in cache, consumo minimo di RAM |

### **Un avviso che conviene leggere nei log**

`COMPRESSION_PRIORITY` è letta da **Varnish**, che gira in un altro container e non può sapere cosa nginx sappia produrre. Se chiede una codifica che nginx non ha, normalizzerà `Accept-Encoding` su quella e i browser che la annunciano riceveranno risposte **non compresse** — peggio che non avere affatto `br` o `zstd`.

Per questo l'entrypoint stampa all'avvio quali codifiche sono realmente attive e avvisa se `COMPRESSION_PRIORITY` ne chiede una mancante:

```
[wp] Compressione attiva: zstd, br, gzip
```

nginx emette le direttive di un modulo **solo se il modulo è caricato**: scrivere `brotli on` senza il modulo non degraderebbe la compressione, farebbe fallire nginx all'avvio con `unknown directive`, cioè sito giù.

### **Livelli**

```
GZIP_LEVEL=6     BROTLI_LEVEL=5     ZSTD_LEVEL=6
COMPRESSION_MIN_LENGTH=256
```

Alzarli fa risparmiare byte e costare CPU. Per i file statici il risultato finisce in cache e si paga una volta sola; per l'HTML si paga ad ogni MISS. Brotli 11 su HTML dinamico è quasi sempre un cattivo affare.

`*_static on` è attivo per tutte e tre: se un plugin di ottimizzazione ha già prodotto il gemello `.gz`/`.br`/`.zst`, nginx serve quello senza ricomprimere.

### **`zlib.output_compression` resta Off**

Se PHP comprimesse in proprio, nginx riceverebbe un corpo già codificato e perderebbe la negoziazione: nessun Brotli per chi lo accetta, nessun controllo sul livello, rischio di doppia compressione.

---

## **🧊 6-bis. Cache a due livelli**

```
Traefik ─▶ Varnish ─▶ nginx ─▶ PHP-FPM
           (RAM)      (SSD)
           TTL 1h     TTL 30gg
```

I due livelli non sono ridondanti: hanno difetti opposti.

| | Varnish | nginx FastCGI |
| --- | --- | --- |
| Dove | RAM | SSD |
| Capienza | centinaia di MB | gigabyte |
| Sopravvive al riavvio | **no** | **sì** |
| Velocità (misurata) | 75.000 req/s | 12.600 req/s |

Varnish è cinque volte più veloce, ma quando il suo container riparte la
cache è vuota e tutto il traffico piomba su PHP nello stesso istante.
nginx assorbe quei MISS: PHP viene interpellato solo quando la pagina
manca in **entrambi**.

Ogni risposta dichiara l'esito dei due livelli:

```bash
curl -sI https://tuosito.com/ | grep -i 'x-cache\|x-nginx-cache\|x-wp-cache-reason'
```

`X-Cache` è Varnish, `X-Nginx-Cache` il livello su disco, e
`X-WP-Cache-Reason` dice **perché** una pagina non è stata memorizzata —
la domanda più frequente quando una cache "non prende".

`X-Cache` ha tre valori: `HIT`, `MISS` (cercata e non trovata) e
`BYPASS` (richiesta amministrativa, Varnish non ha nemmeno guardato).
Su una sessione loggata il primo livello è quindi sempre `BYPASS`: la
RAM è riservata al traffico anonimo, e per la bacheca il livello di
cache è nginx.

### **Il plugin Stack Cache**

Installato come must-use plugin dall'entrypoint: fa parte
dell'infrastruttura e non è disattivabile per errore dalla bacheca.

I due livelli sono ciechi — vedono header e cookie, non sanno se una
pagina è un articolo appena pubblicato o il carrello di qualcuno.
WordPress lo sa. Il plugin traduce quella conoscenza in istruzioni che i
due livelli capiscono nativamente:

| Destinatario | Header | Effetto |
| --- | --- | --- |
| nginx | `X-Accel-Expires` | supportato nativamente, vince su `Cache-Control` |
| Varnish | `X-WP-Varnish-TTL` | letto in `vcl_backend_response` |

Nessuno dei due esce mai verso il visitatore.

Dalla voce **Cache** in bacheca: stato dei quattro livelli, svuotamento
singolo o totale, invalidazione di un indirizzo, TTL separati per i due
livelli, automazioni sugli eventi di WordPress e preload.

### **Utenti loggati**

Tre strati indipendenti concordano nel non servire mai una pagina
personale a un estraneo: il VCL di Varnish, le mappe `$cache_skip` di
nginx e il plugin, che manda TTL zero. Basta un cookie di sessione, un
header `Authorization` o un nonce REST.

I tre concordano sulla regola ma non sul ruolo. Varnish quelle richieste
non le guarda nemmeno: escono in cima al VCL con `X-Cache: BYPASS`, così
la RAM resta tutta al traffico anonimo. nginx invece le riceve tutte,
perché è lui a servire l'area di amministrazione — fuori dalla cache di
pagina, ma con `sendfile` sugli asset e OPcache più Redis sotto.

I cookie di analytics (`_ga`, `_fbp`, consensi) sono invece **ignorati**:
sono la ragione numero uno per cui una cache di pagina "non prende mai".

### **Preload**

Dopo un'invalidazione le pagine vengono richieste in sottofondo, così il
primo visitatore trova la cache già piena. Gli indirizzi arrivano dalla
sitemap di WordPress, e le richieste vanno a `127.0.0.1` — cioè a nginx
nello stesso container: non dipendono da DNS, Traefik o certificato.

## **🖼 7. Immagini: AVIF e WebP**

nginx serve automaticamente la variante moderna quando il browser la accetta, senza plugin lato PHP nel percorso della richiesta:

```
Accept: image/avif,...  →  /wp-content/compressx-nextgen/foto.jpg.avif
Accept: image/webp,...  →  /wp-content/compressx-nextgen/foto.jpg.webp
altrimenti              →  /wp-content/foto.jpg
```

La cartella si configura in base al plugin di conversione:

| **Plugin** | **`CONVERTED_DIR`** |
| --- | --- |
| CompressX | `compressx-nextgen` |
| WebP Express | `webp-express/webp-images/doc-root/wp-content` |

La risposta esce con `Vary: Accept`, obbligatorio: senza, Varnish (o una CDN a monte) servirebbe l'AVIF anche a chi non sa leggerlo. Per non frammentare la cache, Varnish riduce `Accept` a tre soli valori sulle richieste di immagini, esattamente come fa con `Accept-Encoding`.

`imagick` è compilato contro ImageMagick 7 con i plugin libheif (`aomenc`, `libde265`, `x265`), quindi AVIF e HEIC funzionano in lettura e scrittura anche per le conversioni fatte da WordPress.

Verifica dal terminale del servizio **wordpress**:

```bash
php -r 'echo Imagick::getVersion()["versionString"], PHP_EOL;'
php -r 'print_r(array_intersect(["WEBP","AVIF","HEIC"], Imagick::queryFormats()));'
```

---

## **🔒 8. Sicurezza**

### **Firewall applicativo**

Ispirato al firewall 8G di Jeff Starr, ma riscritto per nginx con `map` invece che come `.htaccess`. **Non è una traduzione riga per riga**, e le differenze sono deliberate: 8G nasce per Apache e alcune sue regole, portate così come sono su un WordPress moderno, bloccano traffico legittimo.

| **Regola 8G** | **Qui** | **Perché** |
| --- | --- | --- |
| `+select+` nella query string | Sostituita da pattern con sintassi SQL vera (`union … select`, `' or 1=1`, `sleep(`) | `?s=come+select+un+piano` è una ricerca interna legittima |
| Schemi `http`/`https` nella query | Solo `ftp`, `php`, `inurl`, `expect`, `dict`, `gopher` | Bloccarli romperebbe il `redirect_to` di `wp-login.php` |
| `curl` e `wget` fra gli user agent vietati | Ammessi | Li usano healthcheck, webhook e integrazioni |
| Archivi (`.zip`, `.gz`) bloccati per estensione | Ammessi | Molti siti distribuiscono file dalla cartella uploads |

Copre query string, percorso, user agent, referer, metodo HTTP e cookie. Le richieste bloccate ricevono **444**: connessione chiusa senza risposta, che a differenza di un 403 non conferma allo scanner che il target esiste e non consuma banda.

```
FIREWALL_ENABLED=1
```

### **Cookie di bypass**

Se il firewall ti blocca mentre usi un page builder o un plugin di import:

```js
document.cookie = "IL-TUO-VALORE=1; path=/; SameSite=Lax; Secure";
```

⚠️ **Cambia `FIREWALL_BYPASS_COOKIE`.** Con il valore di esempio chiunque lo conosca aggira i controlli. L'entrypoint lo segnala nei log finché resta quello di default.

### **Hardening dei percorsi**

- **PHP non eseguibile in `uploads`, `cache`, `upgrade`.** È la singola regola che trasforma "upload arbitrario" in "nessuna conseguenza".
- Dotfile (`.git`, `.env`, `.htaccess`, `.DS_Store`) → 404, con eccezione per `.well-known`.
- `wp-config.php`, `readme.html`, `license.txt`, `debug.log` → 404.
- File sorgente e di build (`.sql`, `.bak`, `.log`, `.ini`, `composer.json`, `package.json`…) → 404.
- **Enumerazione utenti chiusa** su entrambe le vie: `/?author=1` → 403, `/wp-json/wp/v2/users` → 401 per gli anonimi (chi è loggato passa, al pannello serve).

### **Installer**

```
WP_INSTALL_ACCESS=auto
```

`/wp-admin/install.php` e `/wp-admin/setup-config.php` su un sito installato vanno chiusi: sono la porta d'ingresso di chi trova un sito con il database vuoto e ci ripunta WordPress su un database proprio, diventando amministratore. Ma finché il sito **non** è installato sono l'unica strada per installarlo dal browser.

Con `auto` (default) l'entrypoint decide ad ogni avvio guardando lo stato reale: `install.php` è raggiungibile finché le tabelle non esistono, `setup-config.php` finché manca `wp-config.php`. Appena il sito è installato, il riavvio successivo li richiude — e nel frattempo `install.php` risponde comunque "Già installato" senza toccare nulla. L'installer sta sotto lo stesso rate limit di `wp-login.php`.

`deny` li chiude sempre (installazione solo da CLI, `wp core install`), `open` li lascia sempre raggiungibili.

### **XML-RPC**

```
XMLRPC_ENABLED=0
```

Chiuso per default. È la superficie preferita per il brute force amplificato: `system.multicall` prova centinaia di password in una sola richiesta. Mettilo a `1` solo se usi Jetpack o l'app mobile — resta comunque sotto rate limit.

### **Rate limit**

| **Variabile** | **Default** | **Su cosa** |
| --- | --- | --- |
| `RATE_LIMIT_LOGIN` | 20/min per IP | `wp-login.php` |
| `RATE_LIMIT_XMLRPC` | 10/min per IP | `xmlrpc.php` |
| `RATE_LIMIT_API` | 20/s per IP | `/wp-json/` |
| `LIMIT_CONN_PER_IP` | 40 | Connessioni contemporanee |

Il limite sulle connessioni rende costoso lo slowloris senza dare fastidio a un browser reale.

### **PHP: funzioni disabilitate solo sul web**

`exec`, `shell_exec`, `system`, `proc_open`, `popen` e affini sono spente **nelle richieste web ma non nella CLI**. È il punto: WP-CLI ha bisogno di `proc_open` per metà dei suoi comandi, quindi la lista vive nel pool FPM e non in un `.ini` condiviso.

Per sovrascriverla: `PHP_DISABLE_FUNCTIONS=...` (vuoto = lista di default).

### **Header**

`X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, `Permissions-Policy`, `Cross-Origin-Opener-Policy`, `Cross-Origin-Resource-Policy` su ogni risposta, comprese le pagine di errore.

`Strict-Transport-Security` solo quando la richiesta è arrivata in HTTPS al bordo — con valore vuoto nginx non emette affatto l'header, così le chiamate interne in HTTP (healthcheck, purge) non se lo portano dietro.

`X-XSS-Protection` è **deliberatamente assente**: l'auditor XSS dei browser è stato rimosso anni fa e l'header, dove ancora interpretato, ha introdotto vulnerabilità proprie.

**Content-Security-Policy non c'è**, ed è una scelta: una CSP sensata dipende dal tema e dai plugin installati, e una generica o blocca il sito o non protegge. Quando il sito è stabile, aggiungila in `nginx/snippets/security-headers.conf`.

### **Hardening in `wp-config.php`**

Scritte alla prima installazione:

```php
define( 'DISALLOW_FILE_EDIT', true );   // niente editor di temi/plugin dal pannello
define( 'WP_AUTO_UPDATE_CORE', 'minor' );
define( 'WP_HOME',    'https://tuosito.com' );
define( 'WP_SITEURL', 'https://tuosito.com' );
```

`DISALLOW_FILE_EDIT` toglie di mezzo l'editor del pannello, che trasforma un account amministratore rubato in esecuzione di codice arbitrario. Gli URL fissi evitano il redirect loop dietro reverse proxy e impediscono di avvelenare l'URL del sito via header `Host`.

---

## **🧠 9. Redis (object cache)**

Installa **Redis Object Cache** e attivalo:

```bash
wp plugin install redis-cache --activate
wp redis enable
wp redis status
```

`wp-config.php` contiene già host, porta, prefisso (il dominio, così più installazioni possono condividere lo stesso Redis) e timeout.

```
REDIS_PASSWORD=          # vuoto = nessuna autenticazione
```

Redis è sulla sola rete interna, ma valorizzarla è consigliato: la define corrispondente finisce in `wp-config.php` alla prima installazione.

`maxmemory-policy` è `allkeys-lru`: quando la memoria finisce, Redis butta le chiavi usate meno di recente invece di rispondere errore. Per una cache è il comportamento giusto; per un datastore non lo sarebbe.

---

## **⏰ 10. Cron**

Il cron interno di WordPress è disattivato (`DISABLE_WP_CRON`) e sostituito da un loop gestito da `supervisord`.

Non è una preferenza estetica: il cron interno parte **dentro a una richiesta del visitatore**, e con Varnish davanti le richieste che arrivano fino a PHP sono poche e irregolari. I job programmati — pubblicazioni differite, backup, email — non partirebbero con regolarità.

```
WP_CRON_ENABLED=true
WP_CRON_INTERVAL=60
```

---

## **🔌 11. Plugin consigliati**

| **Plugin** | **A cosa serve** |
| --- | --- |
| Redis Object Cache | Attiva l'object cache. Senza, Redis resta inutilizzato |
| Proxy Cache Purge | Invalida Varnish quando pubblichi o modifichi |
| CompressX (o WebP Express) | Genera le varianti AVIF/WebP che nginx serve |

Da evitare: plugin di **cache di pagina** (WP Rocket page cache, W3TC, LiteSpeed Cache). Quel lavoro lo fa Varnish, e due cache di pagina in serie producono invalidazioni incoerenti.

---

## **⚙️ 12. Environment**

Copia `.env.example` e personalizzalo. Le variabili sono raggruppate per area e ognuna ha il suo commento; qui solo quelle che vanno assolutamente toccate:

| **Variabile** | **Nota** |
| --- | --- |
| `DOMAIN` | Senza `https://` |
| `ADMIN_EMAIL` | |
| `DB_PASS`, `DB_ROOT_PASS` | |
| `FB_ADMIN_PASSWORD` | Se resta vuota, FileBrowser parte con admin **senza password** |
| `FIREWALL_BYPASS_COOKIE` | Cambia il valore di esempio |

⚠️ Una variabile che non compare nella sezione `environment:` del servizio in `docker-compose.yml` **non arriva al container**, per quanto accuratamente sia impostata nel `.env`. Se aggiungi un knob tuo, aggiungilo in entrambi i posti.

---

## **🛠 13. Troubleshooting**

### **Verificare che la cache funzioni**

```bash
curl -sI https://tuosito.com/ | grep -i x-cache
```

`X-Cache: HIT` con `X-Cache-Hits` crescente. Se resta sempre `MISS`:

- sei loggato — la sessione esclude dalla cache, è corretto; prova in finestra anonima;
- un plugin manda `Set-Cookie` su ogni risposta: una risposta che imposta cookie non viene cachata, perché è quasi sempre personale;
- un plugin manda `Cache-Control: no-cache`: Varnish lo rispetta.

Per capire quale: `varnishlog -g request -q 'ReqURL eq "/"'` dal terminale di **varnish**.

### **Verificare la compressione**

```bash
curl -sI -H 'Accept-Encoding: zstd, br, gzip' https://tuosito.com/ | grep -i content-encoding
curl -sI -H 'Accept-Encoding: br' https://tuosito.com/wp-includes/css/dashicons.min.css | grep -i content-encoding
```

Se manca del tutto:

- risposta sotto `COMPRESSION_MIN_LENGTH` (256 byte): è voluto;
- il MIME della risposta non è nella lista dei tipi comprimibili;
- `COMPRESSION_PRIORITY` chiede una codifica che nginx non produce — **guarda la riga `Compressione attiva:` nei log di avvio del servizio wordpress**.

### **503 dopo aver riavviato il solo servizio `wordpress`**

Varnish risolve il nome del backend **quando compila il VCL**, non ad ogni richiesta. Se il container `wordpress` viene ricreato e prende un IP diverso, Varnish continua a puntare al vecchio.

Il probe se ne accorge e serve le pagine in grace, quindi il sito resta navigabile, ma i MISS falliscono. Soluzione: **riavvia anche `varnish`**. Un redeploy completo da Dokploy ricrea entrambi e il problema non si presenta.

### **502 sul sito**

PHP-FPM non risponde. Dal terminale di **wordpress**:

```bash
supervisorctl status
curl -s http://127.0.0.1/php-fpm-status
tail -n 50 /var/www/wordpress/logs/php-fpm-slow.log
```

`php-fpm-status` dice quanti worker sono attivi e quanti in coda: se `listen queue` è costantemente sopra zero, `PHP_CONCURRENCY` è troppo basso.

### **Richieste lente**

`request_slowlog_timeout` è a 10s: oltre quella soglia la richiesta finisce in `logs/php-fpm-slow.log` **con lo stack PHP completo**, cioè con il nome della funzione che sta bloccando — informazione che il log di nginx non può avere.

Per le query: `slow_query_log` è attivo su MariaDB con soglia 2s, in `/var/lib/mysql/slow.log`. È il posto dove si scopre quale plugin sta facendo la scansione completa di `wp_postmeta`.

### **Comandi WP-CLI**

Dal terminale del servizio **wordpress**, da qualunque cartella:

```bash
wp plugin list
wp core update
wp search-replace 'http://vecchio.it' 'https://nuovo.it' --all-tables
```

Il wrapper scende da solo a `www-data` e si posiziona sulla docroot. WP-CLI da root si rifiuterebbe di partire, e i file creati resterebbero non scrivibili da PHP.

### **Permessi**

```
FIX_PERMISSIONS=1
```

Ad ogni avvio normalizza proprietario e permessi di tutta la docroot. Costa secondi su un sito grande: tienilo a `0` e alzalo solo dopo un ripristino da backup. A mano:

```bash
chown -R www-data:www-data /var/www/wordpress/html
```

### **Ripristinare un sito esistente**

```
WP_AUTO_INSTALL=0
```

Impedisce all'entrypoint di scaricare WordPress e generare `wp-config.php`. Carica i file con FileBrowser e il dump con Adminer, poi riporta `FIX_PERMISSIONS=1` per un avvio.

### **Password admin di FileBrowser**

Cambiala in `FB_ADMIN_PASSWORD` e riavvia il servizio `files`. Viene riapplicata ad ogni avvio: la fonte di verità è la variabile, non l'interfaccia web, quindi una password cambiata dalla UI viene sovrascritta al riavvio successivo.

### **Build fallito compilando i moduli nginx**

Lo stage `nginx-modules` installa lo stesso pacchetto nginx dello stage finale e legge la versione da lì, poi scarica i sorgenti corrispondenti da `nginx.org`. Se quella versione esatta non è più pubblicata (succede con le release molto vecchie), fissa `DEBIAN_CODENAME` a una release la cui versione di nginx sia ancora scaricabile.

Un modulo disallineato dal server non passa inosservato: il `nginx -t` del Dockerfile fallisce il build con `module is not binary compatible`, invece di lasciare scoprire il problema al primo deploy.
