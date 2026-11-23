let values = require('values');
let strict_bool = values.strict_bool;
let ids = require('ids');
let platform_bool = values.platform_bool;
let as_list = values.as_list;
let as_word_list_or_null = values.as_word_list_or_null;
let is_valid_ipv4 = values.is_valid_ipv4;
let is_valid_cidr = values.is_valid_cidr;
let is_valid_cidr_any = values.is_valid_cidr_any;
let is_valid_ipv6 = values.is_valid_ipv6;
let is_valid_ipv6_cidr = values.is_valid_ipv6_cidr;
let netifd_int = values.netifd_int;
let netifd_string = values.netifd_string;
let ipv6_words = values.ipv6_words;

const PKG = "network";

// Linux IFNAMSIZ-1 caps the wireguard netdev name at 15 chars (netifd uses
// the section name as the kernel netdev); hyphens are valid in ifnames but
// uci section names reject them, so they're not in the charset either.
const IFNAMSIZ_RE = /^[A-Za-z][A-Za-z0-9_]{0,14}$/;

const VALID_PROTOS = {
	"static": true, "dhcp": true, "dhcpv6": true, "pppoe": true,
	"none": true, "ppp": true, "wwan": true, "wireguard": true, "openvpn": true,
};
const WG_KEY_RE = regexp("^" + values.WG_KEY_PATTERN + "$");
const VALID_REQADDRESS = { "try": true, "force": true, "none": true };
// Fields that apply only to some protos, after the proto scripts that read them and LuCI's
// forms. Every other field applies to every proto, because netifd reads it as a core interface
// attribute. A field outside its protos is hidden on read and dropped on write, and a request
// that names it is refused: netifd would ignore it, or toUci would drop it.
const FIELD_PROTOS = {
	ipaddr: [ "static" ], ipaddrs: [ "static" ], ip6addrs: [ "static" ],
	netmask: [ "static" ], broadcast: [ "static" ], gateway: [ "static" ], ip6gw: [ "static" ],
	ip6prefix: [ "static", "dhcpv6", "wireguard" ],
	broadcast_flag: [ "dhcp" ], hostname: [ "dhcp" ],
	clientid: [ "dhcp", "dhcpv6" ],
	reqaddress: [ "dhcpv6" ],
	reqprefix: [ "dhcpv6", "pppoe", "ppp" ],
	sourcefilter: [ "dhcpv6", "pppoe", "ppp" ],
	// netifd drops the DNS servers that openvpn-hotplug adds from a pushed dhcp-option when peerdns
	// is off, and the hotplug skips the host route to the server for nohostroute '1'.
	peerdns: [ "dhcp", "dhcpv6", "pppoe", "ppp", "wwan", "openvpn" ],
	private_key: [ "wireguard" ], has_private_key: [ "wireguard" ], listen_port: [ "wireguard" ],
	addresses: [ "wireguard" ], nohostroute: [ "wireguard", "openvpn" ],
	// ppp.sh hands them to pppd, and wwan to the handler of the modem that it finds.
	username: [ "pppoe", "ppp", "wwan", "openvpn" ], password: [ "pppoe", "ppp", "wwan", "openvpn" ],
	has_password: [ "pppoe", "ppp", "wwan", "openvpn" ],
};
const LOGIN = [ "username", "password" ];

// The options of /lib/netifd/proto/openvpn.sh that uapi models. Each field is the uci option of
// its name.
const OPENVPN = {};
for (let f in [ "client", "dev", "dev_type", "ovpnproto", "port", "lport", "rport", "remote", "local",
                "nobind", "float", "topology", "server", "server_bridge", "push", "route", "route_gateway",
                "ifconfig", "ifconfig_pool", "client_to_client", "duplicate_cn", "keepalive", "ping",
                "ping_restart", "persist_key", "persist_tun", "cipher", "auth", "data_ciphers", "tls_server",
                "tls_client", "tls_crypt", "ca", "cert", "dh", "crl_verify", "remote_cert_tls",
                "verify_x509_name", "user", "group", "log", "log_append", "verb", "mute", "config",
                "username", "key", "tls_auth", "pkcs12", "password", "cert_password",
                "has_key", "has_tls_auth", "has_pkcs12", "has_password", "has_cert_password" ]) {
	OPENVPN[f] = true;
	FIELD_PROTOS[f] ??= [ "openvpn" ];
}

// openvpn's --proto takes a family-agnostic form plus explicit v4 and v6 variants, and tcp has
// separate client and server spellings, which LuCI offers.
const VALID_OVPNPROTO = {
	"udp": true,  "tcp": true,  "tcp-client": true,  "tcp-server": true,
	"udp4": true, "tcp4": true, "tcp4-client": true, "tcp4-server": true,
	"udp6": true, "tcp6": true, "tcp6-client": true, "tcp6-server": true,
};
// The handler writes each value onto a line of openvpn's config, so a path excludes whitespace and
// shell meta.
const PATH_RE = /^\/[A-Za-z0-9_.+\/-]+$/;
const OPENVPN_PATHS = [ "ca", "cert", "key", "dh", "tls_auth", "tls_crypt", "pkcs12", "crl_verify",
                        "log", "log_append", "config" ];
// LuCI's `hostname` datatype, which its openvpn form takes for `local` beside an address.
const HOSTNAME_RE = /^([A-Za-z0-9_]+|[A-Za-z0-9_][A-Za-z0-9_.-]*[A-Za-z0-9]\.?)$/;

// The table judges only the protos uapi models. A handler such as 6in4 reads ipaddr and
// ip6prefix, and uapi cannot know what else, so on such a proto every field applies except those
// that are another reading of an option: uci `broadcast` there is no dhcp flag, and `server` there
// is no openvpn option. A has_ twin reads false where uci holds nothing, which on such a proto
// would show a field for an option that is absent. `password` there would be a secret that no read
// shows, so it stays out with its `username`.
function applies(field, proto) {
	let protos = FIELD_PROTOS[field];
	return protos == null || index(protos, proto) != -1
		|| (!VALID_PROTOS[proto] && field != "broadcast_flag" && !OPENVPN[field] && index(field, "has_") != 0);
}

// Fields that can hold several values, and their options. netifd hands a list to a handler only for
// an option that the handler declares as a list, and it publishes each declaration in
// get_proto_handlers: 6in4, gre, ipip and vxlan declare ipaddr as a string, and LuCI writes it as an
// option for them. Every handler that declares one of these as a string reads it from what netifd
// hands it. The ucode handler of wireguard declares no option and reads addresses from uci, so no
// declaration tells for addresses.
const LIST_OPTIONS = { ipaddrs: "ipaddr", ip6addrs: "ip6addr", ip6prefix: "ip6prefix" };

// netifd parses no listen_port: the wireguard handler gets the option as uci holds it and writes
// `ListenPort=%d` with ucode's int() of it, so `0x10` gives 0, `010` gives 10 and `1194x` gives
// 1194. A name or a list gives no number and port 0, so wg listens on a port that the kernel picks,
// as with no option. wg refuses a port outside 0 to 65535, with the whole config, which reads -1.
function listen_port(v) {
	let n = (type(v) == "string") ? int(v) : null;
	if (type(n) != "int") return null;
	return (n >= 0 && n <= 65535) ? n : -1;
}

const OVPN_BOOL = " Only a stored `1` or `true` reads true: netifd drops another value, and the handler then passes no flag.";
const OVPN_FILE = " The handler leaves the option out when the file does not exist at ifup, so openvpn then runs as if it were unset. A write does not check that the file exists.";
const OVPN_LIST = " Always an array. netifd splits an option that is not a uci list into its words, and the handler gives openvpn each as an entry of its own, so such an option reads as its words.";
const OVPN_SECRET = " Write-only: a read gives `has_%s`. A null, or a write that leaves it out, keeps the stored value, an empty string removes it, and a switch to another proto removes it.";

