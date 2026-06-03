let values = require('values');
let normalize_bool = values.normalize_bool;
let as_list = values.as_list;
let as_int = values.as_int;
let is_valid_cidr = values.is_valid_cidr;
let is_valid_ip = values.is_valid_ip;

const VALID_PROTO = { "udp": true, "tcp": true, "udp4": true, "tcp4": true, "udp6": true, "tcp6": true };
const VALID_DEV   = { "tun": true, "tap": true };
const VALID_TLS   = { "tls-server": true, "tls-client": true, "tls-auth": true };
// Filesystem paths on the router. The shape excludes shell meta + relative
// paths so a malformed value cannot break out of /etc/openvpn or smuggle
// arguments past the daemon's argv handling.
const PATH_RE = /^\/[A-Za-z0-9_.+\/-]+$/;

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		enabled:         normalize_bool(section.enabled, true),
		client:          normalize_bool(section.client, false),
		dev:             section.dev ?? null,
		dev_type:        section.dev_type ?? null,
		proto:           section.proto ?? null,
		port:            as_int(section.port),
		lport:           as_int(section.lport),
		rport:           as_int(section.rport),
		remote:          as_list(section.remote),
		local:           section.local ?? null,
		nobind:          normalize_bool(section.nobind, false),
		float:           normalize_bool(section.float, false),
		topology:        section.topology ?? null,
		server:          section.server ?? null,
		server_bridge:   section.server_bridge ?? null,
		push:            as_list(section.push),
		route:           as_list(section.route),
		route_gateway:   section.route_gateway ?? null,
		ifconfig:        section.ifconfig ?? null,
		ifconfig_pool:   section.ifconfig_pool ?? null,
		client_to_client: normalize_bool(section.client_to_client, false),
		duplicate_cn:    normalize_bool(section.duplicate_cn, false),
		keepalive:       section.keepalive ?? null,
		ping:            as_int(section.ping),
		ping_restart:    as_int(section.ping_restart),
		persist_key:     normalize_bool(section.persist_key, false),
		persist_tun:     normalize_bool(section.persist_tun, false),
		comp_lzo:        section.comp_lzo ?? null,
		compress:        section.compress ?? null,
		cipher:          section.cipher ?? null,
		auth:            section.auth ?? null,
		ncp_ciphers:     section.ncp_ciphers ?? null,
		ncp_disable:     normalize_bool(section.ncp_disable, false),
		tls_server:      normalize_bool(section.tls_server, false),
		tls_client:      normalize_bool(section.tls_client, false),
		tls_crypt:       section.tls_crypt ?? null,
		ca:              section.ca ?? null,
		cert:            section.cert ?? null,
		dh:              section.dh ?? null,
		crl_verify:      section.crl_verify ?? null,
		remote_cert_tls: section.remote_cert_tls ?? null,
		verify_x509_name: section.verify_x509_name ?? null,
		user:            section.user ?? null,
		group:           section.group ?? null,
		status:          section.status ?? null,
		log:             section.log ?? null,
		log_append:      section.log_append ?? null,
		verb:            as_int(section.verb),
		mute:            as_int(section.mute),
		// key, tls_auth, pkcs12: filesystem paths to secret material. Surfaced
		// as has_<field> on read so a scope:ro caller cannot recover the path
		// (and thus the secret-file location) just by GET-ing the resource.
		has_key:         (section.key != null && section.key != ""),
		has_tls_auth:    (section.tls_auth != null && section.tls_auth != ""),
		has_pkcs12:      (section.pkcs12 != null && section.pkcs12 != ""),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.enabled != null)          out.enabled = json.enabled ? "1" : "0";
	if (json.client != null)           out.client = json.client ? "1" : "0";
	if (json.dev != null)              out.dev = json.dev;
	if (json.dev_type != null)         out.dev_type = json.dev_type;
	if (json.proto != null)            out.proto = json.proto;
	if (json.port != null)             out.port = "" + json.port;
	if (json.lport != null)            out.lport = "" + json.lport;
	if (json.rport != null)            out.rport = "" + json.rport;
	if (json.remote != null)           out.remote = json.remote;
	if (json.local != null)            out.local = json.local;
	if (json.nobind != null)           out.nobind = json.nobind ? "1" : "0";
	if (json.float != null)            out.float = json.float ? "1" : "0";
	if (json.topology != null)         out.topology = json.topology;
	if (json.server != null)           out.server = json.server;
	if (json.server_bridge != null)    out.server_bridge = json.server_bridge;
	if (json.push != null)             out.push = json.push;
	if (json.route != null)            out.route = json.route;
	if (json.route_gateway != null)    out.route_gateway = json.route_gateway;
	if (json.ifconfig != null)         out.ifconfig = json.ifconfig;
	if (json.ifconfig_pool != null)    out.ifconfig_pool = json.ifconfig_pool;
	if (json.client_to_client != null) out.client_to_client = json.client_to_client ? "1" : "0";
	if (json.duplicate_cn != null)     out.duplicate_cn = json.duplicate_cn ? "1" : "0";
	if (json.keepalive != null)        out.keepalive = json.keepalive;
	if (json.ping != null)             out.ping = "" + json.ping;
	if (json.ping_restart != null)     out.ping_restart = "" + json.ping_restart;
	if (json.persist_key != null)      out.persist_key = json.persist_key ? "1" : "0";
	if (json.persist_tun != null)      out.persist_tun = json.persist_tun ? "1" : "0";
	if (json.comp_lzo != null)         out.comp_lzo = json.comp_lzo;
	if (json.compress != null)         out.compress = json.compress;
	if (json.cipher != null)           out.cipher = json.cipher;
	if (json.auth != null)             out.auth = json.auth;
	if (json.ncp_ciphers != null)      out.ncp_ciphers = json.ncp_ciphers;
	if (json.ncp_disable != null)      out.ncp_disable = json.ncp_disable ? "1" : "0";
	if (json.tls_server != null)       out.tls_server = json.tls_server ? "1" : "0";
	if (json.tls_client != null)       out.tls_client = json.tls_client ? "1" : "0";
	if (json.tls_crypt != null)        out.tls_crypt = json.tls_crypt;
	if (json.ca != null)               out.ca = json.ca;
	if (json.cert != null)             out.cert = json.cert;
	if (json.dh != null)               out.dh = json.dh;
	if (json.crl_verify != null)       out.crl_verify = json.crl_verify;
	if (json.remote_cert_tls != null)  out.remote_cert_tls = json.remote_cert_tls;
	if (json.verify_x509_name != null) out.verify_x509_name = json.verify_x509_name;
	if (json.user != null)             out.user = json.user;
	if (json.group != null)            out.group = json.group;
	if (json.status != null)           out.status = json.status;
	if (json.log != null)              out.log = json.log;
	if (json.log_append != null)       out.log_append = json.log_append;
	if (json.verb != null)             out.verb = "" + json.verb;
	if (json.mute != null)             out.mute = "" + json.mute;
	if (json.key != null)              out.key = json.key;
	if (json.tls_auth != null)         out.tls_auth = json.tls_auth;
	if (json.pkcs12 != null)           out.pkcs12 = json.pkcs12;
	return out;
}

