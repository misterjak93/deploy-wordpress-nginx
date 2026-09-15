<?php
/**
 * Plugin Name:  Stack Cache
 * Description:  Governo unificato dei quattro livelli di cache dello stack: Varnish (RAM), nginx FastCGI (SSD), Redis (oggetti) e OPcache (bytecode). Stato, invalidazione, TTL, automazioni e preload.
 * Version:      1.0.0
 * Requires PHP: 8.1
 *
 * Installato come must-use plugin dall'entrypoint del container: fa parte
 * dell'infrastruttura, non e' disattivabile per errore dalla bacheca.
 *
 * Il principio: i due livelli di cache di pagina sono ciechi. Vedono
 * header e cookie, non sanno se una pagina e' un articolo appena
 * pubblicato o il carrello di qualcuno. WordPress lo sa. Questo plugin
 * traduce quella conoscenza in istruzioni che i due livelli capiscono
 * nativamente:
 *
 *   nginx   <- X-Accel-Expires   (supportato nativamente, vince su tutto)
 *   Varnish <- X-WP-Varnish-TTL  (letto in vcl_backend_response)
 *
 * Nessuno dei due header esce mai verso il visitatore.
 *
 * @package StackCache
 */

declare( strict_types = 1 );

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

final class Stack_Cache {

	public const VERSION    = '1.0.0';
	public const OPTION     = 'stack_cache_settings';
	public const QUEUE      = 'stack_cache_preload_queue';
	public const STATS      = 'stack_cache_stats';

	/**
	 * Contatore incrementato ad ogni svuotamento totale. Entra nel
	 * calcolo dell'ETag, quindi "Svuota tutto" invalida anche le copie
	 * che stanno nei browser dei visitatori: senza, il pulsante direbbe
	 * di aver svuotato la cache e una parte del pubblico continuerebbe a
	 * rivedere la pagina vecchia dal proprio disco.
	 */
	public const GENERATION = 'stack_cache_generation';
	public const CRON_HOOK  = 'stack_cache_preload_tick';
	public const SITEMAP_HOOK = 'stack_cache_collect_sitemap';
	public const TRASH_HOOK = 'stack_cache_trash_tick';
	public const MENU_SLUG  = 'stack-cache';

	/**
	 * Prefisso delle directory di cache messe da parte da
	 * purge_nginx_all() in attesa di essere rimosse dal cron. Il punto
	 * iniziale le tiene fuori dai glob ingenui, e il prefisso permette a
	 * run_trash_batch() di riconoscerle senza tenere un elenco da
	 * qualche parte.
	 */
	private const TRASH_PREFIX = '.purge-';

	private static ?self $instance = null;

	/** @var array<string,mixed> */
	private array $settings;

	/**
	 * Lavoro rimandato a fine richiesta.
	 *
	 * Ogni invalidazione e' una chiamata di rete: un PURGE a Varnish per
	 * URL coinvolto, e ce ne sono tanti quanti sono gli archivi che
	 * mostrano un articolo. Farle mentre la bacheca aspetta significa che
	 * chi salva un articolo paga il tempo di tutte, e con Varnish
	 * irraggiungibile paga il timeout di ognuna. Si accumulano qui e si
	 * eseguono su 'shutdown', dopo che la risposta e' stata mandata.
	 *
	 * @var string[]
	 */
	private array $pending_urls = array();

	private bool $pending_all = false;

	/** @var string[] URL da mettere in coda di preload alla fine. */
	private array $pending_preload = array();

	private bool $shutdown_hooked = false;

	public static function instance(): self {
		return self::$instance ??= new self();
	}

	private function __construct() {
		$this->settings = $this->load_settings();

		// Percorso caldo: su ogni richiesta pubblica gira solo questo.
		//
		// Il gancio e' 'template_redirect', non 'send_headers', e non e'
		// una preferenza di stile. WP::main() esegue in quest'ordine:
		// parse_request(), send_headers(), query_posts(), handle_404().
		// Su 'send_headers' la query principale non e' ancora partita,
		// quindi is_404(), is_feed(), is_search(), is_singular() e le
		// condizionali di WooCommerce rispondono tutte "false": il plugin
		// dichiarava "pagina pubblica" - cioe' trenta giorni di TTL su
		// nginx - anche per un 404, per una ricerca o per il carrello. Le
		// mappe di nginx ne fermavano una parte, ed e' l'unica ragione per
		// cui il guasto non si e' mai visto.
		//
		// 'template_redirect' scatta a query conclusa e prima di qualunque
		// output, ed e' anche il primo punto in cui l'oggetto interrogato
		// esiste: senza di lui non si puo' calcolare un Last-Modified.
		//
		// La priorita' e' alta di proposito, per stare dopo
		// redirect_canonical (10): su una richiesta che finisce in 301
		// quel gancio chiude la risposta e chiama exit, quindi qui non si
		// arriva affatto e il 301 esce senza header di cache. E' corretto:
		// un redirect non e' contenuto di cui questo plugin sappia
		// qualcosa.
		add_action( 'template_redirect', array( $this, 'send_cache_headers' ), 1000 );

		// La REST API non passa di li'. rest_api_loaded() e' agganciata a
		// 'parse_request', serve la richiesta e chiama die(): 'send_headers'
		// e 'template_redirect' non vengono mai eseguiti. Per questo ogni
		// risposta REST usciva senza X-Accel-Expires, e nginx la
		// memorizzava con il proprio FASTCGI_CACHE_TTL. Vedi rest_no_store().
		add_filter( 'rest_post_dispatch', array( $this, 'rest_no_store' ), PHP_INT_MAX, 1 );

		// Due header "Link" che WordPress emette su ogni pagina pubblica:
		// la discovery della REST API e lo shortlink. Viaggiano su ogni
		// risposta e finiscono in cache insieme ad essa, e nessun browser
		// ne fa niente. La discovery resta all'indirizzo di sempre
		// (/wp-json/), solo non viene piu' annunciata in un header.
		//
		// Si possono togliere da qui perche' i must-use plugin vengono
		// caricati da wp-settings.php DOPO default-filters.php, che e' dove
		// i due ganci vengono registrati.
		remove_action( 'template_redirect', 'rest_output_link_header', 11 );
		remove_action( 'template_redirect', 'wp_shortlink_header', 11 );

		add_action( 'init', array( $this, 'register_automations' ) );

		if ( is_admin() ) {
			add_action( 'admin_menu', array( $this, 'register_menu' ) );
			add_action( 'admin_post_stack_cache_action', array( $this, 'handle_action' ) );
			add_action( 'admin_notices', array( $this, 'render_notice' ) );
		}

		add_action( 'admin_bar_menu', array( $this, 'admin_bar' ), 100 );
		add_action( self::CRON_HOOK, array( $this, 'run_preload_batch' ) );
		add_action( self::SITEMAP_HOOK, array( $this, 'collect_sitemap_now' ) );
		add_action( self::TRASH_HOOK, array( $this, 'run_trash_batch' ) );
		add_filter( 'cron_schedules', array( $this, 'add_cron_schedule' ) );
	}

	// =========================================================
	// Impostazioni
	// =========================================================

	/** @return array<string,mixed> */
	public static function defaults(): array {
		return array(
			'enabled'          => true,
			// TTL asimmetrici di proposito: Varnish e' piccola e volatile,
			// nginx e' grande e persistente. Vedi la nota in
			// fastcgi-cache.conf.template.
			'ttl_nginx'        => 2592000, // 30 giorni
			'ttl_varnish'      => 3600,    // 1 ora
			'ttl_feed'         => 1800,
			'ttl_404'          => 60,
			// Quanto puo' tenersi l'HTML il browser del visitatore.
			// Zero di proposito: la cache condivisa la sappiamo
			// invalidare, quella dentro al portatile di un lettore no.
			// Con Last-Modified ed ETag attivi, zero non significa
			// "riscaricare ogni volta" ma "richiedere ogni volta", e la
			// risposta e' quasi sempre un 304 senza corpo.
			'ttl_browser'      => 0,
			'validators'       => true,
			'cache_404'        => true,
			'cache_feed'       => true,
			'purge_scope'      => 'related', // 'related' | 'all'
			'preload_enabled'  => true,
			'preload_batch'    => 5,
			'preload_on_purge' => true,
			'automations'      => array(
				'save_post'      => true,
				'delete_post'    => true,
				'comment'        => true,
				'switch_theme'   => true,
				'plugin_toggle'  => true,
				'nav_menu'       => true,
				'term'           => true,
				'customizer'     => true,
				'core_update'    => true,
			),
		);
	}

	/** @return array<string,mixed> */
	private function load_settings(): array {
		$saved = get_option( self::OPTION, array() );
		if ( ! is_array( $saved ) ) {
			$saved = array();
		}
		$merged = array_merge( self::defaults(), $saved );
		$merged['automations'] = array_merge(
			self::defaults()['automations'],
			is_array( $saved['automations'] ?? null ) ? $saved['automations'] : array()
		);
		return $merged;
	}

	public function get( string $key, mixed $fallback = null ): mixed {
		return $this->settings[ $key ] ?? $fallback;
	}

	private function automation_on( string $key ): bool {
		return $this->get( 'enabled' ) && ! empty( $this->settings['automations'][ $key ] );
	}

	// =========================================================
	// Decisione di cacheabilita'
	// =========================================================