const ONE_VALUE = " On a proto that uapi does not model, such as 6in4, one value is stored as an option, as LuCI writes it, and a write refuses several when the handler reads the option as one value, as netifd publishes it in `get_proto_handlers`: netifd hands such a handler no uci list.";

function handler_options(conn, proto) {
	if (conn == null || type(proto) != "string" || VALID_PROTOS[proto]) return null;
	let handlers = null;
	try { handlers = conn.call("network", "get_proto_handlers"); } catch (e) {}
	return handlers?.[proto]?.validate;
}

function one_value(declared) {
	return type(declared) == "string" && substr(declared, 0, 5) != "list(";
}

// One entry per group of fields that share their protos: on the other modelled protos, each
// field must be null. Generated from FIELD_PROTOS so the document and validate() cannot drift.
function proto_scope_conditionals() {
	let groups = {};
	for (let field, protos in FIELD_PROTOS) {
		let key = join(",", protos);
		if (groups[key] == null)
			groups[key] = { others: filter(keys(VALID_PROTOS), (p) => index(protos, p) == -1), fields: {} };
		groups[key].fields[field] = { type: "null" };
	}
	let out = [];
	for (let key, g in groups)
		push(out, { if: { properties: { proto: { enum: g.others } }, required: [ "proto" ] },
		            then: { properties: g.fields } });
	return out;
}

function fetch_runtime(conn, name) {
	if (conn == null || type(name) != "string" || name == "")
		return {};
	let status = null;
	try { status = conn.call("network.interface." + name, "status"); }
	catch (e) { return {}; }
	if (status == null) return {};
	// ubus emits hyphenated keys (ipv4-address, ipv6-address, ipv6-prefix).
	// Hyphenated identifiers are the only ones in our API surface that need
	// quoting in HCL/Go field tags; remap to snake_case to match the rest.
	return {
		up: !!status.up,
		pending: !!status.pending,
		available: !!status.available,
		// What netifd is actually running, which is not always what uci asks
		// for. netifd registers protocol handlers by scanning
		// /lib/netifd/proto at startup and caches the result: a reload does not
		// rescan, only a restart does. So a protocol whose package is absent, or
		// was installed after netifd started, is silently discarded and reported
		// as "none" while uci still holds the requested value. Comparing this
		// against `proto` is the only way to see that from outside.
		effective_proto: status.proto ?? null,
		l3_device: status.l3_device ?? null,
		uptime: status.uptime ?? null,
		ipv4_address: status["ipv4-address"] ?? [],
		ipv6_address: status["ipv6-address"] ?? [],
		ipv6_prefix:  status["ipv6-prefix"]  ?? [],
		route: status.route ?? [],
	};
}

function fromUci(section, conn) {
	let anonymous = !!section['.anonymous'];
	let proto = section.proto ?? "none";
	// Modern OpenWrt (25+) writes `list ipaddr` for multi-address static
	// interfaces (e.g. loopback ships as `list ipaddr '127.0.0.1/8'`), while
	// older configs used `option ipaddr 'x.x.x.x'`. Surface BOTH forms:
	// `ipaddr` keeps the v1.0/v1.1 contract (a single string; the first entry
	// when uci has a list), and a new `ipaddrs` array holds the full set.
	// netifd reads a scalar as whitespace-separated words, and `option ipaddr ''` as nothing.
	let ipaddrs = as_word_list_or_null(section.ipaddr);
	let ipaddr_first = (ipaddrs != null) ? ipaddrs[0] : null;
	let view = {
		id: section['.name'],
		managed: !anonymous,
		device: section.device ?? null,
		proto: proto,
		ipaddr: ipaddr_first,
		ipaddrs: ipaddrs,
		// uci holds IPv6 static addressing in a separate `list ip6addr`, and modelling only
		// the v4 list made an IPv6-addressed interface read back with no addresses at all and
		// no indication that a value had been seen and dropped.
		ip6addrs: as_word_list_or_null(section.ip6addr),
		netmask: section.netmask ?? null,
		gateway: section.gateway ?? null,
		broadcast: section.broadcast ?? null,
		ip6gw: section.ip6gw ?? null,
		ip6prefix: as_word_list_or_null(section.ip6prefix),
		dns: as_word_list_or_null(section.dns),
		// netifd reads the ip6assign group for every proto. It once lived in the dhcpv6 block, whose
		// script never reads ip6hint, so a static LAN wrote it into nothing and a PUT erased LuCI's.
		ip6assign: netifd_int(section.ip6assign),
		ip6hint: section.ip6hint ?? null,
		ip6ifaceid: section.ip6ifaceid ?? null,
		ip6class: as_word_list_or_null(section.ip6class),
		ip6weight: netifd_int(section.ip6weight),
		mtu: netifd_int(section.mtu),
		auto: platform_bool(section.auto, true),
		// `auto` controls bring-up at boot; `disabled` is stronger and separate: netifd
		// does not register the interface at all, so it has no ubus object and its
		// addresses, routes and peers go with it. Unmodelled, that box reads as ordinary
		// active config, which is the one thing a read must never do.
		//
		// netifd compares the option against "1" and, since e97e36f (2026-07-16), "true", and
		// takes anything else as enabled.
		disabled: platform_bool(section.disabled, false),
		ip4table: section.ip4table ?? null,
		ip6table: section.ip6table ?? null,
		metric: netifd_int(section.metric),
		// The booleans below read null when uci has nothing explicitly set. Surfacing the daemon's
		// effective default would have the patch merge write it into uci on the next PATCH,
		// silently changing the section's surface area for the client.
		defaultroute: (section.defaultroute != null) ? platform_bool(section.defaultroute, true) : null,
		delegate: (section.delegate != null) ? platform_bool(section.delegate, true) : null,
		peerdns: (section.peerdns != null) ? platform_bool(section.peerdns, true) : null,
		// On proto dhcp, uci's `broadcast` is the flag dhcp.sh passes to udhcpc as -B, not an
		// address, so the static reader turned LuCI's `broadcast '1'` into an address that a PUT
		// of the read then refused.
		broadcast_flag: (section.broadcast != null) ? platform_bool(section.broadcast, false) : null,
		hostname: section.hostname ?? null,
		clientid: section.clientid ?? null,
		reqprefix: section.reqprefix ?? null,
		reqaddress: section.reqaddress ?? null,
		sourcefilter: (section.sourcefilter != null) ? platform_bool(section.sourcefilter, true) : null,
		listen_port: listen_port(section.listen_port),
		addresses: as_word_list_or_null(section.addresses),
		nohostroute: strict_bool(section.nohostroute),
		has_private_key: (section.private_key != null && section.private_key != ""),
		// netifd hands the openvpn handler each option through uci's blob converter, as the handler
		// declares it: a boolean takes 1 or true, an integer reads as strtol in base 0, a string
		// drops a list, and a list splits an option into words.
		client: platform_bool(section.client, false),
		dev: netifd_string(section.dev),
		dev_type: netifd_string(section.dev_type),
		ovpnproto: netifd_string(section.ovpnproto),
		port: netifd_int(section.port),
		lport: netifd_int(section.lport),
		rport: netifd_int(section.rport),
		remote: as_word_list_or_null(section.remote),
		local: netifd_string(section.local),
		nobind: platform_bool(section.nobind, false),
		float: platform_bool(section.float, false),
		topology: netifd_string(section.topology),
		server: netifd_string(section.server),
		server_bridge: netifd_string(section.server_bridge),
		push: as_word_list_or_null(section.push),
		route: as_word_list_or_null(section.route),
		route_gateway: netifd_string(section.route_gateway),
		ifconfig: netifd_string(section.ifconfig),
		ifconfig_pool: netifd_string(section.ifconfig_pool),
		client_to_client: platform_bool(section.client_to_client, false),
		duplicate_cn: platform_bool(section.duplicate_cn, false),
		keepalive: netifd_string(section.keepalive),
		ping: netifd_int(section.ping),
		ping_restart: netifd_int(section.ping_restart),
		persist_key: platform_bool(section.persist_key, false),
		persist_tun: platform_bool(section.persist_tun, false),
		cipher: netifd_string(section.cipher),
		auth: netifd_string(section.auth),
		data_ciphers: as_word_list_or_null(section.data_ciphers),
		tls_server: platform_bool(section.tls_server, false),
		tls_client: platform_bool(section.tls_client, false),
		tls_crypt: netifd_string(section.tls_crypt),
		ca: netifd_string(section.ca),
		cert: netifd_string(section.cert),
		dh: netifd_string(section.dh),
		crl_verify: netifd_string(section.crl_verify),
		remote_cert_tls: netifd_string(section.remote_cert_tls),
		verify_x509_name: netifd_string(section.verify_x509_name),
		user: netifd_string(section.user),
		group: netifd_string(section.group),
		log: netifd_string(section.log),
		log_append: netifd_string(section.log_append),
		verb: netifd_int(section.verb),
		mute: netifd_int(section.mute),
		config: netifd_string(section.config),
		username: netifd_string(section.username),
		has_key: (section.key != null && section.key != ""),
		has_tls_auth: (section.tls_auth != null && section.tls_auth != ""),
		has_pkcs12: (section.pkcs12 != null && section.pkcs12 != ""),
		has_password: (section.password != null && section.password != ""),
		has_cert_password: (section.cert_password != null && section.cert_password != ""),
		runtime: fetch_runtime(conn, section['.name']),
	};
	for (let field in FIELD_PROTOS)
		if (!applies(field, proto) || (!VALID_PROTOS[proto] && view[field] == null))
			delete view[field];
	return view;
}