function _check_path(errs, field, value) {
	if (value == null || value == "") return;
	if (type(value) != "string" || !match(value, PATH_RE))
		push(errs, { field, code: "invalid_format",
		             message: "must be an absolute filesystem path (no shell meta)" });
}

function validate(json) {
	let errs = [];
	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}
	_check_path(errs, "ca",       json.ca);
	_check_path(errs, "cert",     json.cert);
	_check_path(errs, "key",      json.key);
	_check_path(errs, "dh",       json.dh);
	_check_path(errs, "tls_auth", json.tls_auth);
	_check_path(errs, "tls_crypt", json.tls_crypt);
	_check_path(errs, "pkcs12",   json.pkcs12);
	_check_path(errs, "crl_verify", json.crl_verify);
	_check_path(errs, "status",   json.status);
	_check_path(errs, "log",      json.log);
	_check_path(errs, "log_append", json.log_append);
	if (json.local != null && json.local != "" && !is_valid_ip(json.local))
		push(errs, { field: "local", code: "invalid_format",
		             message: "must be a valid IP" });
	return errs;
}

// PATCH that omits key/tls_auth/pkcs12 must NOT wipe the existing values:
// those are write-only on the wire (fromUci surfaces only has_<field>) and
// the merge needs the original uci section to carry them forward.
function merge_for_patch(existing_section, existing_json, body) {
	let merged = { ...existing_json };
	for (let k in body) merged[k] = body[k];
	if (body.key == null && existing_section.key != null)
		merged.key = existing_section.key;
	if (body.tls_auth == null && existing_section.tls_auth != null)
		merged.tls_auth = existing_section.tls_auth;
	if (body.pkcs12 == null && existing_section.pkcs12 != null)
		merged.pkcs12 = existing_section.pkcs12;
	delete merged.has_key;
	delete merged.has_tls_auth;
	delete merged.has_pkcs12;
	return merged;
}