	/**
	 * Dice se la risposta corrente e' condivisibile fra visitatori e per
	 * quanto. Il TTL di nginx e quello di Varnish sono restituiti
	 * separati: i due livelli hanno scopi diversi.
	 *
	 * @return array{cacheable:bool, nginx:int, varnish:int, reason:string}
	 */
	private function evaluate(): array {
		$no = static fn( string $why ): array => array(
			'cacheable' => false,
			'nginx'     => 0,
			'varnish'   => 0,
			'reason'    => $why,
		);

		if ( ! $this->get( 'enabled' ) ) {
			return $no( 'plugin disattivato' );
		}

		// Convenzione rispettata da molti plugin: se qualcuno ha gia'
		// deciso che questa pagina non va in cache, non si discute.
		if ( defined( 'DONOTCACHEPAGE' ) && DONOTCACHEPAGE ) {
			return $no( 'DONOTCACHEPAGE' );
		}

		if ( ( defined( 'WP_CLI' ) && WP_CLI )
			|| wp_doing_cron()
			|| wp_doing_ajax()
			|| is_admin() ) {
			return $no( 'contesto non pubblico' );
		}

		$method = strtoupper( (string) ( $_SERVER['REQUEST_METHOD'] ?? 'GET' ) );
		if ( 'GET' !== $method && 'HEAD' !== $method ) {
			return $no( 'metodo ' . $method );
		}

		// La ragione numero uno per cui una cache di pagina e'
		// pericolosa: servire a un estraneo la pagina di chi e' loggato.
		if ( is_user_logged_in() ) {
			return $no( 'utente loggato' );
		}

		// Anche senza sessione WordPress, un cookie di commento o di
		// carrello rende la pagina personale.
		foreach ( array_keys( $_COOKIE ) as $name ) {
			$name = (string) $name;
			if ( str_starts_with( $name, 'wordpress_logged_in_' )
				|| str_starts_with( $name, 'comment_author_' )
				|| str_starts_with( $name, 'wp-postpass_' )
				|| str_starts_with( $name, 'woocommerce_items_in_cart' )
				|| str_starts_with( $name, 'wp_woocommerce_session_' )
				|| str_starts_with( $name, 'edd_items_in_cart' ) ) {
				// Il nome del cookie lo sceglie chi chiama: si nomina la
				// famiglia, non il cookie. La ragione non esce piu' in un
				// header, ma resta una stringa che puo' finire in un log.
				return $no( 'cookie di sessione' );
			}
		}

		if ( is_preview() || is_customize_preview() || is_search() ) {
			return $no( 'anteprima o ricerca' );
		}

		if ( function_exists( 'post_password_required' ) && is_singular() && post_password_required() ) {
			return $no( 'contenuto protetto da password' );
		}

		// WooCommerce e simili: pagine per definizione personali.
		if ( function_exists( 'is_cart' ) && ( is_cart() || is_checkout() ) ) {
			return $no( 'carrello o cassa' );
		}
		if ( function_exists( 'is_account_page' ) && is_account_page() ) {
			return $no( 'area utente' );
		}

		if ( is_404() ) {
			return $this->get( 'cache_404' )
				? array( 'cacheable' => true, 'nginx' => (int) $this->get( 'ttl_404' ), 'varnish' => (int) $this->get( 'ttl_404' ), 'reason' => '404' )
				: $no( '404' );
		}

		if ( is_feed() ) {
			return $this->get( 'cache_feed' )
				? array( 'cacheable' => true, 'nginx' => (int) $this->get( 'ttl_feed' ), 'varnish' => (int) $this->get( 'ttl_feed' ), 'reason' => 'feed' )
				: $no( 'feed' );
		}

		return array(
			'cacheable' => true,
			'nginx'     => (int) $this->get( 'ttl_nginx' ),
			'varnish'   => (int) $this->get( 'ttl_varnish' ),
			'reason'    => 'pubblica',
		);
	}

	public function send_cache_headers(): void {
		if ( headers_sent() ) {
			return;
		}

		$v = $this->evaluate();

		// X-Accel-Expires: nginx lo legge e lo fa valere sopra
		// Cache-Control ed Expires. Zero significa "non memorizzare".
		header( 'X-Accel-Expires: ' . ( $v['cacheable'] ? $v['nginx'] : 0 ) );
		header( 'X-WP-Varnish-TTL: ' . ( $v['cacheable'] ? $v['varnish'] : 0 ) );

		if ( ! $v['cacheable'] ) {
			// Il browser non deve tenersi una pagina personale.
			header( 'Cache-Control: no-store, no-cache, must-revalidate, max-age=0' );
			return;
		}

		// Cosa puo' farne il browser. Lo decide il plugin perche' e'
		// l'unico dei tre livelli che sa se questa pagina e' pubblica: il
		// VCL non riscrive piu' Cache-Control quando arriva dal backend.
		header( 'Cache-Control: ' . $this->browser_cache_control() );

		$this->send_validators();
	}

	/**
	 * Politica di cache per il browser del visitatore.
	 *
	 * "s-maxage=0" e' fisso e non segue il TTL di Varnish, che il proprio
	 * se lo prende da X-WP-Varnish-TTL. s-maxage parla a una eventuale CDN
	 * davanti a Traefik, e quella non la sappiamo invalidare: annunciarle
	 * un'ora vorrebbe dire un'ora di contenuto vecchio che nessun pulsante
	 * di questa bacheca puo' raggiungere.
	 */
	private function browser_cache_control(): string {
		$ttl = max( 0, (int) $this->get( 'ttl_browser' ) );

		return 'public, max-age=' . $ttl . ', s-maxage=0, must-revalidate';
	}

	/**
	 * Last-Modified, ETag e risposta alle richieste condizionali.
	 *
	 * A cosa servono, visto che davanti ci sono gia' due cache: a non
	 * rispedire il corpo. Con max-age a zero il browser ricontrolla ad
	 * ogni visita, ma se porta con se' il validatore che gli abbiamo dato
	 * la risposta e' un 304 di poche centinaia di byte invece di una
	 * pagina intera. Su un lettore che torna, e su ogni crawler, e' la
	 * differenza fra rimandare 90 KB e rimandare niente.
	 *
	 * I due validatori sono anche cio' che permette a Varnish di
	 * rispondere 304 da solo, senza svegliare nginx: senza ETag
	 * nell'oggetto memorizzato, una richiesta condizionale in HIT si
	 * porta dietro il corpo lo stesso.
	 */
	private function send_validators(): void {
		if ( ! $this->get( 'validators' ) ) {
			return;
		}

		// Su un 404 non c'e' niente da validare: la pagina non esiste e la
		// sua "data di modifica" sarebbe inventata.
		if ( is_404() ) {
			return;
		}

		// Sui feed lo fa gia' WordPress: WP::send_headers() emette
		// Last-Modified ed ETag e risponde 304 da solo. Rifarlo qui
		// significherebbe due header per nome, e il secondo vincerebbe.
		if ( is_feed() ) {
			return;
		}

		$ts = $this->last_modified_ts();
		if ( $ts <= 0 ) {
			return;
		}

		$etag = $this->etag_for( $ts );

		header( 'Last-Modified: ' . gmdate( 'D, d M Y H:i:s', $ts ) . ' GMT' );
		header( 'ETag: ' . $etag );

		if ( ! $this->client_is_current( $etag, $ts ) ) {
			return;
		}

		// 304: i validatori e la politica di cache restano, il corpo no.
		// L'uscita anticipata non salta le invalidazioni accumulate:
		// quelle girano su 'shutdown', che exit() esegue comunque.
		status_header( 304 );
		header_remove( 'Content-Type' );
		header_remove( 'Content-Length' );

		// E i due livelli non devono MEMORIZZARE questa risposta. Senza
		// queste due righe uscirebbe con il TTL calcolato poco sopra, e
		// X-Accel-Expires vince su tutto: nginx memorizzerebbe un 304 -
		// che normalmente non e' fra gli stati cacheabili - e lo
		// servirebbe poi a chi non ha mandato nessun validatore, cioe'
		// una pagina senza corpo a chi la chiede per la prima volta.
		//
		// Nella configurazione predefinita questo ramo non viene mai
		// eseguito, perche' con la cache accesa nginx toglie gli header
		// condizionali prima del backend. Vale per quando e' spenta.
		header( 'X-Accel-Expires: 0' );
		header( 'X-WP-Varnish-TTL: 0' );
		exit;
	}

	/**
	 * La data della cosa piu' recente che compone questa risposta.
	 *
	 * Non e' "l'ultima modifica del sito": un archivio che mostra dieci
	 * articoli cambia quando cambia uno qualunque dei dieci, e una pagina
	 * singola cambia anche quando arriva un commento - senza che
	 * post_modified si muova di un secondo.
	 */
	private function last_modified_ts(): int {
		$date = array();

		if ( is_singular() ) {
			$post = get_queried_object();
			if ( $post instanceof WP_Post ) {
				$date[] = (int) get_post_modified_time( 'U', true, $post );

				// Un commento cambia la pagina senza toccare
				// post_modified. Senza questa riga un lettore che ha gia'
				// visto l'articolo riceverebbe 304 e non vedrebbe mai i
				// commenti nuovi: il guasto sarebbe silenzioso, come tutti
				// i peggiori di questo stack. La query e' una sola riga su
				// una colonna indicizzata, e gira solo quando la pagina la
				// si sta generando davvero - cioe' quando entrambe le
				// cache hanno gia' fatto MISS.
				if ( (int) $post->comment_count > 0 ) {
					$ultimo = get_comments(
						array(
							'post_id' => $post->ID,
							'status'  => 'approve',
							'number'  => 1,
							'orderby' => 'comment_date_gmt',
							'order'   => 'DESC',
						)
					);
					if ( ! empty( $ultimo[0]->comment_date_gmt ) ) {
						$date[] = (int) strtotime( $ultimo[0]->comment_date_gmt . ' GMT' );
					}
				}
			}
		} elseif ( ! empty( $GLOBALS['wp_query']->posts ) ) {
			foreach ( $GLOBALS['wp_query']->posts as $p ) {
				if ( $p instanceof WP_Post && $p->post_modified_gmt ) {
					$date[] = (int) strtotime( $p->post_modified_gmt . ' GMT' );
				}
			}
		}

		if ( ! $date ) {
			// Homepage statica senza loop, pagina di un plugin, archivio
			// vuoto: si ripiega sull'ultima modifica del sito.
			$ultima = get_lastpostmodified( 'GMT' );
			if ( $ultima ) {
				$date[] = (int) strtotime( $ultima . ' GMT' );
			}
		}

		$date = array_filter( $date, static fn( int $t ): bool => $t > 0 );
		if ( ! $date ) {
			return 0;
		}

		// Un contenuto programmato, o un orologio avanti, darebbero un
		// Last-Modified nel futuro: per la RFC e' invalido, e qualche
		// proxy lo legge come "fresco per sempre".
		return min( max( $date ), time() );
	}