function toUci(body) {
	let json = {};
	for (let k, v in body)
		if (applies(k, body.proto)) json[k] = v;
	let out = {};
	if (json.device != null) out.device = json.device;
	if (json.proto != null) out.proto = json.proto;
	// On a proto that uapi does not model, one value is written as an option, which a handler takes
	// whether it declares a string or a list. netifd's static handler takes a list.
	let form = (v) => (!VALID_PROTOS[json.proto] && length(v) == 1) ? v[0] : v;
	if (type(json.ipaddrs) == "array" && length(json.ipaddrs) > 0)
		out.ipaddr = form(json.ipaddrs);
	if (type(json.ip6addrs) == "array" && length(json.ip6addrs) > 0)
		out.ip6addr = form(json.ip6addrs);

	if (json.netmask != null) out.netmask = json.netmask;
	if (json.gateway != null) out.gateway = json.gateway;
	if (json.broadcast != null) out.broadcast = json.broadcast;
	if (json.ip6gw != null) out.ip6gw = json.ip6gw;
	// One prefix is written as a scalar: uci's blob.c drops a list given to a string attribute,
	// and 6rd, map and 464xlat read ip6prefix as one string.
	if (type(json.ip6prefix) == "array" && length(json.ip6prefix) > 0)
		out.ip6prefix = (length(json.ip6prefix) > 1) ? json.ip6prefix : json.ip6prefix[0];
	if (type(json.dns) == "array" && length(json.dns) > 0) out.dns = json.dns;
	if (json.ip6assign != null) out.ip6assign = "" + json.ip6assign;
	if (json.ip6hint != null) out.ip6hint = json.ip6hint;
	if (json.ip6ifaceid != null) out.ip6ifaceid = json.ip6ifaceid;
	if (type(json.ip6class) == "array" && length(json.ip6class) > 0) out.ip6class = json.ip6class;
	if (json.ip6weight != null) out.ip6weight = "" + json.ip6weight;
	if (json.mtu != null) out.mtu = "" + json.mtu;
	if (json.auto != null) out.auto = json.auto ? "1" : "0";
	if (json.disabled != null) out.disabled = json.disabled ? "1" : "0";
	if (json.ip4table != null) out.ip4table = "" + json.ip4table;
	if (json.ip6table != null) out.ip6table = "" + json.ip6table;
	if (json.metric != null) out.metric = "" + json.metric;
	if (json.defaultroute != null) out.defaultroute = json.defaultroute ? "1" : "0";
	if (json.delegate != null) out.delegate = json.delegate ? "1" : "0";
	if (json.peerdns != null) out.peerdns = json.peerdns ? "1" : "0";
	if (json.broadcast_flag != null) out.broadcast = json.broadcast_flag ? "1" : "0";
	if (json.hostname != null) out.hostname = json.hostname;
	if (json.clientid != null) out.clientid = json.clientid;
	if (json.reqprefix != null) out.reqprefix = "" + json.reqprefix;
	if (json.reqaddress != null) out.reqaddress = json.reqaddress;
	if (json.sourcefilter != null) out.sourcefilter = json.sourcefilter ? "1" : "0";
	if (json.private_key != null) out.private_key = json.private_key;
	if (json.listen_port != null) out.listen_port = "" + json.listen_port;
	if (type(json.addresses) == "array" && length(json.addresses) > 0)
		out.addresses = json.addresses;
	if (json.nohostroute != null) out.nohostroute = json.nohostroute ? "1" : "0";
	for (let k in [ "client", "nobind", "float", "client_to_client", "duplicate_cn", "persist_key",
	                "persist_tun", "tls_server", "tls_client" ])
		if (json[k] != null) out[k] = json[k] ? "1" : "0";
	for (let k in [ "port", "lport", "rport", "ping", "ping_restart", "verb", "mute" ])
		if (json[k] != null) out[k] = "" + json[k];
	for (let k in [ "remote", "push", "route", "data_ciphers" ])
		if (type(json[k]) == "array" && length(json[k]) > 0) out[k] = json[k];
	for (let k in [ "dev", "dev_type", "ovpnproto", "local", "topology", "server", "server_bridge",
	                "route_gateway", "ifconfig", "ifconfig_pool", "keepalive", "cipher", "auth", "tls_crypt",
	                "ca", "cert", "dh", "crl_verify", "remote_cert_tls", "verify_x509_name", "user", "group",
	                "log", "log_append", "config", "username", "key", "tls_auth", "pkcs12", "password",
	                "cert_password" ])
		if (json[k] != null) out[k] = json[k];
	// A switch sends the login as null. A PATCH deletes only what the read of the old proto shows,
	// so this clear also reaches a login that the read hides, as on qmi. On a proto that uapi does
	// not model, the handler can read the login, so a null there keeps it.
	for (let k in LOGIN)
		if (exists(body, k) && body[k] == null && VALID_PROTOS[body.proto]) out[k] = [];
	return out;
}