return {
	package: "openvpn",
	type: "openvpn",
	reload: ["openvpn"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	merge_for_patch: merge_for_patch,
	id_prefix: "o",
	schema_properties: {
		enabled:          { type: "boolean" },
		client:           { type: "boolean", description: "Run this instance as a client (default: server)." },
		dev:              { type: ["string", "null"], description: "Interface name (tun0, tap0, etc.)." },
		dev_type:         { type: ["string", "null"], enum: keys(VALID_DEV) + [null] },
		proto:            { type: ["string", "null"], enum: keys(VALID_PROTO) + [null] },
		port:             { type: ["integer", "null"], minimum: 1, maximum: 65535 },
		lport:            { type: ["integer", "null"], minimum: 0, maximum: 65535 },
		rport:            { type: ["integer", "null"], minimum: 1, maximum: 65535 },
		remote:           { type: "array", items: { type: "string" },
		                    description: "host[:port] entries; client tries them in order." },
		local:            { type: ["string", "null"], description: "Bind to this local IP." },
		nobind:           { type: "boolean" },
		float:            { type: "boolean" },
		topology:         { type: ["string", "null"], enum: ["net30", "p2p", "subnet", null] },
		server:           { type: ["string", "null"], description: "Server-mode subnet (e.g. `10.8.0.0 255.255.255.0`)." },
		server_bridge:    { type: ["string", "null"] },
		push:             { type: "array", items: { type: "string" },
		                    description: "Server-mode directives pushed to clients." },
		route:            { type: "array", items: { type: "string" } },
		route_gateway:    { type: ["string", "null"] },
		ifconfig:         { type: ["string", "null"] },
		ifconfig_pool:    { type: ["string", "null"] },
		client_to_client: { type: "boolean" },
		duplicate_cn:     { type: "boolean" },
		keepalive:        { type: ["string", "null"], description: "`interval timeout` pair." },
		ping:             { type: ["integer", "null"], minimum: 1, maximum: 3600 },
		ping_restart:     { type: ["integer", "null"], minimum: 1, maximum: 86400 },
		persist_key:      { type: "boolean" },
		persist_tun:      { type: "boolean" },
		comp_lzo:         { type: ["string", "null"], enum: ["yes", "no", "adaptive", null] },
		compress:         { type: ["string", "null"], enum: ["lzo", "lz4", "lz4-v2", "stub", "stub-v2", null] },
		cipher:           { type: ["string", "null"], description: "Legacy data cipher (e.g. AES-256-CBC)." },
		auth:             { type: ["string", "null"], description: "HMAC digest (SHA256, etc.)." },
		ncp_ciphers:      { type: ["string", "null"], description: "Colon-separated negotiable data ciphers." },
		ncp_disable:      { type: "boolean" },
		tls_server:       { type: "boolean" },
		tls_client:       { type: "boolean" },
		tls_crypt:        { type: ["string", "null"], description: "Path to tls-crypt key file." },
		ca:               { type: ["string", "null"], description: "Path to CA cert PEM." },
		cert:             { type: ["string", "null"], description: "Path to local cert PEM." },
		dh:               { type: ["string", "null"], description: "Path to DH parameters PEM (server-mode)." },
		crl_verify:       { type: ["string", "null"], description: "Path to CRL PEM." },
		remote_cert_tls:  { type: ["string", "null"], enum: ["client", "server", null] },
		verify_x509_name: { type: ["string", "null"] },
		user:             { type: ["string", "null"], description: "Drop privileges to this user." },
		group:            { type: ["string", "null"] },
		status:           { type: ["string", "null"], description: "Status file path." },
		log:              { type: ["string", "null"] },
		log_append:       { type: ["string", "null"] },
		verb:             { type: ["integer", "null"], minimum: 0, maximum: 11 },
		mute:             { type: ["integer", "null"], minimum: 0 },
		// Sensitive paths. Write-only on the wire; read returns has_<field>.
		key:              { type: "string", writeOnly: true,
		                    description: "Path to private key PEM. Write-only; reads return has_key." },
		tls_auth:         { type: "string", writeOnly: true,
		                    description: "Path to TLS auth key file. Write-only; reads return has_tls_auth." },
		pkcs12:           { type: "string", writeOnly: true,
		                    description: "Path to PKCS#12 bundle. Write-only; reads return has_pkcs12." },
		has_key:          { type: "boolean", readOnly: true },
		has_tls_auth:     { type: "boolean", readOnly: true },
		has_pkcs12:       { type: "boolean", readOnly: true },
	},
};