	/**
	 * ETag della risposta corrente.
	 *
	 * Debole di proposito (il prefisso W/). Fra PHP e il visitatore il
	 * corpo viene ricompresso da nginx in gzip, brotli o zstd: un ETag
	 * forte smetterebbe di descrivere i byte consegnati davvero. Il modulo
	 * gzip lo degrada da solo a debole, gli altri due non
	 * necessariamente; dichiararlo debole da subito toglie la
	 * discrepanza, e per una richiesta condizionale il confronto debole e'
	 * comunque quello giusto.
	 *
	 * Nell'impronta entrano la data calcolata sopra, l'indirizzo completo
	 * - host compreso, perche' lo stesso percorso su due domini non e' la
	 * stessa pagina - e il contatore di generazione, che sale ad ogni
	 * svuotamento totale.
	 */
	private function etag_for( int $ts ): string {
		$parti = array(
			(string) self::generation(),
			(string) $ts,
			$this->site_host(),
			(string) ( $_SERVER['REQUEST_URI'] ?? '/' ),
		);

		return 'W/"' . md5( implode( '|', $parti ) ) . '"';
	}

	/**
	 * Il client ha gia' questa versione?
	 *
	 * Quando manda un ETag comanda quello e If-Modified-Since diventa
	 * irrilevante: e' il validatore preciso, mentre la data ha la
	 * risoluzione di un secondo e non sa niente dei commenti arrivati
	 * nello stesso secondo.
	 */
	private function client_is_current( string $etag, int $ts ): bool {
		$inm = trim( (string) ( $_SERVER['HTTP_IF_NONE_MATCH'] ?? '' ) );

		if ( '' !== $inm ) {
			if ( '*' === $inm ) {
				return true;
			}

			$nudo = static fn( string $t ): string => trim(
				(string) preg_replace( '/^\s*W\//', '', trim( $t ) )
			);
			$mio  = $nudo( $etag );

			foreach ( explode( ',', $inm ) as $candidato ) {
				if ( $nudo( $candidato ) === $mio ) {
					return true;
				}
			}

			return false;
		}

		$ims = trim( (string) ( $_SERVER['HTTP_IF_MODIFIED_SINCE'] ?? '' ) );
		if ( '' === $ims ) {
			return false;
		}

		$visto = strtotime( $ims );

		return false !== $visto && $visto >= $ts;
	}

	/**
	 * Generazione corrente del sito: sale ad ogni svuotamento totale.
	 *
	 * Entra nell'ETag, quindi "Svuota tutto" invalida anche le copie che
	 * i visitatori hanno nel proprio browser. Senza, il pulsante direbbe
	 * di aver svuotato la cache mentre una parte del pubblico continua a
	 * rivedere la pagina vecchia dal proprio disco, e nessuno se ne
	 * accorgerebbe: l'ennesima cache che risponde qualcosa che non e' un
	 * errore.
	 *
	 * Le invalidazioni mirate non la toccano: la data di modifica del
	 * contenuto cambia da sola, e alzare la generazione per un articolo
	 * scaderebbe i validatori di tutto il sito.
	 */
	public static function generation(): int {
		return max( 1, (int) get_option( self::GENERATION, 1 ) );
	}

	private function bump_generation(): void {
		update_option( self::GENERATION, self::generation() + 1, true );
	}

	/**
	 * La REST API non e' contenuto di pagina, e non deve mai finire in una
	 * cache condivisa.
	 *
	 * Questo filtro esiste perche' nessuno degli altri ganci del plugin
	 * viene eseguito su una richiesta REST: rest_api_loaded() e'
	 * agganciata a 'parse_request', serve la risposta e chiama die(),
	 * quindi 'send_headers' e 'template_redirect' non arrivano mai. Le
	 * risposte REST uscivano percio' senza X-Accel-Expires e senza
	 * X-WP-Varnish-TTL, e i due livelli applicavano i propri default:
	 * FASTCGI_CACHE_TTL su nginx (trenta giorni) e VARNISH_TTL in RAM.
	 *
	 * Il danno non e' "una risposta un po' vecchia". La REST API e' anche
	 * il canale con cui un client esterno - un'app, un server MCP -
	 * scopre di cosa e' capace questo sito e a quali indirizzi parlargli.
	 * Una copia vecchia dell'indice delle rotte gli fa cercare endpoint
	 * che non esistono piu' o ignorare quelli appena comparsi, e siccome
	 * la copia scade da sola il guasto va e viene: la connessione riesce,
	 * poi cade, poi riesce di nuovo. E' la stessa forma gia' vista con i
	 * documenti di discovery sotto /.well-known/, solo su un altro
	 * indirizzo.
	 *
	 * Nemmeno l'invalidazione avrebbe potuto rimediare: purge_post()
	 * conosce permalink, archivi e feed, non le rotte REST che li
	 * espongono. Le voci sarebbero rimaste fino a "inactive".
	 *
	 * Le mappe di nginx e il VCL dicono la stessa cosa. Qui e' il punto in
	 * cui la dice WordPress, che e' l'unico a saperlo anche quando la
	 * rotta la registra un plugin installato stamattina.
	 *
	 * @param mixed $response Risposta gia' pronta per essere servita.
	 * @return mixed
	 */
	public function rest_no_store( mixed $response ): mixed {
		if ( $response instanceof WP_REST_Response ) {
			$response->header( 'X-Accel-Expires', '0' );
			$response->header( 'X-WP-Varnish-TTL', '0' );
			$response->header( 'Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0' );
		}

		return $response;
	}

	// =========================================================
	// Livello 1: Varnish
	// =========================================================

	private function varnish_host(): string {
		if ( defined( 'VHP_VARNISH_IP' ) && VHP_VARNISH_IP ) {
			return (string) VHP_VARNISH_IP;
		}
		return (string) ( getenv( 'VARNISH_HOST' ) ?: 'varnish' );
	}

	/**
	 * Header comuni a PURGE e BAN.
	 *
	 * X-Forwarded-Proto e' obbligatorio, e non e' un dettaglio: vcl_hash
	 * lo include quando c'e'. Le richieste dei visitatori passano da
	 * Traefik e ce l'hanno sempre, quindi gli oggetti in cache sono
	 * indicizzati su url+host+"https". Senza questo header il PURGE
	 * calcolava un hash diverso, non trovava nulla, e Varnish rispondeva
	 * 200 lo stesso: l'invalidazione della singola pagina non funzionava
	 * mai, in silenzio. Il VCL ora mette anche un default, ma mandarlo da
	 * qui rende la cosa leggibile da questo lato.
	 *
	 * X-Purge-Token c'e' solo se il .env lo definisce. Il VCL lo pretende
	 * solo in quel caso, quindi i due lati non possono sfasarsi: lo stesso
	 * valore arriva a entrambi i container.
	 *
	 * @return array<string,string>
	 */
	private function purge_headers(): array {
		$headers = array(
			'Host'              => $this->site_host(),
			'X-Forwarded-Proto' => 'https',
		);

		$token = (string) ( getenv( 'PURGE_TOKEN' ) ?: '' );
		if ( '' !== $token ) {
			$headers['X-Purge-Token'] = $token;
		}

		return $headers;
	}

	private function site_host(): string {
		$host = wp_parse_url( home_url(), PHP_URL_HOST );
		return is_string( $host ) ? strtolower( $host ) : '';
	}

	/**
	 * Invalidazione di una singola pagina.
	 *
	 * La richiesta va all'host interno di Varnish, non all'URL pubblico:
	 * passando da Traefik verrebbe rifiutata, perche' il VCL accetta le
	 * invalidazioni solo da chiamate che non hanno attraversato il proxy.
	 */
	public function purge_varnish_url( string $url ): bool {
		$path = (string) ( wp_parse_url( $url, PHP_URL_PATH ) ?: '/' );
		$q    = wp_parse_url( $url, PHP_URL_QUERY );
		if ( $q ) {
			$path .= '?' . $q;
		}

		$res = wp_remote_request(
			'http://' . $this->varnish_host() . $path,
			array(
				'method'    => 'PURGE',
				'headers'   => $this->purge_headers(),
				'timeout'   => 5,
				'sslverify' => false,
			)
		);
		return ! is_wp_error( $res ) && wp_remote_retrieve_response_code( $res ) < 400;
	}

	/** Invalidazione di tutto il sito, via BAN con espressione regolare. */
	public function purge_varnish_all(): bool {
		$res = wp_remote_request(
			'http://' . $this->varnish_host() . '/',
			array(
				'method'    => 'BAN',
				// Il BAN confronta gli header dell'oggetto, non l'hash,
				// quindi X-Forwarded-Proto qui non sarebbe indispensabile.
				// Si manda per coerenza con il PURGE: l'unica forma che il
				// VCL vede arrivare e' quella di una richiesta passata dal
				// bordo.
				'headers'   => $this->purge_headers() + array( 'X-Ban-Expression' => '.' ),
				'timeout'   => 5,
				'sslverify' => false,
			)
		);
		return ! is_wp_error( $res ) && wp_remote_retrieve_response_code( $res ) < 400;
	}

	public function varnish_status(): array {
		$res = wp_remote_get(
			'http://' . $this->varnish_host() . '/varnish-health',
			array( 'timeout' => 3, 'sslverify' => false )
		);
		if ( is_wp_error( $res ) ) {
			return array( 'ok' => false, 'detail' => $res->get_error_message() );
		}
		$body = trim( (string) wp_remote_retrieve_body( $res ) );
		return array(
			'ok'     => 200 === wp_remote_retrieve_response_code( $res ),
			'detail' => '' !== $body ? $body : 'risposta vuota',
		);
	}