function validate(json, conn, id, delta, partial) {
	let errs = [];

	values.require_present(errs, json, "proto");

	// Only what the request named, which is not what the write leaves: a PATCH that switches proto
	// still carries the old proto's fields in its merged view, and the write drops them. The
	// read-only twins never write, and an empty value asks for nothing, as a module that writes
	// `cond ? [...] : []` sends.
	let named = delta ?? json;
	// Here rather than as an enum in schema_properties, which the Response would then declare
	// although a read answers any proto that uci stores. netifd takes such a proto, as the qmi wan
	// that config_generate writes on an LTE router, so a stored one is no error of the section, and
	// a PATCH that leaves it out keeps the options of its handler, which toUci cannot emit. A PUT
	// sends the proto, and would delete those options.
	if (named.proto != null && type(json.proto) == "string" && !VALID_PROTOS[json.proto])
		push(errs, { field: "proto", code: "not_in_enum",
		             message: sprintf("must be one of %s: uapi does not write proto %s. A PATCH that leaves proto out keeps the options that its handler reads",
		                              join(", ", keys(VALID_PROTOS)), json.proto) });
	if (type(json.proto) == "string")
		for (let field, v in named) {
			if (v == null || v === "" || (type(v) == "array" && length(v) == 0)
			    || field == "ipaddr" || index(field, "has_") == 0 || applies(field, json.proto))
				continue;
			let protos = FIELD_PROTOS[field];
			push(errs, { field, code: "conflict",
			             message: sprintf("applies only when proto is %s; send null or leave it out",
			                              length(protos) == 1 ? protos[0] : "one of " + join(", ", protos)) });
		}

	// `id` is the universal section-name input and goes through the framework's
	// validate_section_id for the broader uci section-name rules; the tighter IFNAMSIZ
	// cap below applies only where netifd uses the section name as the kernel netdev name.
	if (id != null && json.id != null && json.id != id)
		push(errs, { field: "id", code: "read_only",
		             message: "id can only be set at create time; rename via DELETE + POST" });
	// For proto=wireguard, the IFNAMSIZ-tight cap is a kernel constraint:
	// netifd uses the uci section name as the netdev name and Linux's
	// IFNAMSIZ limits that to 15 chars. Tighten beyond the framework's
	// 32-char default when the caller supplied `id` directly on a
	// wireguard interface.
	if (id == null && json.id != null && json.proto == "wireguard"
	    && (type(json.id) != "string" || !match(json.id, IFNAMSIZ_RE)))
		push(errs, { field: "id", code: "invalid_format",
		             message: "must match [A-Za-z][A-Za-z0-9_]{0,14} (proto=wireguard binds the uci section name to the kernel netdev name; IFNAMSIZ caps it at 15 chars)" });

	// Each format check runs only where its field applies. Elsewhere toUci drops the field and
	// the check above refuses a request that names it, so a stale value stored under another
	// proto must not block the PATCH that switches away from it.
	let ok = (field) => applies(field, json.proto);
	let handler = handler_options(conn, json.proto);
	for (let field, opt in LIST_OPTIONS)
		if (ok(field) && length(as_word_list_or_null(json[field])) > 1 && one_value(handler?.[opt]))
			push(errs, { field, code: "conflict",
			             message: sprintf("must hold one value on proto %s: its handler reads %s as one value, and netifd hands it no list", json.proto, opt) });
	// A uci list never reaches a handler that reads the option as one value: on 6in4 the tunnel took
	// the wan address and no IPv6 address. The read shows the value, so only the stored form tells,
	// and a write that names the field stores one value as an option.
	let raw = (handler != null && id != null) ? conn.uci_get(PKG, id) : null;
	for (let field, opt in LIST_OPTIONS)
		if (!exists(named, field) && type(raw?.[opt]) == "array" && length(raw[opt]) == 1 && one_value(handler[opt]))
			push(errs, { field, code: "conflict",
			             message: sprintf("is stored as a uci list, which netifd does not hand to the %s handler, since it reads %s as one value. A PATCH that sends the value stores it as an option", json.proto, opt) });
	if (ok("netmask") && json.netmask != null && json.netmask != "" && !is_valid_ipv4(json.netmask))
		push(errs, { field: "netmask", code: "invalid_format",
		             message: "must be a valid IPv4 netmask" });
	if (ok("gateway") && json.gateway != null && json.gateway != "" && !is_valid_ipv4(json.gateway))
		push(errs, { field: "gateway", code: "invalid_format",
		             message: "must be a valid IPv4 address" });
	if (ok("broadcast") && json.broadcast != null && json.broadcast != "" && !is_valid_ipv4(json.broadcast))
		push(errs, { field: "broadcast", code: "invalid_format",
		             message: "must be a valid IPv4 address" });
	// netifd wants a bare address for the gateway and accepts a prefix length on the routed
	// prefix, which is the same split LuCI encodes as ip6addr("nomask") against ip6addr.
	if (ok("ip6gw") && json.ip6gw != null && json.ip6gw != "" && !is_valid_ipv6(json.ip6gw))
		push(errs, { field: "ip6gw", code: "invalid_format",
		             message: "must be a valid IPv6 address without a prefix length" });
	let ip6prefix = (ok("ip6prefix") && type(json.ip6prefix) == "array") ? json.ip6prefix : null;
	for (let i = 0; i < length(ip6prefix); i++)
		if (type(ip6prefix[i]) == "string" && !is_valid_ipv6_cidr(ip6prefix[i]) && !is_valid_ipv6(ip6prefix[i]))
			push(errs, { field: sprintf("ip6prefix[%d]", i), code: "invalid_format",
			             message: "must be a valid IPv6 address or prefix" });
	for (let i = 0; ok("ipaddrs") && type(json.ipaddrs) == "array" && i < length(json.ipaddrs); i++) {
		if (!is_valid_ipv4(json.ipaddrs[i]) && !is_valid_cidr(json.ipaddrs[i]))
			push(errs, { field: sprintf("ipaddrs[%d]", i), code: "invalid_format",
			             message: "must be a valid IPv4 address or CIDR" });
	}
	for (let i = 0; ok("ip6addrs") && type(json.ip6addrs) == "array" && i < length(json.ip6addrs); i++) {
		if (!is_valid_ipv6(json.ip6addrs[i]) && !is_valid_ipv6_cidr(json.ip6addrs[i]))
			push(errs, { field: sprintf("ip6addrs[%d]", i), code: "invalid_format",
			             message: "must be a valid IPv6 address or CIDR" });
	}

	if (json.proto == "static") {
		// One address family is enough, matching LuCI, whose static form marks neither
		// `ipaddr` nor `ip6addr` required. Demanding IPv4 made an IPv6-only interface
		// unwritable and so unable to round-trip its own read.
		//
		// The read-only `ipaddr` deliberately does not count. Only `ipaddrs` and `ip6addrs`
		// write, so a body carrying the scalar alone once satisfied the requirement and then
		// wrote nothing: uapi created an addressless static interface and answered 200.
		let has_list = type(json.ipaddrs) == "array" && length(json.ipaddrs) > 0;
		let has_v6 = type(json.ip6addrs) == "array" && length(json.ip6addrs) > 0;
		if (!has_list && !has_v6)
			push(errs, { field: "ipaddrs", code: "required",
			             message: "either ipaddrs or ip6addrs is required when proto is static" });
	}

	if (json.proto == "wireguard") {
		if (json.private_key == null || json.private_key == "")
			push(errs, { field: "private_key", code: "required",
			             message: "is required when proto is wireguard" });
		// A write carries the stored key forward, so the message has to say how to replace one.
		else if (!match(json.private_key, WG_KEY_RE))
			push(errs, { field: "private_key", code: "invalid_format",
			             message: "must be a 44-char base64 WireGuard private key as wg genkey prints it: send a new one to replace a stored key that wg refuses" });
		let addrs = as_list(json.addresses);
		if (length(addrs) == 0)
			push(errs, { field: "addresses", code: "required",
			             message: "is required when proto is wireguard (list of CIDRs)" });
		for (let i = 0; i < length(addrs); i++) {
			// Both families: a wireguard tunnel's own address list is routinely v6 or
			// dual-stack, netifd's handler parses either, and `ipaddr`/`ipaddrs` above
			// stay v4-only because those are the static-proto v4 fields.
			if (!is_valid_cidr_any(addrs[i]))
				push(errs, { field: sprintf("addresses[%d]", i), code: "invalid_format",
				             message: "must be a valid IPv4 or IPv6 CIDR" });
		}
	}

	for (let field in OPENVPN_PATHS)
		if (ok(field) && json[field] != null && json[field] != "" && (type(json[field]) != "string" || !match(json[field], PATH_RE)))
			push(errs, { field, code: "invalid_format",
			             message: "must be an absolute filesystem path without whitespace or shell meta" });
	if (ok("local") && type(json.local) == "string" && json.local != "" && !values.is_valid_ip(json.local)
	    && (length(json.local) > 253 || !match(json.local, HOSTNAME_RE) || !match(json.local, /[^0-9.]/)))
		push(errs, { field: "local", code: "invalid_format",
		             message: "must be an IP address or a host name" });
	// options.c of openvpn 2.7 stores each --data-ciphers over the one before it.
	if (ok("data_ciphers") && type(json.data_ciphers) == "array" && length(json.data_ciphers) > 1)
		push(errs, { field: "data_ciphers", code: "conflict",
		             message: "must hold one entry: the handler gives openvpn each entry as a --data-ciphers of its own, and openvpn keeps only the last. Join the ciphers with colons in one entry, such as AES-256-GCM:CHACHA20-POLY1305" });

	// These follow LuCI. netifd parses ip6hint with strtol(v, NULL, 16), so a prefix such as
	// 2001:db8::/56 was not ignored: it became subnet 0x2001. An empty string clears the option.
	if (json.ip6hint != null && json.ip6hint != "") {
		let m = match(json.ip6hint, /^(0x)?([0-9A-Fa-f]+)$/);
		let digits = (m != null) ? ltrim(m[2], "0") : null;
		if (digits == null || length(digits) > 8 || hex(digits) >= 0xffffffff)
			push(errs, { field: "ip6hint", code: "invalid_format",
			             message: "must be a hexadecimal subnet id below 0xffffffff, such as 1 or 0x1f" });
	}
	if (json.ip6ifaceid != null && json.ip6ifaceid != "" && json.ip6ifaceid != "eui64" && json.ip6ifaceid != "random") {
		let w = ipv6_words(json.ip6ifaceid);
		if (w == null || w[0] || w[1] || w[2] || w[3])
			push(errs, { field: "ip6ifaceid", code: "invalid_format",
			             message: "must be eui64, random, or an interface id whose network half is zero, such as ::1" });
	}
	// conn still holds the section as it was, because validation runs before the write is staged.
	// A name that the server generates has no stored options.
	let name = id ?? json.id;
	let old = (json.proto == "wireguard" && conn != null && name != null) ? conn.uci_get(PKG, name) : null;
	// The schema allows -1 because a read reports a stored port outside 0 to 65535 as -1.
	if (ok("listen_port") && json.listen_port === -1)
		push(errs, { field: "listen_port", code: "out_of_range",
		             message: "must be from 0 to 65535: -1 is how a stored port outside that range reads, and wg cannot bring the interface up with it" });
	// A PATCH keeps an option that it leaves out, and deletes only what the read of the old proto
	// shows. That read hides listen_port, so the check above cannot see a hand-written value that a
	// switch to wireguard keeps, and a null in the switch cannot remove it. LuCI saves such a switch
	// and refuses the value at the next save of its wireguard form.
	if (partial && old != null && !applies("listen_port", old.proto) && json.listen_port == null
	    && listen_port(old.listen_port) === -1)
		push(errs, { field: "listen_port", code: "conflict",
		             message: "must be sent as a port in a PATCH that switches to wireguard: uci holds a listen_port outside 0 to 65535, which the read of the old proto does not show, and wg cannot bring the interface up with it. Send a port from 0 to 65535, or switch with a PUT, which removes it" });
	// odhcp6c takes -P<len> or -P<prefix>/<len>, and LuCI documents both forms.
	let prefix = (type(json.reqprefix) == "string") ? replace(json.reqprefix, /(\/[0-9]+):[0-9A-Fa-f]{1,8}$/, "$1") : null;
	if (ok("reqprefix") && prefix != null && index(prefix, "/") != -1 && !is_valid_ipv6_cidr(prefix))
		push(errs, { field: "reqprefix", code: "invalid_format",
		             message: "must be auto, no, a prefix length, or an IPv6 prefix such as 2001:db8::/56" });
	// The schema allows the whole range so that a stored value reads as it is. ppp.sh hands the
	// mtu to pppd, which exits outside 128..16384 and leaves the interface down. Elsewhere netifd
	// applies a device mtu only from 68 up, and the wireguard handler applies a smaller one, which
	// leaves the device with no IPv4 address while netifd reports the interface up.
	if (type(json.mtu) == "int") {
		if (json.proto == "ppp" || json.proto == "pppoe") {
			if (json.mtu < 128 || json.mtu > 16384)
				push(errs, { field: "mtu", code: "out_of_range",
				             message: "must be from 128 to 16384: pppd refuses anything else and leaves the interface down" });
		}
		else if (json.mtu < 68)
			push(errs, { field: "mtu", code: "out_of_range",
			             message: "must be at least 68: netifd ignores a smaller device mtu, and a WireGuard device below 68 carries no IPv4" });
	}
	if (type(json.ip6class) == "array")
		for (let i = 0; i < length(json.ip6class); i++)
			if (type(json.ip6class[i]) != "string" || !match(json.ip6class[i], /^[A-Za-z0-9_]+$/))
				push(errs, { field: sprintf("ip6class[%d]", i), code: "invalid_format",
				             message: "must be local or an interface name" });

	return errs;
}

