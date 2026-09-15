# CLAUDE.md

Note di lavoro per questo repository: come si contribuisce, perché lo
stack è fatto così, e cosa è già stato provato e scartato.

Il `README.md` spiega **come si usa** lo stack. Questo file spiega **come
lo si modifica**, e i vincoli non ovvi da non reintrodurre.

---

## Workflow

**Ogni modifica passa da una pull request verso `main`.** Niente push
diretti su `main`.

1. branch dedicato a partire da `main`
2. commit con messaggio che spiega *perché*, non solo *cosa*
3. pull request verso `main`
4. merge, e solo allora il deploy

`main` è la versione che gira in produzione: Dokploy deploya da lì.

### Prima di aprire una PR

Lo stack non ha una suite di test, ma tre cose si possono verificare
senza fare un deploy, e vanno verificate:

```bash
# 1. Configurazione nginx: renderizzare i template e passarli a nginx -t.
#    I template usano envsubst con una whitelist esplicita di variabili
#    (vedi NGINX_VARS in entrypoint.sh): tutte le $variabili di nginx
#    restano intatte proprio perché non sono nella lista.

# 2. VCL: compilarlo davvero.
varnishd -C -f default.vcl

# 3. Sintassi shell di ogni script.
bash -n entrypoint.sh scripts/*.sh
sh -n varnish/varnish-entrypoint.sh

# 4. PHP del mu-plugin.
php -l wordpress/mu-plugins/stack-cache.php
```

E quando la modifica riguarda il comportamento, non la sintassi: nginx e
Varnish si installano dai pacchetti (`apt-get install nginx-light
varnish`) e si fanno girare **davvero**, uno davanti all'altro, con i
template renderizzati. `varnish-entrypoint.sh` si avvia così com'è
passandogli `VARNISH_RUNTIME_DIR`, `BACKEND_HOST=localhost` e
`BACKEND_PORT` della nginx di prova.

Costa dieci minuti ed è l'unico modo per contare gli **effetti** invece
di leggere il codice: quale generazione di pagina torna dopo un PURGE,
cosa riceve davvero il backend in `Accept-Encoding` (`varnishlog -i
BereqHeader`), che codice risponde `/healthz` con una catena di header
falsificata. Ogni guasto grave trovato finora in questo repository era
silenzioso, e nessuno di loro sarebbe emerso da una rilettura.

---

## Vincoli da non reintrodurre

Ognuno di questi è costato un deploy fallito o un bug sottile. Sono
elencati perché la modifica "ovvia" li riporta indietro.

### Varnish gira come utente non-root

L'immagine ufficiale ha `User: varnish` e `WorkingDir: /etc/varnish`, che
per quell'utente è **sola lettura**. Tre cose ne dipendono:

- il VCL generato da `varnish-entrypoint.sh`
- il file secret dell'interfaccia di amministrazione
- `varnishd -C`, che scrive le proprie temporanee nella directory corrente

Tutte e tre vivono in `/tmp/varnish`, montata come **tmpfs con
`mode=1777`**. Un volume nominato non funzionerebbe: nasce `root:root` e
l'utente `varnish` non potrebbe scriverci.

### `varnishd -C` stampa su stderr

Il sorgente C generato (circa 110 KB) esce su **stderr**, non su stdout.
Un `> /dev/null` non lo intercetta e riempie il log del container ad ogni
avvio. L'output va catturato e stampato solo in caso di errore.

### `http_gzip_support=off` non è opzionale

È la scelta che tiene in piedi Brotli e Zstandard. Acceso (il default),
Varnish riscrive `Accept-Encoding` a `gzip` verso il backend: nginx non
vedrebbe mai `br` né `zstd` e non li produrrebbe **per nessuno**.

### La normalizzazione di `Accept-Encoding` è obbligatoria

Ogni risposta compressa esce con `Vary: Accept-Encoding`, quindi Varnish
tiene una copia per ogni valore distinto di quell'header — e nel mondo
reale ne esistono decine di varianti testuali per la stessa capacità.
Senza normalizzare, l'hit rate crolla. Stesso ragionamento per `Accept`
sulle immagini (negoziazione AVIF/WebP).

### nginx: le direttive di un modulo solo se il modulo c'è

`brotli on` senza il modulo caricato non degrada la compressione: fa
fallire nginx all'avvio con `unknown directive`, cioè sito giù.
L'entrypoint emette ogni blocco solo dopo aver verificato il `.so`.

`COMPRESSION_PRIORITY` è letta da Varnish, che gira in un altro container
e non può sapere cosa nginx sappia produrre. Se chiede una codifica
assente, i browser che la annunciano ricevono risposte **non compresse**:
peggio che non averla. L'entrypoint lo segnala nei log di avvio.

### PURGE: l'ACL da sola non basta

Le richieste che arrivano da Traefik hanno l'IP di Traefik, che è in
`172.16.0.0/12`. Il discriminante è il numero di indirizzi in
`X-Forwarded-For`: una chiamata interna ne ha uno, una passata dal proxy
almeno due.

L'ACL, dal canto suo, non elenca più le reti private: la genera
l'entrypoint dagli indirizzi dei backend. Vedi *L'ACL di Varnish per il
purge si genera, non si scrive*, più in basso.

### Varnish risolve il backend a tempo di compilazione