	// =========================================================
	// Livello 2: nginx FastCGI su disco
	// =========================================================

	private function nginx_dir(): string {
		$dir = (string) ( getenv( 'FASTCGI_CACHE_DIR' ) ?: '/var/cache/nginx/wordpress' );
		return rtrim( $dir, '/' );
	}

	/**
	 * Ricostruisce il percorso del file che nginx ha scritto per un URL.
	 *
	 * La chiave deve combaciare CARATTERE PER CARATTERE con
	 * fastcgi_cache_key in fastcgi-cache.conf.template, e la struttura
	 * delle directory con "levels=1:2": ultimo carattere dell'md5, poi i
	 * due precedenti. Se si cambia l'una va cambiata l'altra, altrimenti
	 * l'invalidazione smette silenziosamente di funzionare - il caso
	 * peggiore, perche' il sito continua a servire contenuto vecchio
	 * senza alcun errore.
	 */
	public function nginx_path_for_url( string $url, string $method = 'GET' ): string {
		$parts = wp_parse_url( $url );
		$host  = strtolower( (string) ( $parts['host'] ?? $this->site_host() ) );
		$uri   = (string) ( $parts['path'] ?? '/' );
		if ( ! empty( $parts['query'] ) ) {
			$uri .= '?' . $parts['query'];
		}

		$md5 = md5( strtoupper( $method ) . '|' . $host . '|' . $uri );

		return $this->nginx_dir() . '/' . substr( $md5, -1 ) . '/' . substr( $md5, -3, 2 ) . '/' . $md5;
	}

	/**
	 * Tutti i percorsi che nginx puo' aver scritto per lo stesso URL.
	 *
	 * La chiave comincia con $request_method, quindi una HEAD e una GET
	 * sulla stessa pagina sono due voci distinte. Cancellare solo la GET
	 * lasciava in giro la variante HEAD - creata da monitor esterni,
	 * anteprime di link, crawler - che nessuna invalidazione toccava piu'
	 * fino a inactive=60d.
	 *
	 * Il metodo resta nella chiave apposta: senza, una HEAD in MISS
	 * memorizzerebbe una risposta senza corpo che verrebbe poi servita a
	 * una GET.
	 *
	 * @return string[]
	 */
	public function nginx_paths_for_url( string $url ): array {
		return array(
			$this->nginx_path_for_url( $url, 'GET' ),
			$this->nginx_path_for_url( $url, 'HEAD' ),
		);
	}

	public function purge_nginx_url( string $url ): bool {
		$ok = true;
		foreach ( $this->nginx_paths_for_url( $url ) as $file ) {
			if ( is_file( $file ) && ! @unlink( $file ) ) {
				$ok = false;
			}
		}
		return $ok; // gia' assente conta come raggiunto
	}

	/**
	 * Svuota tutta la cache su disco.
	 *
	 * La strada normale e' rinominare la directory e ricrearla vuota: una
	 * sola operazione, indipendente da quante voci ci siano dentro. La
	 * cache risulta svuotata all'istante - nginx da quel momento scrive
	 * nella directory nuova - e la rimozione vera dei file, che su una
	 * cache da 2 GB sono decine di migliaia, la fa il cron a lotti invece
	 * di tenere ferma la richiesta dell'amministratore.
	 *
	 * Rinominare e' sicuro: nginx apre i file di cache per percorso ad
	 * ogni richiesta, e un file che non trova piu' vale come MISS. E'
	 * esattamente cio' che succedeva gia' cancellandoli uno per uno, solo
	 * senza lasciare indietro le directory vuote.
	 *
	 * Se la rinomina non riesce - permessi sulla directory padre - si
	 * ricade sulla cancellazione diretta, che e' il comportamento
	 * precedente.
	 *
	 * @return array{ok:bool, deferred:bool, files:int}
	 */
	public function purge_nginx_all(): array {
		$dir = $this->nginx_dir();
		if ( ! is_dir( $dir ) ) {
			return array( 'ok' => false, 'deferred' => false, 'files' => 0 );
		}

		$trash = dirname( $dir ) . '/' . self::TRASH_PREFIX . basename( $dir ) . '-' . time();
		if ( ! file_exists( $trash ) && @rename( $dir, $trash ) ) {
			// Ricreata subito: fra la rinomina e la prima scrittura di
			// nginx non deve esserci una finestra senza directory, o
			// nginx logherebbe un errore per ogni risposta cacheabile.
			@mkdir( $dir, 0755, true );
			@chmod( $dir, 0755 );
			$this->schedule_trash_removal();
			return array( 'ok' => true, 'deferred' => true, 'files' => 0 );
		}

		$removed = 0;
		try {
			$it = new RecursiveIteratorIterator(
				new RecursiveDirectoryIterator( $dir, FilesystemIterator::SKIP_DOTS ),
				RecursiveIteratorIterator::CHILD_FIRST
			);
			foreach ( $it as $item ) {
				/** @var SplFileInfo $item */
				if ( $item->isFile() && @unlink( $item->getPathname() ) ) {
					++$removed;
				}
			}
		} catch ( Throwable $e ) {
			// Una cache parzialmente svuotata e' comunque meglio di un
			// errore fatale nella bacheca.
			return array( 'ok' => true, 'deferred' => false, 'files' => $removed );
		}
		return array( 'ok' => true, 'deferred' => false, 'files' => $removed );
	}

	/** @param array{ok:bool, deferred:bool, files:int} $r */
	private function nginx_purge_detail( array $r ): string {
		if ( ! $r['ok'] ) {
			return 'directory non trovata';
		}
		return $r['deferred']
			? 'svuotata (i file vengono rimossi in sottofondo)'
			: sprintf( '%d file rimossi', $r['files'] );
	}

	private function schedule_trash_removal(): void {
		if ( ! wp_next_scheduled( self::TRASH_HOOK ) ) {
			wp_schedule_single_event( time(), self::TRASH_HOOK );
		}
		$this->ensure_cron();
	}

	/**
	 * Rimuove a lotti le directory di cache messe da parte.
	 *
	 * Un tetto per esecuzione, e si riprogramma da sola finche' non ha
	 * finito: cosi' anche una cache enorme non trasforma un giro di cron
	 * in un processo che macina per minuti.
	 */
	public function run_trash_batch(): void {
		$budget = 5000;
		$base   = dirname( $this->nginx_dir() );

		$trashes = glob( $base . '/' . self::TRASH_PREFIX . '*', GLOB_ONLYDIR );
		if ( ! $trashes ) {
			return;
		}

		foreach ( $trashes as $trash ) {
			try {
				$it = new RecursiveIteratorIterator(
					new RecursiveDirectoryIterator( $trash, FilesystemIterator::SKIP_DOTS ),
					RecursiveIteratorIterator::CHILD_FIRST
				);
				foreach ( $it as $item ) {
					/** @var SplFileInfo $item */
					if ( $item->isDir() ) {
						@rmdir( $item->getPathname() );
					} else {
						@unlink( $item->getPathname() );
					}
					if ( --$budget <= 0 ) {
						wp_schedule_single_event( time() + 60, self::TRASH_HOOK );
						return;
					}
				}
			} catch ( Throwable $e ) {
				continue;
			}
			@rmdir( $trash );
		}
	}

	/** @return array{ok:bool, files:int, bytes:int, capped:bool, dir:string} */
	public function nginx_status(): array {
		$dir = $this->nginx_dir();
		if ( ! is_dir( $dir ) ) {
			return array( 'ok' => false, 'files' => 0, 'bytes' => 0, 'capped' => false, 'dir' => $dir );
		}

		$files  = 0;
		$bytes  = 0;
		$capped = false;
		// Su una cache da centinaia di migliaia di voci un conteggio
		// completo bloccherebbe la bacheca: meglio un numero onesto con
		// un tetto dichiarato.
		$limit = 20000;

		try {
			$it = new RecursiveIteratorIterator(
				new RecursiveDirectoryIterator( $dir, FilesystemIterator::SKIP_DOTS )
			);
			foreach ( $it as $item ) {
				/** @var SplFileInfo $item */
				if ( ! $item->isFile() ) {
					continue;
				}
				++$files;
				$bytes += $item->getSize();
				if ( $files >= $limit ) {
					$capped = true;
					break;
				}
			}
		} catch ( Throwable $e ) {
			return array( 'ok' => false, 'files' => $files, 'bytes' => $bytes, 'capped' => $capped, 'dir' => $dir );
		}

		return array(
			'ok'     => is_writable( $dir ),
			'files'  => $files,
			'bytes'  => $bytes,
			'capped' => $capped,
			'dir'    => $dir,
		);
	}

	// =========================================================
	// Livello 3: Redis (object cache)
	// =========================================================

	public function purge_redis(): bool {
		return function_exists( 'wp_cache_flush' ) ? (bool) wp_cache_flush() : false;
	}

	public function redis_status(): array {
		$active = (bool) wp_using_ext_object_cache();
		$detail = $active ? 'object cache esterna attiva' : 'nessuna object cache persistente';

		if ( class_exists( 'Redis' ) ) {
			try {
				$r    = new Redis();
				$host = (string) ( getenv( 'REDIS_HOST' ) ?: 'redis' );
				$port = (int) ( getenv( 'REDIS_PORT' ) ?: 6379 );
				if ( $r->connect( $host, $port, 1.0 ) ) {
					$pass = (string) ( getenv( 'REDIS_PASSWORD' ) ?: '' );
					if ( '' !== $pass ) {
						$r->auth( $pass );
					}
					$info   = $r->info();
					$detail = sprintf(
						'%s · %s usati · %s chiavi',
						$active ? 'attiva' : 'raggiungibile ma non in uso',
						$info['used_memory_human'] ?? '?',
						(string) ( $r->dbSize() )
					);
					$r->close();
					return array( 'ok' => true, 'detail' => $detail );
				}
			} catch ( Throwable $e ) {
				return array( 'ok' => false, 'detail' => 'Redis non raggiungibile: ' . $e->getMessage() );
			}
		}

		return array( 'ok' => $active, 'detail' => $detail );
	}