return {
	package: PKG,
	type: "interface",
	reload: ["network"],
	// odhcpd reads this config and has a procd trigger on it. dnsmasq and unbound, which LuCI's
	// ucitrack also reloads, read only ula_prefix and the interface names here: see docs/raw.md.
	reload_if_running: ["odhcpd"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	// netifd restarts a wireguard interface that a write changes or creates, and wg refuses the
	// config of the whole interface for one stored peer, so the kernel apply names such a peer.
	kernel_ops: (kind, opts, sec_type, existing, staged) =>
		(staged?.proto == "wireguard") ? [ { iface: staged['.name'], action: "check" } ] : [],
	// A static interface takes `option ipaddr` and `list ipaddr` alike, so a PATCH that sends its
	// address back writes nothing there.
	rewrite_when_named: (view) => VALID_PROTOS[view.proto] ? {} : LIST_OPTIONS,
	// Each proto sends the login to another party: a switch from pppoe to openvpn that kept it gave
	// the ISP login to the VPN server.
	clear_on_switch: { proto: LOGIN },
	// Opt in to the advisory management-path warning. Only this resource carries the
	// fields that can move the caller's own path, and `disabled` on a peer or a rule is
	// not the same condition, so the framework is told rather than guessing.
	mgmt_path_guard: true,
	// Caller-supplied name wins. proto=wireguard falls back to a 14-char
	// wg_<rand> (netifd's IFNAMSIZ constraint), and proto=openvpn to a 15-char
	// vpn_<rand>, within the 15 chars that LuCI takes for an interface name.
	// Other protos return null so handler.create emits the standard 28-char ULID.
	id_for_create: function(body) {
		if (body == null) return null;
		if (body.proto == "wireguard") return ids.new_id("wg", 11);
		if (body.proto == "openvpn") return ids.new_id("vpn", 11);
		return null;
	},
	openapi_singular: "network interface",
	openapi_required: ["proto"],
	openapi_conditional: [
		{ if:   { properties: { proto: { const: "static" } }, required: ["proto"] },
		  then: { anyOf: [
		            { required: ["ipaddr"] },
		            { required: ["ipaddrs"] },
		            { required: ["ip6addrs"] },
		          ] } },
		// private_key is write-only; GET surfaces only has_private_key, so listing
		// it in `required` would make strict OpenAPI client codegen reject reads.
		// validate() enforces presence on create.
		{ if:   { properties: { proto: { const: "wireguard" } }, required: ["proto"] },
		  then: { required: ["addresses"] } },
		...proto_scope_conditionals(),
	],
	openapi_write_conditional: [
		{ if:   { properties: { proto: { enum: [ "ppp", "pppoe" ] } }, required: ["proto"] },
		  then: { properties: { mtu: { minimum: 128, maximum: 16384 } } } },
	],
	openapi_runtime: {
		type: "object",
		description: "Populated from ubus network.interface.<name> status; empty {} when the interface has no runtime state.",
		properties: {
			up:               { type: "boolean" },
			pending:          { type: "boolean" },
			available:        { type: "boolean" },
			effective_proto:  { type: ["string", "null"],
			                    description: "The protocol netifd is actually running for this interface. Differs from the configured `proto` when no handler is registered for it, in which case netifd reports `none` and the interface is inert; a mismatch means the device needs the handler package and a networking restart." },
			l3_device:        { type: ["string", "null"] },
			uptime:           { type: ["integer", "null"], minimum: 0 },
			ipv4_address:     { type: "array", items: { type: "object" } },
			ipv6_address:     { type: "array", items: { type: "object" } },
			ipv6_prefix:      { type: "array", items: { type: "object" } },
			route:            { type: "array", items: { type: "object" } },
		},
	},
	schema_properties: {
		proto: { type: "string", default: "none", "x-uapi-write": { enum: keys(VALID_PROTOS) },
		         description: "Interface protocol. Several values need a handler package on the device: wwan needs `wwan`, wireguard needs `wireguard-tools`, dhcpv6 needs `odhcp6c`, ppp/pppoe need `ppp`, and openvpn needs `openvpn-openssl`, or its `openvpn-mbedtls` or `openvpn-wolfssl` variant. When the handler is missing, the write still succeeds, the interface is inert, and `runtime.effective_proto` reads `none`. netifd loads its handlers when it starts, so a handler package installed later takes effect after a reboot or `/etc/init.d/network restart`. A read answers any proto that uci stores, such as the `6in4` that LuCI writes or the `qmi` that an LTE router ships, while a write takes only the protos that the request schema lists. Another proto is no error of the section: a PATCH that leaves `proto` out passes and keeps the options that its handler reads, and the validation sweep does not list it. A write that leaves a wireguard interface enabled keeps its commit while an enabled `network/wireguard_peers` of the interface holds a value that makes wg refuse the whole interface, and answers `X-Kernel-Status: blocked` with `X-Kernel-Blocked`, which names each such peer." },
		id:        { type: "string", pattern: "^[A-Za-z][A-Za-z0-9_]{0,31}$",
		             description: "Create-time only; picks the uci section name (which becomes the uapi `id` field). When omitted, the server emits a 14-char `wg_<rand>` for proto=wireguard (fits Linux IFNAMSIZ for the kernel netdev), a 15-char `vpn_<rand>` for proto=openvpn, or a 28-char ULID otherwise. Useful for LuCI parity (`lan`, `wan`, `guest`) and readable cross-references. For proto=wireguard the value must additionally fit IFNAMSIZ (15 chars max). The pattern applies to the create only: a section that LuCI or a shell named otherwise, such as `4g`, takes every other write." },
		device:    { type: ["string", "null"],
		             description: "Physical or logical L2 device this interface binds to" },
		ipaddr:    { type: ["string", "null"], readOnly: true,
		             description: "First entry of the uci `list ipaddr`. Read-only: send `ipaddrs` to write, which names the same uci option." },
		ipaddrs:   { type: ["array", "null"], items: { type: "string" },
		             description: "Full IPv4 address list for static proto (uci `list ipaddr`). The only write name for this option; `ipaddr` is the read-only first entry." + ONE_VALUE },
		ip6addrs:  { type: ["array", "null"], items: { type: "string" },
		             description: "IPv6 address list for static proto (uci `list ip6addr`). A static interface needs either this or `ipaddrs`, not both." + ONE_VALUE },
		netmask:   { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		             description: "IPv4 netmask (static proto)" },
		broadcast: { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		             description: "IPv4 broadcast address (static proto). On proto dhcp the same uci option is a flag, `broadcast_flag`." },
		ip6gw:     { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		             description: "IPv6 default gateway, a bare address with no prefix length (static proto)" },
		ip6prefix: { type: ["array", "null"], "x-uapi-clear-on-omit": true,
		             items: { type: "string" },
		             description: "IPv6 prefixes routed to this device for delegation to clients (static, dhcpv6, wireguard). Always an array in both directions." + ONE_VALUE },
		gateway:   { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		             description: "IPv4 default gateway (static proto)" },
		dns:       { type: ["array", "null"], items: { type: "string" },
		             description: "DNS servers that netifd sets for this interface. On proto openvpn too, this is netifd's list and not openvpn's own `--dns`, which uapi does not model: a write stores a uci list, which the openvpn handler does not take for its `dns` option." },
		ip6assign: { type: ["integer", "null"], minimum: 0, maximum: 128,
		             description: "Prefix length to assign downstream from a delegated prefix" },
		ip6hint:   { type: ["string", "null"],
		             description: "Hexadecimal subnet id that picks which part of a delegated or ULA prefix this interface gets, such as `1` or `0x1f`, below `0xffffffff`. netifd uses it only when `ip6assign` is set, from 33 to 64." },
		ip6ifaceid: { type: ["string", "null"],
		             description: "Interface id of the address this interface takes from an assigned prefix: `eui64`, `random`, or a fixed id whose network half is zero, such as `::1`. On proto dhcpv6, odhcp6c also uses it for the upstream address." },
		ip6class:  { type: ["array", "null"], items: { type: "string" },
		             description: "Prefix classes this interface may take its assignment from: `local` for the ULA prefix, or the name of the interface that received the prefix. Unset means any." },
		ip6weight: { type: ["integer", "null"], minimum: -2147483648, maximum: 2147483647, "x-uapi-write": { minimum: 0 },
		             description: "Assignment preference: when several interfaces share a prefix, the ones with a higher weight get their subnet first." },
		mtu:       { type: ["integer", "null"], minimum: 0, maximum: 65535, "x-uapi-write": { minimum: 68 },
		             description: "MTU that netifd applies to the interface's devices, from 68 up: the device named by `device` when it has no `config device` section of its own (a dotted VLAN such as `br-lan.10` included), and every device that joins the interface later, such as a Wi-Fi netdev, which then lowers a bridge it joins. A device with its own section keeps its own settings: set its MTU on network/devices, after adopting an anonymous section. On ppp and pppoe the value also goes to pppd, which takes 128 to 16384. The wireguard handler applies it to the tunnel itself. A stored value outside these ranges reads as it is, and a write outside them answers 422." },
		auto:      { type: "boolean", default: true,
		             description: "Bring this interface up at boot" },
		disabled:  { type: "boolean", default: false,
		             description: "Whether netifd ignores this interface entirely. A disabled interface is not registered at all, so it has no ubus object and its addresses and routes are not installed. A stored `1` or `true` reads true, as netifd reads it, and any other value reads false. A write stores `1` or `0`. A write that enables a wireguard interface while one of its enabled peers holds a value that makes wg refuse the whole interface keeps its commit, and answers `X-Kernel-Status: blocked`." },
		addresses: { type: ["array", "null"], items: { type: "string" },
		             description: "Proto wireguard requires at least one address, as an IPv4 or IPv6 CIDR." },
		private_key: { type: "string", writeOnly: true,
		               description: "WireGuard private key; accepted on write, masked on read. A PATCH or PUT that switches the interface to another proto removes it." },
		has_private_key: { type: "boolean", readOnly: true },
		listen_port:  { "x-uapi-read-nullable": true, type: "integer", minimum: -1, maximum: 65535, "x-uapi-write": { minimum: 0 },
		                description: "WireGuard listen port. 0 or unset lets the kernel pick one. netifd parses no listen_port, and the proto handler gives wg the number that ucode's int() reads from the stored value, so `0x10` reads 0 and `010` reads 10. A service name that uci stores, such as `openvpn`, reads null: the handler gives wg no port for it, and wg listens on a port that the kernel picks. A PUT of the read removes the name, with no change for wg. -1 reads for a stored number outside 0 to 65535, for which wg refuses the config of the whole interface, so the interface does not come up. A write answers 422 while the interface holds -1. A PATCH that switches to wireguard and does not send a port also answers 422 while uci holds such a number, which the read of the old proto does not show: send a port, or switch with a PUT, which removes it." },
		nohostroute:  { type: "boolean",
		                description: "Suppress the host route that wireguard adds to a peer endpoint and openvpn to its remote server. Only a stored `1` reads true, which is the value that openvpn-hotplug compares it with." },
		ip4table:     { type: ["string", "null"],
		                description: "Routing table for the IPv4 routes this interface installs: a number or a name from /etc/iproute2/rt_tables" },
		ip6table:     { type: ["string", "null"],
		                description: "Routing table for the IPv6 routes this interface installs: a number or a name from /etc/iproute2/rt_tables" },
		peerdns:      { "x-uapi-read-nullable": true, type: "boolean",
		                description: "Use the DNS servers the upstream advertises (dhcp, dhcpv6, pppoe, ppp, wwan, openvpn). On openvpn they are the DNS servers of a pushed `dhcp-option`. Unset means true." },
		defaultroute: { "x-uapi-read-nullable": true, type: "boolean",
		                description: "Install the default route the protocol provides. Unset means true. On openvpn, openvpn-hotplug provides one each time openvpn knows a route gateway, which a `topology subnet` server always pushes, also without `redirect-gateway`. netifd then replaces the default route of wan, and when the tunnel goes down the main table keeps no IPv4 default route until wan restarts. Set false on a client that must not carry the default route." },
		metric:       { "x-uapi-read-nullable": true, type: "integer", minimum: -2147483648, "x-uapi-write": { minimum: 0 },
		                description: "Metric of the routes this interface installs without one of their own" },
		broadcast_flag: { "x-uapi-read-nullable": true, type: "boolean",
		                description: "Ask the DHCP server to broadcast its replies, as LuCI's \"Use broadcast flag\" (dhcp). Stored in uci as `broadcast`, which is an address on proto static. Unset means false." },
		hostname:     { "x-uapi-read-nullable": true, type: "string",
		                description: "Client hostname sent in DHCPDISCOVER (dhcp)" },
		clientid:     { "x-uapi-read-nullable": true, type: "string", pattern: "^[0-9A-Fa-f: \t-]*$",
		                description: "Client identifier: DHCP option 61 on proto dhcp, a DUID on proto dhcpv6, as hex digits that colons, dashes or blanks may separate, as the proto scripts read it" },
		reqprefix:    { "x-uapi-read-nullable": true, type: "string", pattern: "^(auto|no|([0-9]+|[0-9A-Fa-f:.]+/[0-9]+)(:[0-9A-Fa-f]{1,8})?)$",
		                description: "Prefix delegation request (dhcpv6, pppoe, ppp): auto, no, a prefix length, or a prefix such as 2001:db8::/56, each with an optional :IAID of up to 8 hex digits, as dhcpv6.sh passes it to odhcp6c" },
		reqaddress:   { "x-uapi-read-nullable": true, type: "string", enum: keys(VALID_REQADDRESS),
		                description: "DHCPv6 IA_NA request mode (dhcpv6)" },
		delegate:     { "x-uapi-read-nullable": true, type: "boolean",
		                description: "Hand this interface's IPv6 prefixes on to downstream interfaces. Unset means true." },
		sourcefilter: { "x-uapi-read-nullable": true, type: "boolean",
		                description: "Source-specific default routes (dhcpv6, ppp, pppoe). Unset means true. False adds the upstream default route without a source, which a routed `ip6prefix` needs: traffic from its downstream subnets matches no source-specific route." },
		client:           { type: "boolean",
		                    description: "proto openvpn only. Run in client mode (`--client`), which takes the options that the server pushes." + OVPN_BOOL },
		dev:              { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		                    description: "proto openvpn only. tun or tap device name, such as `tun0`. openvpn needs a device, from this field or from `config`." },
		dev_type:         { type: ["string", "null"], "x-uapi-clear-on-omit": true, enum: [ "tun", "tap", "null", null ], "x-uapi-write": { enum: [ "tun", "tap", null ] },
		                    description: "proto openvpn only. `tun` or `tap`. Unset, the handler passes `--dev-type tun`. openvpn also takes `null`, a device that carries no traffic, which a read gives and a write refuses." },
		ovpnproto:        { type: ["string", "null"], "x-uapi-clear-on-omit": true, enum: [ ...keys(VALID_OVPNPROTO), null ],
		                    description: "proto openvpn only. Transport protocol, openvpn's `--proto`. uci names it `ovpnproto` because `proto` is the netifd protocol, and it is the `proto` of the openvpn/instances of uapi 3.x. Unset, openvpn uses udp." },
		port:             { type: ["integer", "null"], "x-uapi-clear-on-omit": true, minimum: 0, maximum: 65535, "x-uapi-write": { minimum: 1 },
		                    description: "proto openvpn only. Local and remote port (`--port`)." },
		lport:            { type: ["integer", "null"], "x-uapi-clear-on-omit": true, minimum: 0, maximum: 65535,
		                    description: "proto openvpn only. Local port (`--lport`)." },
		rport:            { type: ["integer", "null"], "x-uapi-clear-on-omit": true, minimum: 0, maximum: 65535, "x-uapi-write": { minimum: 1 },
		                    description: "proto openvpn only. Remote port (`--rport`)." },
		remote:           { type: ["array", "null"], "x-uapi-clear-on-omit": true, items: { type: "string" },
		                    description: "proto openvpn only. Servers that a client connects to, each `host [port [proto]]`, tried in order." + OVPN_LIST },
		local:            { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		                    description: "proto openvpn only. Local IP address or host name to bind to (`--local`), as LuCI's form takes it." },
		nobind:           { type: "boolean",
		                    description: "proto openvpn only. Bind to no local address and port (`--nobind`)." + OVPN_BOOL },
		float:            { type: "boolean",
		                    description: "proto openvpn only. Let the peer change its address or port (`--float`)." + OVPN_BOOL },
		topology:         { type: ["string", "null"], "x-uapi-clear-on-omit": true, enum: [ "net30", "p2p", "subnet", null ],
		                    description: "proto openvpn only. Server-mode topology." },
		server:           { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		                    description: "proto openvpn only. Server-mode subnet, such as `10.8.0.0 255.255.255.0`." },
		server_bridge:    { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		                    description: "proto openvpn only. Bridged server mode: `gateway netmask pool-start pool-end`." },
		push:             { type: ["array", "null"], "x-uapi-clear-on-omit": true, items: { type: "string" },
		                    description: "proto openvpn only. Server-mode directives pushed to clients, such as `route 10.0.0.0 255.255.255.0`." + OVPN_LIST },
		route:            { type: ["array", "null"], "x-uapi-clear-on-omit": true, items: { type: "string" },
		                    description: "proto openvpn only. Routes of the tunnel, each `network [netmask [gateway [metric]]]`, which openvpn-hotplug hands to netifd." + OVPN_LIST },
		route_gateway:    { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		                    description: "proto openvpn only. Gateway of the `route` entries that name none." },
		ifconfig:         { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		                    description: "proto openvpn only. Tunnel addresses: `local remote` on a point-to-point tun, `address netmask` otherwise." },
		ifconfig_pool:    { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		                    description: "proto openvpn only. Server-mode address pool: `start end [netmask]`." },
		client_to_client: { type: "boolean",
		                    description: "proto openvpn only. Server mode: route traffic between clients inside openvpn (`--client-to-client`)." + OVPN_BOOL },
		duplicate_cn:     { type: "boolean",
		                    description: "proto openvpn only. Server mode: let several clients connect with one common name (`--duplicate-cn`)." + OVPN_BOOL },
		keepalive:        { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		                    description: "proto openvpn only. `interval timeout` pair, such as `10 60`." },
		ping:             { type: ["integer", "null"], "x-uapi-clear-on-omit": true, minimum: 0, maximum: 2147483647,
		                    description: "proto openvpn only. Seconds between pings when no other traffic passes (`--ping`)." },
		ping_restart:     { type: ["integer", "null"], "x-uapi-clear-on-omit": true, minimum: 0, maximum: 2147483647,
		                    description: "proto openvpn only. Seconds without traffic from the peer before openvpn restarts (`--ping-restart`)." },
		persist_key:      { type: "boolean",
		                    description: "proto openvpn only. Keep the keys across a restart (`--persist-key`)." + OVPN_BOOL },
		persist_tun:      { type: "boolean",
		                    description: "proto openvpn only. Keep the tun or tap device across a restart (`--persist-tun`)." + OVPN_BOOL },
		cipher:           { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		                    description: "proto openvpn only. Data cipher for a peer that negotiates none, such as `AES-256-CBC` (`--cipher`)." },
		auth:             { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		                    description: "proto openvpn only. HMAC digest, such as `SHA256` (`--auth`)." },
		data_ciphers:     { type: ["array", "null"], "x-uapi-clear-on-omit": true, items: { type: "string" },
		                    description: "proto openvpn only. Ciphers that openvpn negotiates, as one entry of names joined by colons, such as `AES-256-GCM:CHACHA20-POLY1305`. It replaces `ncp_ciphers`. The handler gives openvpn each entry as a `--data-ciphers` of its own, and openvpn keeps only the last, so a write with several entries answers 422 `conflict`. Several stored entries, which LuCI's form can write, are an error of the section, and every write answers 422 until one sends a single entry. Always an array." },
		tls_server:       { type: "boolean",
		                    description: "proto openvpn only. Take the TLS server role (`--tls-server`)." + OVPN_BOOL },
		tls_client:       { type: "boolean",
		                    description: "proto openvpn only. Take the TLS client role (`--tls-client`)." + OVPN_BOOL },
		tls_crypt:        { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		                    description: "proto openvpn only. Absolute path of the tls-crypt key file." + OVPN_FILE },
		ca:               { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		                    description: "proto openvpn only. Absolute path of the CA certificate PEM." + OVPN_FILE },
		cert:             { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		                    description: "proto openvpn only. Absolute path of the local certificate PEM." + OVPN_FILE },
		dh:               { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		                    description: "proto openvpn only. Absolute path of the Diffie-Hellman parameters PEM, for server mode." + OVPN_FILE },
		crl_verify:       { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		                    description: "proto openvpn only. Absolute path of the certificate revocation list PEM." + OVPN_FILE },
		remote_cert_tls:  { type: ["string", "null"], "x-uapi-clear-on-omit": true, enum: [ "client", "server", null ],
		                    description: "proto openvpn only. Require that the peer certificate carries the key usage of a client or of a server." },
		verify_x509_name: { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		                    description: "proto openvpn only. Accept only a peer certificate of this name: `name [type]`." },
		user:             { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		                    description: "proto openvpn only. User that openvpn drops its privileges to." },
		group:            { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		                    description: "proto openvpn only. Group that openvpn drops its privileges to." },
		log:              { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		                    description: "proto openvpn only. Absolute path of a log file, which openvpn truncates at each start (`--log`)." },
		log_append:       { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		                    description: "proto openvpn only. Absolute path of a log file that openvpn appends to (`--log-append`)." },
		verb:             { type: ["integer", "null"], "x-uapi-clear-on-omit": true, minimum: 0, maximum: 2147483647, "x-uapi-write": { maximum: 11 },
		                    description: "proto openvpn only. Log verbosity. A write takes 0 to 11." },
		mute:             { type: ["integer", "null"], "x-uapi-clear-on-omit": true, minimum: 0, maximum: 2147483647,
		                    description: "proto openvpn only. Log at most this many messages of one category in a row (`--mute`)." },
		config:           { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		                    description: "proto openvpn only. Absolute path of an openvpn config file, which openvpn reads beside these options (`--config`). LuCI's raw config tab stores `/etc/openvpn/<id>/<id>_config.cfg`. The handler runs openvpn in the directory of this file, so a relative path in it resolves there." + OVPN_FILE },
		username:         { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		                    description: "User name that the interface logs in with (pppoe, ppp, wwan, openvpn). ppp.sh gives it and `password` to pppd, and gives neither when it is unset. wwan hands both to the handler of the modem that it finds, such as qmi or mbim. The openvpn handler writes it with `password` to a file that it gives openvpn as `--auth-user-pass`. Each proto sends the login to another party, so a switch to another proto removes it, and a switch that sends a user name stores it." },
		key:              { type: "string", writeOnly: true,
		                    description: "proto openvpn only. Absolute path of the private key PEM." + OVPN_FILE + sprintf(OVPN_SECRET, "key") },
		tls_auth:         { type: "string", writeOnly: true,
		                    description: "proto openvpn only. Absolute path of the tls-auth key file." + sprintf(OVPN_SECRET, "tls_auth") },
		pkcs12:           { type: "string", writeOnly: true,
		                    description: "proto openvpn only. Absolute path of the PKCS#12 bundle." + OVPN_FILE + sprintf(OVPN_SECRET, "pkcs12") },
		password:         { type: "string", writeOnly: true,
		                    description: "Password that the interface logs in with, beside `username` (pppoe, ppp, wwan, openvpn). On pppoe and ppp, a password without `username` does nothing, since ppp.sh then gives pppd neither." + sprintf(OVPN_SECRET, "password") + " A switch that sends a password stores it." },
		cert_password:    { type: "string", writeOnly: true,
		                    description: "proto openvpn only. Passphrase of the private key, which the handler writes to a file that it gives openvpn as `--askpass`." + sprintf(OVPN_SECRET, "cert_password") },
		has_key:          { type: "boolean", readOnly: true, description: "proto openvpn only. Whether uci holds `key`." },
		has_tls_auth:     { type: "boolean", readOnly: true, description: "proto openvpn only. Whether uci holds `tls_auth`." },
		has_pkcs12:       { type: "boolean", readOnly: true, description: "proto openvpn only. Whether uci holds `pkcs12`." },
		has_password:     { type: "boolean", readOnly: true, description: "Whether uci holds `password` (pppoe, ppp, wwan, openvpn)." },
		has_cert_password: { type: "boolean", readOnly: true, description: "proto openvpn only. Whether uci holds `cert_password`." },
	},
};
