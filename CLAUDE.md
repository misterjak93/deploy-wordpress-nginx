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
```

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

### Varnish risolve il backend a tempo di compilazione

Non ad ogni richiesta. Se il container `wordpress` viene ricreato e
cambia IP, Varnish punta al vecchio finché non riparte. Per questo il
wrapper aspetta che il nome sia risolvibile prima di compilare.

### Ordine delle location in nginx

Le regex vengono valutate nell'ordine in cui compaiono, e un prefisso
`^~` batte le regex. Da qui due dipendenze:

- `wordpress-hardening.conf` va incluso **prima** delle location generiche,
  altrimenti un `.php` caricato in `uploads` verrebbe eseguito;
- `/wp-json/` è un prefisso semplice, non `^~`: con `^~` la regex che
  protegge `/wp-json/wp/v2/users` non verrebbe mai raggiunta.

### `add_header` non si eredita

Appena una location ne dichiara uno, tutti quelli del livello superiore
spariscono. Per questo `security-headers.conf` va incluso in ogni
location che aggiunge header propri, **comprese le pagine di errore**.

### PHP: il pacchetto opcache non esiste più da 8.5

Da PHP 8.5 sury compila OPcache staticamente nel binario e non pubblica
più `phpX.Y-opcache`. Il pacchetto sta fra gli opzionali, ma OPcache
resta obbligatorio come *capacità*: il build interroga l'interprete, che
è la prova valida comunque venga distribuito.

### Compose: niente sintassi `${VAR:?...}`

Fa fallire l'interpolazione con errore, e Dokploy rilegge e riscrive il
compose per iniettare le label Traefik. Se quel passaggio va in errore il
container parte comunque, ma senza label: né rotta né certificato.

### Una variabile assente da `environment:` non arriva al container

Per quanto accuratamente sia impostata nel `.env`. Un nuovo knob va
aggiunto in **entrambi** i posti.

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

---

## Cose note e non risolte

- **`deb.sury.org` pubblica già PHP 8.6**, ma senza `php8.6-redis`, che
  qui è obbligatorio. Il build si ferma dicendolo per nome.
- **Nessuna Content-Security-Policy.** Una CSP sensata dipende da tema e
  plugin: una generica o blocca il sito o non protegge. Da aggiungere in
  `nginx/snippets/security-headers.conf` quando il sito è stabile.
- **Il build non è mai stato eseguito in questa sandbox** (niente demone
  Docker): la verifica dei moduli Brotli/Zstandard e dei pacchetti sury
  avviene al primo deploy reale.