	// =========================================================
	// Livello 4: OPcache (bytecode)
	// =========================================================

	public function purge_opcache(): bool {
		return function_exists( 'opcache_reset' ) ? (bool) @opcache_reset() : false;
	}

	public function opcache_status(): array {
		if ( ! function_exists( 'opcache_get_status' ) ) {
			return array( 'ok' => false, 'detail' => 'estensione non disponibile' );
		}
		$s = @opcache_get_status( false );
		if ( ! is_array( $s ) || empty( $s['opcache_enabled'] ) ) {
			return array( 'ok' => false, 'detail' => 'disattivata' );
		}

		$mem  = $s['memory_usage'] ?? array();
		$st   = $s['opcache_statistics'] ?? array();
		$hits = (float) ( $st['opcache_hit_rate'] ?? 0 );

		return array(
			'ok'     => true,
			'detail' => sprintf(
				'%s script · %.1f%% di successo · %s usati',
				number_format_i18n( (int) ( $st['num_cached_scripts'] ?? 0 ) ),
				$hits,
				size_format( (int) ( $mem['used_memory'] ?? 0 ) )
			),
		);
	}

	// =========================================================
	// Lavoro rimandato a fine richiesta
	// =========================================================

	/**
	 * Registra il flush di fine richiesta, una volta sola.
	 *
	 * Priorita' massima: cosi' tutto cio' che altri agganciano a
	 * 'shutdown' - compreso wp_ob_end_flush_all, che e' quello che manda
	 * davvero il corpo della risposta - e' gia' passato quando iniziamo a
	 * fare chiamate di rete.
	 */
	private function defer(): void {
		if ( $this->shutdown_hooked ) {
			return;
		}
		$this->shutdown_hooked = true;
		add_action( 'shutdown', array( $this, 'run_pending' ), PHP_INT_MAX );
	}

	/**
	 * Esegue le invalidazioni accumulate durante la richiesta.
	 *
	 * Chiamato su 'shutdown'. La prima cosa che fa e' chiudere la
	 * richiesta FastCGI: da li' in poi il browser ha gia' la sua risposta
	 * e nessuno sta aspettando, anche se Varnish e' irraggiungibile e ogni
	 * PURGE va in timeout.
	 */
	public function run_pending(): void {
		if ( ! $this->pending_all && ! $this->pending_urls && ! $this->pending_preload ) {
			return;
		}

		// In CLI e nel cron non c'e' nessuna richiesta da chiudere, e
		// chiuderla in un contesto FPM dove qualcuno deve ancora stampare
		// qualcosa perderebbe quell'output: si fa solo con una richiesta
		// web vera, come ultimo agganciato a shutdown.
		if ( function_exists( 'fastcgi_finish_request' )
			&& ! ( defined( 'WP_CLI' ) && WP_CLI )
			&& ! wp_doing_cron() ) {
			@fastcgi_finish_request();
		}

		$urls    = $this->pending_urls;
		$preload = $this->pending_preload;
		$all     = $this->pending_all;

		// Azzerati prima di eseguire: un fatal a meta' non deve far
		// ripartire lo stesso lavoro se qualcuno richiama il flush.
		$this->pending_urls    = array();
		$this->pending_preload = array();
		$this->pending_all     = false;

		if ( $all ) {
			// Lo svuotamento totale rende superflua ogni invalidazione
			// mirata accumulata nella stessa richiesta.
			$this->purge_all();
			return;
		}

		foreach ( array_unique( $urls ) as $url ) {
			$this->purge_url_now( (string) $url );
		}

		if ( $preload && $this->get( 'preload_enabled' ) ) {
			$this->queue_preload( $preload );
		}
	}

	// =========================================================
	// Invalidazione combinata
	// =========================================================

	/**
	 * Svuota tutto, subito.
	 *
	 * Sincrona di proposito: la chiama il pulsante della bacheca, che deve
	 * poter dire quanti file ha rimosso. Le automazioni usano invece
	 * queue_purge_all(), che rimanda a fine richiesta.
	 *
	 * @return array<string,mixed>
	 */
	public function purge_all(): array {
		$result = array(
			'varnish' => $this->purge_varnish_all(),
			'nginx'   => $this->purge_nginx_all(),
			'redis'   => $this->purge_redis(),
			'opcache' => $this->purge_opcache(),
		);

		// La copia che sta nel browser del visitatore non la raggiunge
		// nessun PURGE: l'unico modo di scaderla e' cambiare il
		// validatore che le abbiamo dato. Vedi generation().
		$this->bump_generation();

		$this->bump_stat( 'purge_all' );

		if ( $this->get( 'preload_enabled' ) && $this->get( 'preload_on_purge' ) ) {
			$this->queue_preload_from_sitemap();
		}

		/**
		 * Consente ad altro codice di agganciarsi a un'invalidazione
		 * totale, per esempio per svuotare una CDN.
		 */
		do_action( 'stack_cache_purged_all', $result );

		return $result;
	}

	/** Come purge_all(), ma a fine richiesta. */
	public function queue_purge_all(): void {
		$this->pending_all = true;
		$this->defer();
	}

	/** Come purge_everything_including_code(), ma a fine richiesta. */
	public function queue_purge_everything_including_code(): void {
		// OPcache e' locale e costa microsecondi: nessun motivo per
		// rimandarla, e farla subito evita che il resto della richiesta
		// continui a girare sul bytecode vecchio.
		$this->purge_opcache();
		$this->queue_purge_all();
	}

	/**
	 * Mette una pagina in coda di invalidazione.
	 *
	 * Non fa nulla adesso: il lavoro parte su 'shutdown'. Chi ha bisogno
	 * dell'effetto immediato (la CLI, un test) chiami purge_url_now().
	 */
	public function purge_url( string $url ): void {
		$this->pending_urls[] = $url;
		$this->defer();
	}

	/** Invalida una singola pagina su entrambi i livelli, subito. */
	public function purge_url_now( string $url ): void {
		$this->purge_varnish_url( $url );
		$this->purge_nginx_url( $url );
		do_action( 'stack_cache_purged_url', $url );
	}

	/**
	 * Invalida una pagina e i contenitori che la mostrano.
	 *
	 * Un articolo non vive da solo: compare in homepage, negli archivi,
	 * nei feed. Invalidare solo il suo permalink lascia il resto del
	 * sito a mostrare la versione vecchia, che e' il difetto classico
	 * delle cache "intelligenti" fatte a meta'.
	 */
	public function purge_post( int $post_id ): void {
		if ( 'all' === $this->get( 'purge_scope' ) ) {
			$this->queue_purge_all();
			return;
		}

		$urls = array( home_url( '/' ) );

		$permalink = get_permalink( $post_id );
		if ( $permalink ) {
			$urls[] = $permalink;
		}

		$urls[] = get_feed_link();

		foreach ( (array) get_post_taxonomies( $post_id ) as $tax ) {
			foreach ( (array) wp_get_post_terms( $post_id, $tax ) as $term ) {
				if ( $term instanceof WP_Term ) {
					$link = get_term_link( $term );
					if ( ! is_wp_error( $link ) ) {
						$urls[] = $link;
					}
				}
			}
		}

		$post = get_post( $post_id );
		if ( $post ) {
			$author = get_author_posts_url( (int) $post->post_author );
			if ( $author ) {
				$urls[] = $author;
			}
		}

		/** @param string[] $urls */
		$urls = (array) apply_filters( 'stack_cache_post_urls', array_unique( array_filter( $urls ) ), $post_id );

		// Gli URL si calcolano ADESSO, non a fine richiesta: get_permalink()
		// e get_term_link() di un contenuto appena cestinato non
		// restituirebbero piu' lo stesso indirizzo. A essere rimandata e'
		// solo la parte che parla con la rete.
		foreach ( $urls as $url ) {
			$this->purge_url( (string) $url );
		}

		$this->bump_stat( 'purge_post' );

		if ( $this->get( 'preload_enabled' ) ) {
			$this->pending_preload = array_merge( $this->pending_preload, array_map( 'strval', $urls ) );
			$this->defer();
		}
	}

	// =========================================================
	// Automazioni sugli eventi di WordPress
	// =========================================================

	public function register_automations(): void {
		if ( ! $this->get( 'enabled' ) ) {
			return;
		}

		if ( $this->automation_on( 'save_post' ) ) {
			add_action( 'save_post', array( $this, 'on_save_post' ), 10, 3 );
			add_action( 'transition_post_status', array( $this, 'on_transition' ), 10, 3 );
		}
		if ( $this->automation_on( 'delete_post' ) ) {
			add_action( 'before_delete_post', array( $this, 'on_delete_post' ) );
			add_action( 'trashed_post', array( $this, 'on_delete_post' ) );
		}
		if ( $this->automation_on( 'comment' ) ) {
			add_action( 'comment_post', array( $this, 'on_comment' ), 10, 2 );
			add_action( 'edit_comment', array( $this, 'on_comment_edit' ) );
			add_action( 'wp_set_comment_status', array( $this, 'on_comment_edit' ) );
		}
		// Tutte le automazioni passano dalle varianti "queue_": il lavoro
		// vero parte su 'shutdown'. Un'attivazione di plugin o una
		// modifica di termine non deve far aspettare la bacheca il tempo
		// di svuotare quattro livelli di cache.
		if ( $this->automation_on( 'switch_theme' ) ) {
			add_action( 'switch_theme', array( $this, 'queue_purge_all' ) );
		}
		if ( $this->automation_on( 'plugin_toggle' ) ) {
			add_action( 'activated_plugin', array( $this, 'queue_purge_everything_including_code' ) );
			add_action( 'deactivated_plugin', array( $this, 'queue_purge_everything_including_code' ) );
		}
		if ( $this->automation_on( 'nav_menu' ) ) {
			add_action( 'wp_update_nav_menu', array( $this, 'queue_purge_all' ) );
		}
		if ( $this->automation_on( 'term' ) ) {
			add_action( 'edited_term', array( $this, 'queue_purge_all' ) );
			add_action( 'created_term', array( $this, 'queue_purge_all' ) );
			add_action( 'delete_term', array( $this, 'queue_purge_all' ) );
		}
		if ( $this->automation_on( 'customizer' ) ) {
			add_action( 'customize_save_after', array( $this, 'queue_purge_all' ) );
		}
		if ( $this->automation_on( 'core_update' ) ) {
			add_action( 'upgrader_process_complete', array( $this, 'queue_purge_everything_including_code' ) );
			add_action( '_core_updated_successfully', array( $this, 'queue_purge_everything_including_code' ) );
		}
	}