Non ad ogni richiesta, **e accetta un solo IPv4 per backend**. Se il nome
`wordpress` ne restituisce più di uno — più repliche, o container rimasti
attaccati alla rete da un deploy precedente — la compilazione fallisce con
`resolves to too many addresses` e il container non parte affatto.

Per questo i backend non sono scritti nel template: il wrapper enumera
tutti gli indirizzi e ne genera uno per ciascuno, dietro a un director
`round_robin`. La probe ha `.initial = 0`, quindi ogni backend parte
**malato** e deve guadagnarsi il traffico rispondendo: è ciò che rende
innocuo un indirizzo rimasto da un deploy vecchio, invece di mandargli
richieste finché la probe non se ne accorge.

Non tornare a un `backend default` statico con il nome DNS: rompe appena
compare un secondo indirizzo.

**E non basta risolvere una volta all'avvio.** Gli indirizzi cambiano ogni
volta che il container WordPress viene ricreato: un redeploy, un riavvio
del solo servizio. Varnish resterebbe a puntare a indirizzi che non
esistono più e risponderebbe 503 a tutti finché qualcuno non lo riavvia a
mano — ed è successo davvero.

Per questo `varnish-entrypoint.sh` **non** lancia `varnishd` con `exec`:
resta vivo, ricontrolla gli indirizzi ogni `BACKEND_RECHECK_INTERVAL`
secondi e, quando cambiano, rigenera il VCL e lo ricarica con
`vcl.load` + `vcl.use`. A caldo: niente riavvio, cache conservata.

Conseguenze da tenere presenti se si tocca lo script:

- lo script è PID 1, quindi deve inoltrare `SIGTERM` a `varnishd`,
  altrimenti `docker stop` finisce per uccidere il container;
- il sonno del ciclo è spezzato in tranche da 5s proprio perché un
  `sleep` lungo ritarderebbe la risposta al segnale oltre i 10s che
  Docker concede;
- una risoluzione vuota non deve far ricaricare niente: significa quasi
  sempre che il backend si sta riavviando, e un VCL senza backend non
  compila nemmeno.

### Il traffico amministrativo non entra in Varnish, e il punto è uno solo

La RAM di Varnish è riservata al traffico anonimo. Chi ha una sessione
WordPress aperta esce alla prima riga utile di `vcl_recv`, prima di
qualunque normalizzazione, lookup o chiave: niente oggetto, niente
hit-for-miss, nemmeno per gli asset. Per la bacheca il livello di cache è
nginx, che sta su disco.

La regola esiste **una volta sola**, in cima al VCL, e ci sta apposta. Le
regole più in basso (statici, cookie, percorsi) non la ripetono: sarebbe
una seconda lista da tenere allineata a mano, e prima o poi una delle due
resta indietro.

Sta in cima anche perché il blocco degli statici, più sotto, dice «un
asset non deve mai essere escluso dalla cache per colpa di un cookie».
Spostarlo sopra al controllo dei cookie — modifica ragionevole a leggerne
il commento — rimetterebbe in cache le richieste di chi è loggato. Con il
gate in cima quelle richieste non arrivano nemmeno a leggerlo.

Il marcatore `X-Stack-Bypass` è interno: `vcl_recv` lo azzera prima di
tutto, così un client non può fabbricarlo, e `vcl_backend_fetch` lo toglie
prima di parlare con nginx. Serve solo a `vcl_deliver` per emettere
`X-Cache: BYPASS`.

In `vcl_backend_response` il primo controllo è `bereq.uncacheable`, vero
per ogni fetch nato da un pass. Oltre a non sprecare lavoro, è una
correzione: più in basso l'HTML esce con `Cache-Control: public`, che su
una pagina di `wp-admin` sovrascriverebbe il `no-store` messo apposta dal
mu-plugin.

### Il nome del backend deve essere unico su dokploy-network

`dokploy-network` è **condivisa da tutti i progetti** sulla stessa
macchina, e il DNS di Docker risolve un nome su tutte le reti a cui è
attaccato chi interroga. Varnish sta su entrambe le reti, quindi
chiedendo `wordpress` riceveva anche i container omonimi degli altri
stack — altri siti, vivi, che rispondono ma non hanno `/healthz`: tutte
le probe fallivano e il sito dava 503.

Per questo il servizio `wordpress` ha l'alias **`wp-upstream`** su
`wordpress-network`, ed è quello che Varnish cerca (`BACKEND_HOST`).
L'alias esiste solo dentro la rete privata del progetto.

Due copie di questo stack sulla stessa macchina non collidono, perché il
servizio `wordpress` non è **mai** su `dokploy-network` — ed è anche la
ragione per cui la cache non è scavalcabile. Le due proprietà si
sostengono a vicenda: non mettere `wordpress` su `dokploy-network`.

Stessa ambiguità per **adminer**, che sta su `dokploy-network` e
risolverebbe `mariadb`: da qui l'alias `wp-mariadb`. Il container
`wordpress` non ha il problema, non essendo su quella rete, e continua a
usare `DB_HOST=mariadb`.

Regola generale: **ogni nome cercato da un container attaccato a
`dokploy-network` va reso univoco con un alias.**

### Ordine delle location in nginx

Le regex vengono valutate nell'ordine in cui compaiono, e un prefisso
`^~` batte le regex. Da qui due dipendenze:

- `wordpress-hardening.conf` va incluso **prima** delle location generiche,
  altrimenti un `.php` caricato in `uploads` verrebbe eseguito;
- `/wp-json/` è un prefisso semplice, non `^~`: con `^~` la regex che
  protegge `/wp-json/wp/v2/users` non verrebbe mai raggiunta.

### L'hardening non può chiudere `install.php` prima dell'installazione

`wordpress-hardening.conf` chiudeva `/wp-admin/install.php` e
`/wp-admin/setup-config.php` con un 404 fisso. Ma l'entrypoint, dopo aver
generato `wp-config.php`, scrive "apri il sito per completare
l'installazione dal browser": quella pagina è l'unica strada, e rispondeva
**404**. Sito appena deployato e non installabile affatto.

Le due location vivono ora in `install-guard.conf`, generato ad ogni avvio
da `entrypoint.sh` in base allo stato vero (`wp core is-installed`, e
l'esistenza di `wp-config.php` per `setup-config.php`), con
`WP_INSTALL_ACCESS` per forzare `deny` o `open`. Chiuse per default su un
sito installato, aperte solo finché servono.

Se si tocca: il guard va scritto **sempre**, anche quando è "chiuso", o
l'`include` in `wordpress-hardening.conf` punta a un file inesistente e
nginx non parte. Stesso schema della coppia `fastcgi-cache*.conf`.

### Mai inviare `PATH_TRANSLATED` a php-fpm

`99-wordpress.ini` imposta `cgi.fix_pathinfo = 0`, che è la scelta giusta
per sicurezza. Ma con quel valore php-fpm **non** usa `SCRIPT_FILENAME`
per decidere cosa eseguire: usa `PATH_TRANSLATED`, se lo riceve.

Su una richiesta normale il path info è vuoto, quindi
`$document_root$fastcgi_path_info` vale la sola docroot — una directory,
senza estensione `.php`. Scatta `security.limit_extensions` e php-fpm
risponde **403 con il corpo `Access denied.`** (esattamente 15 byte) per
ogni singolo script: sito completamente inaccessibile.

Il `fastcgi.conf` che molte guide copiano contiene quella riga. PHP
ricava `PATH_TRANSLATED` da sé quando serve. Non reintrodurla.

Sintomo riconoscibile: tutto ciò che resta in nginx funziona (404, 403,
file statici), tutto ciò che arriva a PHP dà `Access denied.`.

### Nemmeno `PATH_INFO`, e per la stessa ragione

Stessa famiglia del vincolo qui sopra, stesso corpo `Access denied.`, ma
si manifesta solo sugli endpoint che **non sono file**.

`fastcgi_param PATH_INFO $fastcgi_path_info` lo mandava vuoto ma
**presente**, e tanto basta: php-fpm prende il ramo path-info e valuta
`security.limit_extensions` su un nome derivato dalla docroot senza
estensione `.php`. Sulle pagine non si vedeva — lì il nome finisce
davvero in `.php`. Si vedeva su `/php-fpm-status` e `/healthz-php`, che
rispondevano **403** invece di servire `pm.status_path` e `ping.path`: il
gestore delle due sonde non veniva nemmeno raggiunto.

In questo stack il path info è *strutturalmente* sempre vuoto — ogni
location PHP o ha `try_files $uri =404` o è un match esatto — quindi le
due righe (`fastcgi_split_path_info` e il parametro) non portavano nulla.
Se un domani servisse davvero, va in uno snippet separato incluso solo
dalle location che lo usano, **mai** in quelle diagnostiche.

Verificato isolando la richiesta con `cgi-fcgi`: stessi identici parametri
senza `PATH_INFO` → `pong`.

### `vcl_hash` include `X-Forwarded-Proto`, quindi ogni chiamata interna deve mandarlo

Le richieste dei visitatori passano da Traefik e l'header ce l'hanno
sempre: ogni oggetto in cache è indicizzato su `url + host + "https"`.
Una chiamata interna che non lo manda calcola un hash diverso e non trova
niente — e `return (purge)` sintetizza **sempre** un 200, che l'oggetto ci
fosse o no.

Risultato: `purge_post()` (cioè la strada normale per ogni pubblicazione,
modifica e commento, con `purge_scope: related`) non ha mai toccato
Varnish. Funzionava solo «svuota tutto», che passa da un `BAN` sugli
header dell'oggetto e quindi non dipende dall'hash. Nessun errore, nessun
log: l'articolo corretto restava vecchio fino alla scadenza del TTL.

Il default sta in cima a `vcl_recv`, **prima** del blocco PURGE/BAN e di
qualunque `return`. Lì copre anche i plugin di terze parti, su cui il
mu-plugin non ha voce (`VHP_VARNISH_IP` è definito in `wp-config.php`).

### `xml` e `txt` non vanno nella location degli statici

Lì la regola è `try_files $uri =404`, giusta per un `.css` che o c'è o non
c'è. Ma xml e txt sono anche risorse che WordPress **genera**: le sitemap
del core (`/wp-sitemap.xml` e figlie, attive per default dalla 5.5),
quelle dei plugin SEO, un `ads.txt` gestito da plugin. Nella regex degli
statici rispondevano tutte 404.

L'effetto peggiore era interno: `collect_sitemap_urls()` chiede
`/wp-sitemap.xml` per costruire la coda di preload, riceveva 404 e
ripiegava in silenzio sugli ultimi 100 contenuti. Il «preload dalla
sitemap» descritto nel README non ha mai letto una sitemap.

### Il cookie di bypass del firewall deve fallire chiuso

Spegne **tutto** il firewall, quindi il valore di esempio non può essere
funzionante: è pubblicato in tre punti del repository e un avviso nei log
non basta (si legge una volta, il default resta).

E finisce **grezzo** dentro a una PCRE. Una parentesi tonda — che un
generatore di password produce senza pensarci — rende la mappa non
compilabile e **nginx non parte**; un punto o un asterisco allargano il
bypass a quasi qualunque cookie. L'entrypoint accetta quindi solo
`[A-Za-z0-9_-]+` e, in ogni altro caso, sostituisce un valore casuale che
nessuno può indovinare: la mappa resta (il template la dichiara sempre) ma
non può scattare.

### `return` salta i controlli `allow`/`deny`

`allow`/`deny` agiscono nella fase di **access**, che nginx esegue
**dopo** quella di rewrite. Una location che risponde con `return` non
arriva mai alla fase di access: i suoi `allow`/`deny` sono decorativi.

È così che `/healthz` è rimasto raggiungibile da Internet, mentre
`/php-fpm-status` (che non usa `return`) era correttamente protetto.

Per gli endpoint che rispondono con `return`, il filtro va fatto con un
`if` sulla mappa `$client_interno`, che sta nella stessa fase e lo
precede.

### `open_file_cache` va spento dove vive la cache FastCGI

`open_file_cache` è attivo a livello `http` per gli asset statici, dove
rende parecchio. Ma tiene aperti i **descrittori** dei file: quando il
plugin cancella una voce di cache, il file sparisce dalla directory e il
suo inode resta vivo finché nginx tiene il descrittore. Per un minuto
intero nginx continua a servire il contenuto vecchio, rispondendo `HIT`
e senza mai interpellare PHP.

È il difetto peggiore possibile in una cache, perché è **silenzioso**: la
bacheca dice che la cache è stata svuotata e il sito mostra ancora la
versione precedente.

`fastcgi-cache-use.conf.template` contiene quindi `open_file_cache off;`.
Vale solo per le location con cache di pagina; gli statici continuano a
goderne. Trovato solo perché il test contava le esecuzioni di PHP invece
di fidarsi dell'header.

### `fastcgi_cache_use_stale` non accetta `http_502` né `http_504`

I valori ammessi sono `error`, `timeout`, `invalid_header`, `updating`,
`http_500`, `http_503`, `http_403`, `http_404`, `http_429`. Un gateway
morto ricade sotto `error`, un backend lento sotto `timeout`. Metterne
uno non valido fa **fallire l'avvio** di nginx.

### La chiave di cache è duplicata in due posti

`fastcgi_cache_key` in `fastcgi-cache.conf.template` e il calcolo in
`Stack_Cache::nginx_path_for_url()` devono produrre la stessa identica
stringa (`GET|host|request_uri`), e la struttura delle directory deve
seguire `levels=1:2`: ultimo carattere dell'md5, poi i due precedenti.

Se divergono, l'invalidazione smette di funzionare **senza errori**: il
plugin cancella file che non esistono e il sito serve contenuto vecchio.
Verificato confrontando il percorso calcolato dal plugin con il file
davvero scritto da nginx.

Il metodo resta nella chiave apposta: senza, una HEAD in MISS
memorizzerebbe una risposta **senza corpo**, che verrebbe poi servita a
una GET. Il prezzo è che GET e HEAD sono due voci distinte, quindi il
plugin deve cancellarle **entrambe** — `nginx_paths_for_url()` restituisce
i due percorsi. Prima cancellava solo la GET, e le voci HEAD (monitor
esterni, anteprime di link, crawler) restavano fino a `inactive=60d`.

### `add_header` non si eredita

Appena una location ne dichiara uno, tutti quelli del livello superiore
spariscono. Per questo `security-headers.conf` va incluso in ogni
location che aggiunge header propri, **comprese le pagine di errore**.

### PHP: il pacchetto opcache non esiste più da 8.5

Da PHP 8.5 sury compila OPcache staticamente nel binario e non pubblica
più `phpX.Y-opcache`. Il pacchetto sta fra gli opzionali, ma OPcache
resta obbligatorio come *capacità*: il build interroga l'interprete, che
è la prova valida comunque venga distribuito.

### WP-CLI gira come www-data ma HOME sarebbe di root

Senza `HOME` esportato in `scripts/wp`, ogni comando stampa
`Failed to create directory '/root/.wp-cli/cache/'` e la cache dei
download non funziona. `setpriv` non ripulisce l'ambiente, quindi
esportarlo nel wrapper basta.

### Il cron non deve loggare a ogni giro

Fra il primo avvio e l'installazione dal browser possono passare giorni,
e in quel periodo ogni esecuzione fallisce. Il runner aspetta che
`wp core is-installed` risponda prima di iniziare, e nel ciclo stampa un
errore solo quando **cambia**: un problema persistente si segnala una
volta, non una al minuto.

### Compose: niente sintassi `${VAR:?...}`

Fa fallire l'interpolazione con errore, e Dokploy rilegge e riscrive il
compose per iniettare le label Traefik. Se quel passaggio va in errore il
container parte comunque, ma senza label: né rotta né certificato.

### Il dominio si sposta in un ordine solo

`WP_HOME` e `WP_SITEURL` stanno in `wp-config.php`, scritte una volta
sola alla prima installazione, e **vincono sui valori nel database**:
cambiare `DOMAIN` nel `.env` non sposta il sito, e non lo segnala
nemmeno. `WP_DOMAIN_SYNC` (`off` | `config` | `full`) lo fa fare
all'avvio.

L'ordine delle operazioni in `full` non è estetica:

1. **dump del database** in `${WP_BASE}/backups` — fuori dalla docroot,
   contiene gli hash delle password. Se fallisce, non si tocca niente:
   una `search-replace` non si annulla;
2. **`search-replace`** su `//vecchio` → `//nuovo` (senza schema cadono
   insieme http, https e i link protocol-relative), con
   `--skip-columns=guid`, che non è opzionale: i GUID sono identificatori
   storici, non indirizzi;
3. **solo adesso** le define in `wp-config.php`.

Il terzo passo per ultimo perché quelle define **sono il marcatore** di
"dominio corrente": finché restano vecchie, l'avvio successivo riprova.
Aggiornarle dopo un fallimento vorrebbe dire un sito a metà che ha anche
smesso di segnalarsi.

Due guardie da non togliere: non si parte mai con `DOMAIN` uguale a
`localhost` (è il default del `.env` dimenticato, e riscriverebbe il
database di un sito vero), e l'esito della `search-replace` si legge dal
comando, non da una pipe — in pipe conterebbe l'uscita di `sed`, e una
migrazione fallita risulterebbe riuscita.

### Una variabile assente da `environment:` non arriva al container

Per quanto accuratamente sia impostata nel `.env`. Un nuovo knob va
aggiunto in **entrambi** i posti.

### L'invalidazione non si fa dentro alla richiesta della bacheca

Ogni purge è una chiamata di rete, e `purge_post()` ne fa una per ogni
URL coinvolto: permalink, homepage, feed, ogni archivio di termine,
autore. Farle mentre l'amministratore aspetta significa che il tempo di
salvataggio di un articolo è la somma di quelle chiamate — e con Varnish
irraggiungibile è la somma dei loro timeout.

Il lavoro si accumula in `$pending_urls` e parte su `shutdown`, con
priorità `PHP_INT_MAX` e dopo `fastcgi_finish_request()`: a quel punto la
risposta è già dal browser e nessuno sta aspettando.

Due cose da non invertire se si tocca:

- gli URL si **calcolano subito**, non a fine richiesta: `get_permalink()`
  e `get_term_link()` di un contenuto appena cestinato non darebbero più
  lo stesso indirizzo. A essere rimandata è solo la parte di rete;
- le automazioni usano le varianti `queue_*`; `purge_all()` resta
  sincrona perché la chiama il pulsante della bacheca, che deve poter
  dire quanti file ha rimosso.

La lettura delle sitemap è ancora più pesante (un indice più una
richiesta per figlia) e sta su `wp_schedule_single_event`, non su
`shutdown`. Va letta da `127.0.0.1` con l'header `Host`, come il preload:
dall'URL pubblico uscirebbe e rientrerebbe da Traefik.

### `$client_interno` non deve guardare `$remote_addr`

`$remote_addr` lo riscrive `real_ip` a partire da `X-Forwarded-For`, che
è scritto dal client. Con `set_real_ip_from` su tutto lo spazio privato e
`real_ip_recursive on`, una catena di soli indirizzi privati fa adottare
a nginx il **primo** della lista: `X-Forwarded-For: 10.0.0.1,
192.168.1.5` rendeva "interna" una richiesta qualunque, e `/healthz`
rispondeva 200.

Il controllo guarda quindi `$realip_remote_addr` (chi ha davvero aperto
la connessione) e il **numero** di indirizzi in `X-Forwarded-For`. È lo
stesso discriminante del PURGE nel VCL, e regge per la stessa ragione:
chi ne aggiunge uno fa solo crescere la catena, non può togliere quelli
che Traefik e Varnish accodano dopo.

`TRUSTED_PROXIES` resta largo di default e va bene così: gli hop sono due
e uno è Traefik su `dokploy-network`, che questo container non può
dedurre non essendoci sopra. Ma ormai decide solo quale IP finisce nei
log e nei rate limit, non chi entra.

### L'ACL di Varnish per il purge si genera, non si scrive

Le reti private per intero non sono "i container di questo stack":
`dokploy-network` è condivisa con tutti i progetti della macchina — la
stessa ambiguità degli alias `wp-upstream` e `wp-mariadb` — quindi un
container altrui superava sia l'ACL sia il test su `X-Forwarded-For`.

L'ACL la genera `varnish-entrypoint.sh` dagli stessi indirizzi con cui
genera i backend, quindi segue da sola i container ricreati. Non
rimetterci una lista statica di sottoreti.

`PURGE_TOKEN` è la terza condizione, facoltativa. Due cose da ricordare:
finisce **grezzo** in una stringa VCL (un apice doppio non fa compilare
il VCL, cioè Varnish non parte), e un plugin di terze parti non lo manda
— attivarlo con Proxy Cache Purge in uso significa invalidazioni
rifiutate con 403, in silenzio.

### La normalizzazione di `Accept-Encoding` deve togliere prima i `q=0`

Il confronto per sottostringa è ciò che rende la normalizzazione
economica, ma `gzip, br;q=0` contiene `br` pur essendo un rifiuto
esplicito: quel client riceveva brotli, cioè una pagina illeggibile.

Nella regex che li rimuove, il delimitatore finale `(,|$)` è
obbligatorio: senza, `gzip;q=0.5` verrebbe letto come `q=0` seguito da
spazzatura e gzip sparirebbe pur essendo accettato.

### Svuotare la cache di nginx è una rinomina, non una passata di unlink

Su una cache da 2 GB sono decine di migliaia di file: iterarli dentro
alla richiesta dell'amministratore costava minuti e lasciava indietro le
directory vuote. `purge_nginx_all()` rinomina la directory in
`.purge-<nome>-<epoch>`, la ricrea vuota e lascia la rimozione al cron, a
lotti da 5000.

È sicuro perché nginx apre i file di cache per percorso ad ogni
richiesta: un file che non trova vale come MISS, esattamente come quando
li si cancellava uno per uno. La directory va ricreata **subito** dopo la
rinomina, o nginx logga un errore per ogni risposta cacheabile.

Le directory messe da parte sono sorelle di quella di cache, non figlie:
`nginx_status()` continua a contare solo le voci vive.

### `/.well-known/` e gli endpoint OAuth/MCP non sono contenuto

Sono la mappa con cui un client impara a parlare con questo sito, e
finivano in cache come una pagina qualunque: GET anonima, nessun cookie,
quindi il ramo generico di `vcl_backend_response` e `VARNISH_TTL` intero
(sei ore di default).

Il guasto vero, su un sito con un server MCP installato: in
`/.well-known/oauth-protected-resource` WordPress pubblica
l'identificatore della risorsa, che costruisce con `rest_url()`. Quel
valore cambia **forma** con la struttura dei permalink —
`/wp-json/mcp/...` con quelli leggibili, `/index.php?rest_route=/mcp/...`
senza — quindi cambiare l'impostazione riscrive tutti gli URL del
documento.

Varnish continuava a servire la copia vecchia, mentre l'authorization
endpoint sta sotto `/wp-admin`, che non è mai in cache e rispondeva con i
valori nuovi. Il client leggeva un identificatore, il server ne calcolava
un altro e rifiutava l'autorizzazione con *The requested resource is not
served by this authorization server*. Con sei ore di TTL l'effetto è anche
intermittente: la connessione riesce, poi cade e non si riesce più a
rifarla.

La regola sta in due posti che devono dire la stessa cosa — `vcl_recv` e
`$cache_skip_uri` in `cache-maps.conf` — e copre **entrambe** le forme di
URL della REST API: il client usa quella che ha letto nella discovery,
non quella che preferiamo noi.

Gli endpoint OAuth sono elencati insieme ai documenti di discovery anche
se quasi sempre passano già oltre (sono POST, o portano `Authorization`):
una GET anonima a `/wp-json/mcp/...` risponde 401, e un 401 tenuto per sei
ore è di nuovo una cache che risponde qualcosa che non è un errore.

Verificato contando le generazioni di pagina, non gli header: backend che
emette un marcatore diverso ad ogni risposta, nginx e Varnish avviati uno
davanti all'altro, e tre richieste per URL.

---

## Storico

### Stack iniziale

Controparte nginx dello stack OpenLiteSpeed (`deploy-wordpress-stack-v2`),
con cache di pagina Varnish e compressione Zstandard/Brotli/gzip.

Catena: `Traefik (TLS) → Varnish (cache) → nginx → PHP-FPM`, con Redis e
MariaDB. Il container `wordpress` non è sulla rete di Traefik: la cache
non è scavalcabile.

Differenza principale rispetto allo stack OpenLiteSpeed: `PHP_VERSION` è
**solo runtime**. L'immagine contiene tutte le versioni e cambiarla è un
riavvio, non un rebuild.

Verificato prima del primo deploy installando nginx e Varnish in locale:
`nginx -t` pulito, firewall (SQLi, XSS, LFI, RCE, scanner) e falsi
positivi (ricerca interna, `redirect_to`, Googlebot, curl), negoziazione
AVIF/WebP, rate limit, e la catena Varnish→nginx completa con HIT/MISS.

Tre bug trovati in quel passaggio: un commento nel VCL che faceva
scattare la guardia anti-segnaposto dello stesso wrapper, `Cache-Control`
duplicato sugli statici, e la pagina di errore che azzerava gli header di
sicurezza.

### Confronto misurato: Varnish contro nginx `fastcgi_cache`

Domanda: serve davvero Varnish, o basta nginx? Misurato con `ab` su 4
core, pagina da 93 KB, solo cache HIT:

| Percorso | req/s | p50 | p99 |
| --- | --- | --- | --- |
| nginx + `fastcgi_cache` | 12.600 | 4 ms | 6 ms |
| Varnish → nginx | 75.000 | 1 ms | 2 ms |

Non è gzip (stesso divario con una pagina da 3 KB) e non è il disco (la
cache di nginx su tmpfs dà lo stesso identico risultato). È che nginx
ricostruisce e ricomprime ad ogni richiesta, mentre Varnish serve byte già
compressi dalla RAM.

Rovescio della medaglia: su corpi grandi **non** compressi nginx vince
8 a 1, grazie al `sendfile` zero-copy. Conferma la scelta nel VCL di non
cachare video, zip e PDF.

Conclusione: a traffico reale (10-100 req/s) entrambe le configurazioni
sono abbondantemente sovradimensionate. Varnish resta per il *grace* — il
sito resta navigabile quando PHP è giù — e per l'invalidazione via `ban`.

### Correzioni dopo i primi deploy

**`php8.5-opcache` non esiste più.** Il primo deploy falliva con
`Unable to locate package`. Verificato sull'indice di sury: OPcache è
l'unico pacchetto sparito fra 8.4 e 8.5. Oltre al fix, i pacchetti
mancanti vengono ora elencati tutti insieme invece di fermarsi al primo,
e `PHP_VERSIONS` accetta la virgola come separatore (lo spazio ha troppe
occasioni di perdersi fra `.env`, parser di Compose e riscrittura di
Dokploy).

**Varnish non partiva:** `cannot create /etc/varnish/default.vcl:
Permission denied`. Vedi *Varnish gira come utente non-root* qui sopra.
Nella stessa occasione è emerso che `varnishd -C` scrive su stderr.

**Pulizia dei log dopo il primo avvio riuscito:** il cron ripeteva
"The site you have requested is not installed" ogni minuto in attesa
dell'installazione, WP-CLI si lamentava di `/root/.wp-cli`, e Varnish
segnalava `mlock() of VSM failed` per via del limite `memlock` a 8 MB.

**503 su tutto il sito, con Varnish vivo.** Gli header lo dicevano:
`via: ... (Varnish/7.7)` e il corpo della pagina di `vcl_backend_error`,
quindi non era Traefik ma Varnish senza backend raggiungibili.

La diagnosi iniziale — indirizzi risolti una volta sola — era **solo metà
della storia**, e ha prodotto la sorveglianza con ricarica a caldo
descritta sopra: utile, ma non la causa. La causa l'ha trovata il
proprietario guardando `docker ps`: cinque container `...-wordpress-1` da
cinque progetti diversi sulla stessa macchina. Il nome `wordpress` non
era ambiguo nel tempo, era ambiguo **nello spazio**. Da qui gli alias.

Lezione operativa: prima di dedurre, guardare. Un `docker ps` avrebbe
risparmiato un giro completo.

**403 `Access denied.` su tutto il sito.** Non era WordPress né nginx: era
php-fpm, per `PATH_TRANSLATED` inviato insieme a `cgi.fix_pathinfo = 0`.
Riprodotto in locale e dimostrato nei due sensi. Nella stessa occasione è
emerso che `/healthz` era raggiungibile da Internet, perché `return`
scavalca `allow`/`deny`.

**Varnish non partiva, secondo giro:** `Backend host "wordpress":
resolves to too many addresses` — tre indirizzi sulla rete interna. Da qui
i backend generati più il director descritti sopra. Il messaggio d'errore
era leggibile solo grazie al fix precedente sullo stderr: prima sarebbe
stato sepolto in 110 KB di sorgente C.

### Audit completo dello stack

Montato e fatto girare per davvero, invece che letto: template
renderizzati con gli stessi `envsubst` e la stessa logica `sed`
dell'entrypoint, VCL compilato, nginx e PHP-FPM avviati con quelle
configurazioni, richieste con `curl` e — dove serviva togliere nginx dal
ragionamento — con `cgi-fcgi` direttamente sul socket del pool.

Venti reperti, tredici riprodotti. I tre gravi erano tutti **silenziosi**,
e due erano esattamente la classe di difetto che questo file definisce la
peggiore in una cache:

- il `PURGE` di una singola pagina non ha mai invalidato niente e
  rispondeva 200 (vedi *`vcl_hash` include `X-Forwarded-Proto`*);
- le due sonde di PHP-FPM rispondevano 403 `Access denied.` da sempre
  (vedi *Nemmeno `PATH_INFO`*) — il README le documenta come lo strumento
  per tarare `PHP_CONCURRENCY`;
- il cookie di bypass d'esempio era una chiave funzionante distribuita nel
  repository.

Lezione operativa, gemella di «prima di dedurre, guardare»: **una cache
che risponde 200 non sta dicendo che ha fatto qualcosa.** Entrambi i
guasti sopravvivevano perché nessuno dei due produceva un errore, e la
verifica che li ha trovati ha contato gli effetti (quale generazione di
pagina tornava dal backend) invece di fidarsi del codice di stato.

Cosa ha retto, verificato nella stessa occasione: la chiave di cache di
nginx e il calcolo del plugin coincidono carattere per carattere;
`PATH_TRANSLATED` è rimasto fuori; l'hardening dei percorsi regge
(`wp-config.php` 404, `.php` in `uploads` 403, `xmlrpc` 444); il rate
limit su `wp-login.php` respinge 29 richieste su 40; una catena
`X-Forwarded-For` falsificata non sopravvive all'hop pubblico che Traefik
accoda.

---

### Le cinque cose rimandate dall'audit

L'audit precedente aveva lasciato un elenco di reperti annotati invece
che risolti, perché richiedevano una decisione di deploy o un refactor
più ampio di quanto un audit debba portarsi dietro. Questo giro li ha
ripresi uno per uno.

Quattro erano lavoro vero e sono chiusi: purge e preload fuori dalla
richiesta della bacheca, `$client_interno` sganciato da
`X-Forwarded-For`, ACL del purge ristretta ai soli backend di questo
progetto, `purge_nginx_all()` a rinomina più cron. Tre rifiniture
(`Via` senza versione, `q=0` in `Accept-Encoding`, ref dei moduli nginx
fissati a uno SHA) sono andate con loro.

Uno è rimasto a metà per forza di cose: `set_real_ip_from` non può
stringersi da solo, perché uno dei due hop da coprire è Traefik su
`dokploy-network` e il container `wordpress` non sta su quella rete —
di proposito. È diventato un knob (`TRUSTED_PROXIES`) e, soprattutto,
ha smesso di essere ciò da cui dipende l'accesso agli endpoint interni.

E uno è rimasto fuori dal repository: l'autenticazione davanti a `files`
e `adminer` sono label Traefik, e le label le riscrive Dokploy. La
sorgente di FileBrowser è però scesa dalla radice del volume a
`wp-content`, che toglie di mezzo `wp-config.php` e la radice della
docroot.

Tutto verificato facendo girare le cose, non leggendole: nginx e Varnish
installati e avviati uno davanti all'altro, `/healthz` interrogato con
catene di `X-Forwarded-For` falsificate (la mappa precedente rispondeva
200, quella nuova 403), PURGE e BAN contati sulla generazione di pagina
che tornava indietro invece che sul codice di stato, e la
normalizzazione di `Accept-Encoding` letta in `varnishlog -i
BereqHeader` per vedere cosa riceve davvero il backend.

Un dettaglio che vale la pena ricordare: con il token attivo un PURGE
senza header risponde **403**, e la cache resta vecchia. È di nuovo la
forma «la cache risponde qualcosa che non è un errore» — solo che
stavolta l'errore c'è ed è visibile. Chi usa un plugin di invalidazione
di terze parti non lo vedrebbe comunque: per questo il token è
facoltativo e il caso è scritto nel `.env.example`.

---

## Cose note e non risolte

- **`files` e `adminer` non hanno niente davanti.** Sono due pannelli di
  amministrazione pubblicati da Traefik con la sola password
  dell'applicazione. La sorgente di FileBrowser ora è
  `/srv/html/wp-content` invece della radice del volume — fuori restano
  `wp-config.php` e la radice della docroot, dove un `.php` caricato
  verrebbe eseguito — ma chi scrive in `wp-content` può comunque
  modificare un tema, e modificare un tema è eseguire codice. Serve un
  middleware Traefik di basic-auth o una lista di IP; il README spiega
  come, e non è nel repository perché le label le riscrive Dokploy e
  vanno verificate sul deploy reale.
- **`set_real_ip_from` si fida ancora di tutto lo spazio privato** per
  default. Ora è `TRUSTED_PROXIES` e si può stringere, ma il default deve
  restare largo: uno dei due hop è Traefik su `dokploy-network`, che il
  container `wordpress` non può dedurre non essendo su quella rete.
  L'esposizione residua è l'IP che finisce nei log e nei rate limit, non
  più l'accesso agli endpoint interni.
- **`PURGE_TOKEN` è facoltativo e di default vuoto.** Con l'ACL ristretta
  ai soli backend il vicino di casa non passa più, ma la difesa contro
  chi possa falsificare l'indirizzo di origine si attiva solo se lo si
  imposta — e attivarlo rompe i plugin di invalidazione di terze parti,
  che non lo conoscono. Non c'è modo di avere entrambe le cose senza
  scegliere.
- **`NGX_BROTLI_REF` e `NGX_ZSTD_REF` sono fissati a uno SHA**, ma quei
  due SHA non sono mai stati compilati: qui non c'è un demone Docker. Il
  build resta la prima occasione in cui si scopre se compilano con la
  nginx della distribuzione. Pinnarli non ha aggiunto rischio — sono la
  testa di `master` al momento del pin, cioè quello che il build avrebbe
  preso comunque — ma non ne ha tolto.
- **La normalizzazione di `Accept` sulle immagini è ancora per
  sottostringa.** Stessa famiglia del `q=0` di `Accept-Encoding`, risolto
  invece nel VCL. Qui l'effetto è più lieve (un browser che *rifiuta*
  esplicitamente `image/avif` ma lo elenca) e la stessa logica sta anche
  nelle mappe di nginx, quindi andrebbero corrette insieme.
- **`deb.sury.org` pubblica già PHP 8.6**, ma senza `php8.6-redis`, che
  qui è obbligatorio. Il build si ferma dicendolo per nome.
- **Nessuna Content-Security-Policy.** Una CSP sensata dipende da tema e
  plugin: una generica o blocca il sito o non protegge. Da aggiungere in
  `nginx/snippets/security-headers.conf` quando il sito è stabile.
- **Il build non è mai stato eseguito in questa sandbox** (niente demone
  Docker): la verifica dei moduli Brotli/Zstandard e dei pacchetti sury
  avviene al primo deploy reale.