	/** Dopo un aggiornamento di codice va buttato anche il bytecode. */
	public function purge_everything_including_code(): void {
		$this->purge_opcache();
		$this->purge_all();
	}

	public function on_save_post( int $post_id, WP_Post $post, bool $update ): void {
		// Le revisioni e i salvataggi automatici non cambiano nulla di
		// cio' che il pubblico vede.
		if ( wp_is_post_revision( $post_id ) || wp_is_post_autosave( $post_id ) ) {
			return;
		}
		if ( 'publish' !== $post->post_status ) {
			return;
		}
		if ( 'auto-draft' === $post->post_status ) {
			return;
		}
		$this->purge_post( $post_id );
	}

	public function on_transition( string $new, string $old, WP_Post $post ): void {
		// Copre la pubblicazione programmata e il ritiro di un articolo,
		// che non passano da save_post con stato "publish".
		if ( $new === $old ) {
			return;
		}
		if ( 'publish' === $new || 'publish' === $old ) {
			$this->purge_post( (int) $post->ID );
		}
	}

	public function on_delete_post( int $post_id ): void {
		$this->purge_post( $post_id );
	}

	public function on_comment( int $comment_id, int|string $approved ): void {
		if ( 1 !== (int) $approved ) {
			return; // in moderazione: il pubblico non lo vede
		}
		$comment = get_comment( $comment_id );
		if ( $comment ) {
			$this->purge_post( (int) $comment->comment_post_ID );
		}
	}

	public function on_comment_edit( int $comment_id ): void {
		$comment = get_comment( $comment_id );
		if ( $comment ) {
			$this->purge_post( (int) $comment->comment_post_ID );
		}
	}

	// =========================================================
	// Preload
	// =========================================================

	public function add_cron_schedule( array $schedules ): array {
		$schedules['stack_cache_minute'] = array(
			'interval' => 60,
			'display'  => 'Ogni minuto (Stack Cache)',
		);
		return $schedules;
	}

	/** @param string[] $urls */
	public function queue_preload( array $urls ): void {
		$queue = get_option( self::QUEUE, array() );
		if ( ! is_array( $queue ) ) {
			$queue = array();
		}
		$queue = array_values( array_unique( array_merge( $queue, array_map( 'strval', $urls ) ) ) );
		// Un tetto evita che un'automazione impazzita accumuli code
		// illimitate in un'opzione del database.
		$queue = array_slice( $queue, 0, 5000 );
		update_option( self::QUEUE, $queue, false );
		$this->ensure_cron();
	}

	/**
	 * Chiede che la coda venga costruita dalla sitemap.
	 *
	 * Non la scarica adesso: l'indice piu' una richiesta per ogni sitemap
	 * figlia sono decine di chiamate HTTP, e farle dentro alla richiesta
	 * della bacheca significava tenere l'amministratore fermo su un
	 * salvataggio per minuti. Qui si programma soltanto: il lavoro lo fa
	 * il runner del cron, che gira ogni minuto.
	 */
	public function queue_preload_from_sitemap(): void {
		if ( ! wp_next_scheduled( self::SITEMAP_HOOK ) ) {
			wp_schedule_single_event( time(), self::SITEMAP_HOOK );
		}
		$this->ensure_cron();
	}

	/** Esecuzione vera della raccolta, dal cron. */
	public function collect_sitemap_now(): void {
		$urls = $this->collect_sitemap_urls();
		if ( $urls ) {
			$this->queue_preload( $urls );
		}
	}

	/**
	 * Richiesta a nginx nello stesso container, con l'Host del sito.
	 *
	 * Stessa strada del preload: non dipende dal DNS pubblico, da Traefik
	 * ne' dal certificato, e non esce dalla macchina. X-Forwarded-Proto
	 * serve a far rispondere is_ssl() vero, altrimenti WordPress genera la
	 * sitemap con URL in http.
	 *
	 * @return string corpo della risposta, vuoto se la richiesta fallisce
	 */
	private function local_get( string $url, int $timeout = 10 ): string {
		$parts = wp_parse_url( $url );
		$host  = strtolower( (string) ( $parts['host'] ?? '' ) );

		// Una sitemap puo' elencare qualunque indirizzo: si seguono solo
		// quelli di questo sito. Senza il controllo, un plugin SEO
		// malconfigurato basterebbe a far chiedere a nginx un Host altrui.
		if ( '' !== $host && $host !== $this->site_host() ) {
			return '';
		}

		$path = (string) ( $parts['path'] ?? '/' );
		if ( ! empty( $parts['query'] ) ) {
			$path .= '?' . $parts['query'];
		}

		$res = wp_remote_get(
			'http://127.0.0.1' . $path,
			array(
				'timeout'     => $timeout,
				'sslverify'   => false,
				'redirection' => 0,
				'headers'     => array(
					'Host'              => $this->site_host(),
					'X-Stack-Preload'   => '1',
					'X-Forwarded-Proto' => 'https',
				),
			)
		);

		if ( is_wp_error( $res ) || 200 !== wp_remote_retrieve_response_code( $res ) ) {
			return '';
		}
		return (string) wp_remote_retrieve_body( $res );
	}

	/** @return string[] */
	private function collect_sitemap_urls(): array {
		$urls = array( home_url( '/' ) );

		// Sitemap del core di WordPress: e' un indice di altre sitemap.
		$body = $this->local_get( home_url( '/wp-sitemap.xml' ) );
		if ( '' !== $body ) {
			foreach ( $this->extract_locs( $body ) as $sub ) {
				if ( str_contains( $sub, 'wp-sitemap' ) ) {
					$child = $this->local_get( $sub );
					if ( '' !== $child ) {
						$urls = array_merge( $urls, $this->extract_locs( $child ) );
					}
				} else {
					$urls[] = $sub;
				}
			}
		}

		// Se le sitemap sono disattivate si ripiega sui contenuti recenti.
		if ( count( $urls ) <= 1 ) {
			$recent = get_posts(
				array(
					'numberposts' => 100,
					'post_status' => 'publish',
					'post_type'   => array( 'post', 'page' ),
					'fields'      => 'ids',
				)
			);
			foreach ( $recent as $id ) {
				$link = get_permalink( (int) $id );
				if ( $link ) {
					$urls[] = $link;
				}
			}
		}

		return array_values( array_unique( array_filter( $urls ) ) );
	}

	/** @return string[] */
	private function extract_locs( string $xml ): array {
		if ( ! preg_match_all( '#<loc>\s*([^<]+?)\s*</loc>#i', $xml, $m ) ) {
			return array();
		}
		return array_map(
			static fn( string $u ): string => html_entity_decode( trim( $u ), ENT_QUOTES, 'UTF-8' ),
			$m[1]
		);
	}

	public function ensure_cron(): void {
		if ( ! wp_next_scheduled( self::CRON_HOOK ) ) {
			wp_schedule_event( time() + 30, 'stack_cache_minute', self::CRON_HOOK );
		}
	}

	/**
	 * Scalda un lotto di URL.
	 *
	 * Le richieste vanno a 127.0.0.1, cioe' a nginx nello stesso
	 * container, NON all'URL pubblico: non dipendono da DNS, da Traefik
	 * o dal certificato, e riempiono direttamente il livello che conta -
	 * quello persistente su disco. Varnish si riempira' da se' alla
	 * prima visita, e le costa pochi millisecondi.
	 */
	public function run_preload_batch(): void {
		if ( ! $this->get( 'enabled' ) || ! $this->get( 'preload_enabled' ) ) {
			return;
		}

		$queue = get_option( self::QUEUE, array() );
		if ( ! is_array( $queue ) || ! $queue ) {
			return;
		}

		$batch = array_splice( $queue, 0, max( 1, (int) $this->get( 'preload_batch' ) ) );
		update_option( self::QUEUE, $queue, false );

		$host = $this->site_host();
		$done = 0;

		foreach ( $batch as $url ) {
			$path = (string) ( wp_parse_url( (string) $url, PHP_URL_PATH ) ?: '/' );
			$q    = wp_parse_url( (string) $url, PHP_URL_QUERY );
			if ( $q ) {
				$path .= '?' . $q;
			}

			$res = wp_remote_get(
				'http://127.0.0.1' . $path,
				array(
					'timeout'     => 15,
					'sslverify'   => false,
					'redirection' => 0,
					'headers'     => array(
						'Host'            => $host,
						'X-Stack-Preload' => '1',
						'Accept-Encoding' => 'gzip',
						// Senza questo la mappa $fcgi_https resta vuota, PHP
						// riceve HTTPS vuoto e is_ssl() risponde falso. Non
						// e' cosmetico: set_url_scheme() risolve gli schemi
						// 'admin', 'login' e 'rest' proprio su is_ssl(),
						// quindi admin_url(), wp_login_url() e get_rest_url()
						// uscivano in http://. E la chiave della cache su
						// disco non contiene lo schema, quindi quella pagina
						// finiva nella stessa voce che poi legge il
						// visitatore in HTTPS, con la radice REST in chiaro
						// dentro all'HTML - cioe' bloccata dal browser come
						// contenuto misto.
						'X-Forwarded-Proto' => 'https',
					),
				)
			);
			if ( ! is_wp_error( $res ) && wp_remote_retrieve_response_code( $res ) < 400 ) {
				++$done;
			}
		}

		$stats = $this->stats();
		$stats['preloaded']     = ( (int) ( $stats['preloaded'] ?? 0 ) ) + $done;
		$stats['preload_left']  = count( $queue );
		$stats['preload_last']  = time();
		update_option( self::STATS, $stats, false );
	}

	// =========================================================
	// Statistiche
	// =========================================================

	/** @return array<string,mixed> */
	public function stats(): array {
		$s = get_option( self::STATS, array() );
		return is_array( $s ) ? $s : array();
	}

	private function bump_stat( string $key ): void {
		$s         = $this->stats();
		$s[ $key ] = ( (int) ( $s[ $key ] ?? 0 ) ) + 1;
		$s['last'] = time();
		update_option( self::STATS, $s, false );
	}

	// =========================================================
	// Interfaccia
	// =========================================================

	public function register_menu(): void {
		add_menu_page(
			'Cache',
			'Cache',
			'manage_options',
			self::MENU_SLUG,
			array( $this, 'render_page' ),
			'dashicons-performance',
			80
		);
	}

	public function admin_bar( WP_Admin_Bar $bar ): void {
		if ( ! current_user_can( 'manage_options' ) ) {
			return;
		}
		$bar->add_node(
			array(
				'id'    => 'stack-cache',
				'title' => 'Svuota cache',
				'href'  => wp_nonce_url(
					admin_url( 'admin-post.php?action=stack_cache_action&do=purge_all' ),
					'stack_cache'
				),
			)
		);
	}

	public function handle_action(): void {
		if ( ! current_user_can( 'manage_options' ) ) {
			wp_die( 'Permessi insufficienti.' );
		}
		check_admin_referer( 'stack_cache' );

		$do      = sanitize_key( (string) ( $_REQUEST['do'] ?? '' ) );
		$message = '';

		switch ( $do ) {
			case 'purge_all':
				$r       = $this->purge_all();
				$message = sprintf(
					'Cache svuotata. Varnish: %s · nginx: %s · Redis: %s · OPcache: %s',
					$r['varnish'] ? 'ok' : 'non raggiungibile',
					$this->nginx_purge_detail( $r['nginx'] ),
					$r['redis'] ? 'ok' : 'non attiva',
					$r['opcache'] ? 'ok' : 'non disponibile'
				);
				break;

			case 'purge_varnish':
				$message = $this->purge_varnish_all() ? 'Varnish svuotata.' : 'Varnish non raggiungibile.';
				break;

			case 'purge_nginx':
				$message = 'Cache nginx: ' . $this->nginx_purge_detail( $this->purge_nginx_all() ) . '.';
				break;

			case 'purge_redis':
				$message = $this->purge_redis() ? 'Object cache svuotata.' : 'Nessuna object cache persistente.';
				break;

			case 'purge_opcache':
				$message = $this->purge_opcache() ? 'OPcache azzerata.' : 'OPcache non disponibile.';
				break;

			case 'purge_url':
				$url = esc_url_raw( (string) ( $_REQUEST['url'] ?? '' ) );
				if ( $url ) {
					$this->purge_url( $url );
					$message = 'Invalidata: ' . $url;
				} else {
					$message = 'URL non valido.';
				}
				break;

			case 'preload':
				$this->queue_preload_from_sitemap();
				$message = 'Preload programmato: la sitemap viene letta in sottofondo entro un minuto, poi la coda comincia a scorrere.';
				break;

			case 'save':
				$this->save_settings();
				$message = 'Impostazioni salvate.';
				break;

			default:
				$message = 'Azione sconosciuta.';
		}

		set_transient( 'stack_cache_notice', $message, 60 );
		wp_safe_redirect( admin_url( 'admin.php?page=' . self::MENU_SLUG ) );
		exit;
	}

	private function save_settings(): void {
		$in  = wp_unslash( $_POST );
		$new = self::defaults();

		$new['enabled']          = ! empty( $in['enabled'] );
		$new['cache_404']        = ! empty( $in['cache_404'] );
		$new['cache_feed']       = ! empty( $in['cache_feed'] );
		$new['preload_enabled']  = ! empty( $in['preload_enabled'] );
		$new['preload_on_purge'] = ! empty( $in['preload_on_purge'] );
		$new['validators']       = ! empty( $in['validators'] );

		$new['ttl_nginx']     = max( 0, (int) ( $in['ttl_nginx'] ?? 0 ) );
		$new['ttl_varnish']   = max( 0, (int) ( $in['ttl_varnish'] ?? 0 ) );
		$new['ttl_feed']      = max( 0, (int) ( $in['ttl_feed'] ?? 0 ) );
		$new['ttl_404']       = max( 0, (int) ( $in['ttl_404'] ?? 0 ) );
		$new['ttl_browser']   = max( 0, (int) ( $in['ttl_browser'] ?? 0 ) );
		$new['preload_batch'] = max( 1, min( 50, (int) ( $in['preload_batch'] ?? 5 ) ) );

		$new['purge_scope'] = 'all' === ( $in['purge_scope'] ?? '' ) ? 'all' : 'related';

		$autos = array();
		foreach ( array_keys( self::defaults()['automations'] ) as $key ) {
			$autos[ $key ] = ! empty( $in['automations'][ $key ] );
		}
		$new['automations'] = $autos;

		update_option( self::OPTION, $new );
		$this->settings = $this->load_settings();
	}

	public function render_notice(): void {
		$msg = get_transient( 'stack_cache_notice' );
		if ( ! $msg ) {
			return;
		}
		delete_transient( 'stack_cache_notice' );
		printf(
			'<div class="notice notice-success is-dismissible"><p>%s</p></div>',
			esc_html( (string) $msg )
		);
	}

	private function action_url( string $do ): string {
		return wp_nonce_url(
			admin_url( 'admin-post.php?action=stack_cache_action&do=' . $do ),
			'stack_cache'
		);
	}

	public function render_page(): void {
		if ( ! current_user_can( 'manage_options' ) ) {
			return;
		}

		$varnish = $this->varnish_status();
		$nginx   = $this->nginx_status();
		$redis   = $this->redis_status();
		$opcache = $this->opcache_status();
		$stats   = $this->stats();
		$queue   = get_option( self::QUEUE, array() );
		$queued  = is_array( $queue ) ? count( $queue ) : 0;

		$cards = array(
			array(
				'nome'  => 'Varnish',
				'sotto' => 'pagine in RAM · primo livello',
				'ok'    => $varnish['ok'],
				'det'   => $varnish['detail'],
				'do'    => 'purge_varnish',
			),
			array(
				'nome'  => 'nginx FastCGI',
				'sotto' => 'pagine su SSD · secondo livello',
				'ok'    => $nginx['ok'],
				'det'   => $nginx['ok']
					? sprintf(
						'%s%s voci · %s',
						$nginx['capped'] ? 'oltre ' : '',
						number_format_i18n( $nginx['files'] ),
						size_format( $nginx['bytes'] )
					)
					: 'directory non scrivibile: ' . $nginx['dir'],
				'do'    => 'purge_nginx',
			),
			array(
				'nome'  => 'Redis',
				'sotto' => 'oggetti e query',
				'ok'    => $redis['ok'],
				'det'   => $redis['detail'],
				'do'    => 'purge_redis',
			),
			array(
				'nome'  => 'OPcache',
				'sotto' => 'bytecode PHP',
				'ok'    => $opcache['ok'],
				'det'   => $opcache['detail'],
				'do'    => 'purge_opcache',
			),
		);
		?>
		<div class="wrap">
			<h1>Cache</h1>
			<p class="description" style="max-width:52em">
				Quattro livelli indipendenti. Le pagine passano da Varnish (RAM, veloce ma volatile)
				e, se manca, da nginx (SSD, grande e persistente). PHP viene interpellato solo quando
				manca in entrambi.
			</p>

			<h2>Stato</h2>
			<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(15rem,1fr));gap:1rem;margin-bottom:2rem">
				<?php foreach ( $cards as $c ) : ?>
					<div class="card" style="margin:0;padding:1rem">
						<h3 style="margin:0 0 .15rem">
							<span style="color:<?php echo $c['ok'] ? '#137333' : '#b32d2e'; ?>">●</span>
							<?php echo esc_html( $c['nome'] ); ?>
						</h3>
						<p style="margin:0 0 .5rem;color:#646970;font-size:12px"><?php echo esc_html( $c['sotto'] ); ?></p>
						<p style="margin:0 0 .75rem"><?php echo esc_html( $c['det'] ); ?></p>
						<a class="button" href="<?php echo esc_url( $this->action_url( $c['do'] ) ); ?>">Svuota</a>
					</div>
				<?php endforeach; ?>
			</div>

			<h2>Azioni</h2>
			<p>
				<a class="button button-primary" href="<?php echo esc_url( $this->action_url( 'purge_all' ) ); ?>">
					Svuota tutto
				</a>
				<a class="button" href="<?php echo esc_url( $this->action_url( 'preload' ) ); ?>">
					Avvia preload dalla sitemap
				</a>
			</p>

			<form method="post" action="<?php echo esc_url( admin_url( 'admin-post.php' ) ); ?>" style="margin:1rem 0 2rem">
				<input type="hidden" name="action" value="stack_cache_action">
				<input type="hidden" name="do" value="purge_url">
				<?php wp_nonce_field( 'stack_cache' ); ?>
				<label for="sc-url">Invalida un singolo indirizzo</label><br>
				<input id="sc-url" type="url" name="url" class="regular-text" placeholder="<?php echo esc_attr( home_url( '/una-pagina/' ) ); ?>" required>
				<button class="button">Invalida</button>
			</form>

			<?php if ( $queued > 0 ) : ?>
				<div class="notice notice-info inline"><p>
					Preload in corso: <strong><?php echo esc_html( (string) $queued ); ?></strong> indirizzi ancora in coda,
					<?php echo esc_html( (string) (int) ( $stats['preloaded'] ?? 0 ) ); ?> scaldati finora.
					Procede in sottofondo, <?php echo esc_html( (string) (int) $this->get( 'preload_batch' ) ); ?> per minuto.
				</p></div>
			<?php endif; ?>

			<form method="post" action="<?php echo esc_url( admin_url( 'admin-post.php' ) ); ?>">
				<input type="hidden" name="action" value="stack_cache_action">
				<input type="hidden" name="do" value="save">
				<?php wp_nonce_field( 'stack_cache' ); ?>

				<h2>Durate</h2>
				<table class="form-table" role="presentation">
					<tr>
						<th scope="row">Cache attiva</th>
						<td>
							<label><input type="checkbox" name="enabled" value="1" <?php checked( $this->get( 'enabled' ) ); ?>> Sì</label>
							<p class="description">Spenta, ogni risposta esce con TTL zero e i due livelli smettono di memorizzare.</p>
						</td>
					</tr>
					<tr>
						<th scope="row"><label for="ttl_nginx">nginx, su SSD</label></th>
						<td>
							<input id="ttl_nginx" type="number" min="0" name="ttl_nginx" value="<?php echo esc_attr( (string) $this->get( 'ttl_nginx' ) ); ?>" class="small-text"> secondi
							<p class="description">Può essere lunghissimo: questa cache non scade, viene invalidata quando il contenuto cambia. Predefinito 30 giorni.</p>
						</td>
					</tr>
					<tr>
						<th scope="row"><label for="ttl_varnish">Varnish, in RAM</label></th>
						<td>
							<input id="ttl_varnish" type="number" min="0" name="ttl_varnish" value="<?php echo esc_attr( (string) $this->get( 'ttl_varnish' ) ); ?>" class="small-text"> secondi
							<p class="description">Più corto: la RAM è poca e le voci scadute lasciano posto a quelle richieste davvero. Sotto c'è comunque nginx.</p>
						</td>
					</tr>
					<tr>
						<th scope="row">Feed</th>
						<td>
							<label><input type="checkbox" name="cache_feed" value="1" <?php checked( $this->get( 'cache_feed' ) ); ?>> In cache per</label>
							<input type="number" min="0" name="ttl_feed" value="<?php echo esc_attr( (string) $this->get( 'ttl_feed' ) ); ?>" class="small-text"> secondi
						</td>
					</tr>
					<tr>
						<th scope="row">Pagine inesistenti</th>
						<td>
							<label><input type="checkbox" name="cache_404" value="1" <?php checked( $this->get( 'cache_404' ) ); ?>> In cache per</label>
							<input type="number" min="0" name="ttl_404" value="<?php echo esc_attr( (string) $this->get( 'ttl_404' ) ); ?>" class="small-text"> secondi
							<p class="description">Breve ma non zero: impedisce che una scansione di indirizzi inesistenti arrivi tutta a PHP.</p>
						</td>
					</tr>
				</table>

				<h2>Browser del visitatore</h2>
				<p class="description" style="max-width:52em">
					Il terzo posto in cui una pagina può restare ferma, dopo Varnish e nginx — con una
					differenza importante: è l'unico che nessun pulsante di questa schermata può
					raggiungere. Quello che un browser ha già scaricato resta suo fino alla scadenza.
				</p>
				<table class="form-table" role="presentation">
					<tr>
						<th scope="row">Validatori</th>
						<td>
							<label><input type="checkbox" name="validators" value="1" <?php checked( $this->get( 'validators' ) ); ?>>
								Invia <code>Last-Modified</code> ed <code>ETag</code></label>
							<p class="description">
								Il browser che torna chiede "è cambiata?" e quasi sempre riceve un
								<code>304</code> di poche centinaia di byte invece della pagina intera.
								Vale anche per Varnish, che con un <code>ETag</code> in cache risponde 304
								da solo senza disturbare nginx.
							</p>
						</td>
					</tr>
					<tr>
						<th scope="row"><label for="ttl_browser">Durata locale dell'HTML</label></th>
						<td>
							<input id="ttl_browser" type="number" min="0" name="ttl_browser" value="<?php echo esc_attr( (string) $this->get( 'ttl_browser' ) ); ?>" class="small-text"> secondi
							<p class="description">
								Zero è il valore giusto per quasi tutti i siti: con i validatori attivi non
								significa "riscaricare ogni volta" ma "richiedere ogni volta", e la risposta
								è un 304 vuoto. Alzarlo rende il ritorno istantaneo, ma per quei secondi una
								correzione pubblicata non raggiunge chi ha già visitato la pagina.
							</p>
							<p class="description">
								Immagini, CSS e font non passano di qui: li serve nginx, con un anno di
								cache e l'indirizzo che cambia ad ogni nuova versione
								(<code>?ver=</code>). Si regolano dal <code>.env</code>, con
								<code>STATIC_BROWSER_TTL</code>
								<?php
								$sbt = (int) ( getenv( 'STATIC_BROWSER_TTL' ) ?: 31536000 );
								printf(
									' (adesso %s).',
									esc_html( number_format_i18n( $sbt ) . ' secondi' )
								);
								?>
							</p>
						</td>
					</tr>
				</table>

				<h2>Automazioni</h2>
				<p class="description">Quando questi eventi accadono, la cache viene invalidata da sola.</p>
				<table class="form-table" role="presentation">
					<tr>
						<th scope="row">Ampiezza</th>
						<td>
							<label><input type="radio" name="purge_scope" value="related" <?php checked( 'related', $this->get( 'purge_scope' ) ); ?>>
								Solo le pagine coinvolte</label><br>
							<label><input type="radio" name="purge_scope" value="all" <?php checked( 'all', $this->get( 'purge_scope' ) ); ?>>
								Tutto il sito</label>
							<p class="description">
								"Le pagine coinvolte" include il permalink, la homepage, i feed e gli archivi che mostrano
								quel contenuto: un articolo non vive da solo. "Tutto il sito" è più sicuro ma rigenera molto.
							</p>
						</td>
					</tr>
					<?php
					$labels = array(
						'save_post'     => 'Pubblicazione o modifica di un contenuto',
						'delete_post'   => 'Eliminazione o cestinamento',
						'comment'       => 'Commento approvato o modificato',
						'switch_theme'  => 'Cambio di tema',
						'plugin_toggle' => 'Attivazione o disattivazione di un plugin',
						'nav_menu'      => 'Modifica di un menu',
						'term'          => 'Modifica di categorie o tag',
						'customizer'    => 'Salvataggio nel personalizzatore',
						'core_update'   => 'Aggiornamento di core, temi o plugin',
					);
					foreach ( $labels as $key => $label ) :
						?>
						<tr>
							<th scope="row"><?php echo esc_html( $label ); ?></th>
							<td><label><input type="checkbox" name="automations[<?php echo esc_attr( $key ); ?>]" value="1"
								<?php checked( ! empty( $this->settings['automations'][ $key ] ) ); ?>> Invalida</label></td>
						</tr>
					<?php endforeach; ?>
				</table>

				<h2>Preload</h2>
				<table class="form-table" role="presentation">
					<tr>
						<th scope="row">Riscaldamento</th>
						<td>
							<label><input type="checkbox" name="preload_enabled" value="1" <?php checked( $this->get( 'preload_enabled' ) ); ?>> Attivo</label>
							<p class="description">
								Dopo un'invalidazione le pagine vengono richieste in sottofondo, così il primo
								visitatore trova già la cache piena invece di aspettare PHP.
							</p>
						</td>
					</tr>
					<tr>
						<th scope="row">Dopo ogni svuotamento totale</th>
						<td><label><input type="checkbox" name="preload_on_purge" value="1" <?php checked( $this->get( 'preload_on_purge' ) ); ?>> Rimetti in coda la sitemap</label></td>
					</tr>
					<tr>
						<th scope="row"><label for="preload_batch">Ritmo</label></th>
						<td>
							<input id="preload_batch" type="number" min="1" max="50" name="preload_batch" value="<?php echo esc_attr( (string) $this->get( 'preload_batch' ) ); ?>" class="small-text"> pagine al minuto
							<p class="description">Il preload non deve pesare più del traffico che evita. Alzalo solo su macchine scariche.</p>
						</td>
					</tr>
				</table>

				<?php submit_button( 'Salva impostazioni' ); ?>
			</form>

			<h2>Come verificare</h2>
			<p class="description" style="max-width:52em">
				Ogni risposta porta con sé l'esito dei due livelli. Da terminale:
			</p>
			<pre style="background:#f6f7f7;padding:1rem;overflow:auto"><code>curl -sI <?php echo esc_html( home_url( '/' ) ); ?> | grep -i 'x-cache\|x-nginx-cache\|etag\|last-modified\|cache-control'</code></pre>
			<p class="description" style="max-width:52em">
				<code>X-Cache</code> è Varnish, <code>X-Nginx-Cache</code> è il livello su disco.
				Da loggato vedrai sempre <code>MISS</code> e <code>BYPASS</code>: è corretto.
			</p>
			<p class="description" style="max-width:52em">
				Per vedere un 304 servito davvero, rimandare indietro l'<code>ETag</code> ricevuto:
			</p>
			<pre style="background:#f6f7f7;padding:1rem;overflow:auto"><code>curl -sI <?php echo esc_html( home_url( '/' ) ); ?> -H 'If-None-Match: &lt;etag&gt;' | head -1</code></pre>
		</div>
		<?php
	}
}

Stack_Cache::instance();
