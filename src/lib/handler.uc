let ids = require("ids");
let errors = require("errors");
let transaction = require("transaction");

// ETag computation. Uses sha256 from ucode-mod-digest when available (real
// router); falls back to a non-crypto stable string hash for unit-test
// environments where digest may not be installed. ETags exist for cache
// invalidation, not authentication, so the fallback is acceptable.
let _digest = null;
try { _digest = require("digest"); } catch (e) {}

function _fallback_hash(s) {
	let h = 5381;
	for (let i = 0; i < length(s); i++) {
		let c = ord(substr(s, i, 1));
		h = ((h * 33) + c) % 4294967296;
	}
	return sprintf("%08x", h);
}

function compute_etag(body) {
	if (body == null) return null;
	let canonical = sprintf("%J", body);
	let hex = (_digest != null) ? _digest.sha256(canonical) : _fallback_hash(canonical);
	return substr(hex, 0, 12);
}

function set_etag_header(resp, body) {
	let etag = compute_etag(body);
	if (etag == null) return resp;
	if (resp.headers == null) resp.headers = {};
	resp.headers["ETag"] = "\"" + etag + "\"";
	return resp;
}

function parse_if_match(header_value) {
	if (type(header_value) != "string" || header_value == "") return null;
	let v = trim(header_value);
	if (v == "*") return "*";
	// Strip surrounding quotes and optional W/ weak indicator.
	if (substr(v, 0, 2) == "W/") v = trim(substr(v, 2));
	if (substr(v, 0, 1) == "\"" && substr(v, length(v) - 1) == "\"")
		v = substr(v, 1, length(v) - 2);
	return v;
}

function precondition_check(ctx, existing_body) {
	let want = parse_if_match(ctx.if_match);
	if (want == null) return null;          // no If-Match -> no check
	if (want == "*" && existing_body != null) return null;  // wildcard ok for any existing
	let have = compute_etag(existing_body);
	if (have == want) return null;
	return errors.error(ctx, "precondition_failed",
		sprintf("If-Match did not match current ETag (current=\"%s\")", have));
}

function build_field_errors(raw_errs) {
	let out = [];
	for (let e in raw_errs)
		push(out, errors.field_error(e.field, e.code, e.message));
	return out;
}

function translate_tx(ctx, result) {
	if (result.ok) {
		let resp = errors.ok(ctx, result.body);
		return (result.body != null) ? set_etag_header(resp, result.body) : resp;
	}
	if (result.kind == "locked") return errors.locked(ctx);
	if (result.kind == "lock_unavailable")
		return errors.error(ctx, "internal_error",
		                    sprintf("transaction lock file not available: %s", result.error));
	if (result.kind == "validation")
		return errors.validation_failed(ctx, build_field_errors(result.errors));
	if (result.kind == "not_found")
		return errors.error(ctx, "not_found", result.message);
	if (result.kind == "unmanaged_resource")
		return errors.error(ctx, "unmanaged_resource", result.message);
	if (result.kind == "conflict")
		return errors.error(ctx, "conflict", result.message);
	if (result.kind == "precondition_failed")
		return errors.error(ctx, "precondition_failed", result.message);
	if (result.kind == "reload_failed_restored")
		return errors.reload_failed_restored(ctx, result.reload_error);
	if (result.kind == "reload_failed_unrecovered")
		return errors.reload_failed_unrecovered(ctx, result.reload_error, result.restore_error);
	return errors.error(ctx, "internal_error",
	                    sprintf("transaction returned unknown kind %J", result.kind));
}

function default_merge_for_patch(existing_section, existing_json, body) {
	let merged = { ...existing_json };
	for (let k in body) {
		if (type(merged[k]) == "object" && type(body[k]) == "object")
			merged[k] = { ...merged[k], ...body[k] };
		else
			merged[k] = body[k];
	}
	return merged;
}

function load_section(conn, pkg, id) {
	let s = conn.uci_get(pkg, id);
	if (!s) return null;
	if (type(s) != "object") return null;
	let view = { ...s };
	view['.name'] = id;
	return view;
}

function make(resource, opts) {
	let pkg = resource.package;
	let sec_type = resource.type;
	let reload_services = resource.reload ?? [];
	let tx_overrides = (opts != null && opts.tx != null) ? opts.tx : {};

	// Dynamic-type hooks (default to static behavior).
	let type_predicate = resource.type_predicate ?? function(t) { return t == sec_type; };
	let create_type = resource.create_type ?? function(body) { return sec_type; };
	let id_prefix = resource.id_prefix ?? substr(sec_type, 0, 1);

	function tx_params(extra) {
		let p = { package: pkg, reload_services: reload_services };
		for (let k in tx_overrides) p[k] = tx_overrides[k];
		for (let k in extra) p[k] = extra[k];
		return p;
	}

	function list(conn, ctx, query) {
		let want_managed = query.managed;
		let out = [];
		conn.uci_foreach(pkg, null, function(s) {
			if (!type_predicate(s['.type'])) return;
			let r = resource.fromUci(s, conn);
			if (want_managed == "true" && !r.managed) return;
			if (want_managed == "false" && r.managed) return;
			push(out, r);
		});
		return errors.ok(ctx, out);
	}

	function get_one(conn, ctx, id) {
		let s = load_section(conn, pkg, id);
		if (!s || !type_predicate(s['.type']))
			return errors.error(ctx, "not_found",
			                    sprintf("No %s with id %J", sec_type, id));
		let body = resource.fromUci(s, conn);
		return set_etag_header(errors.ok(ctx, body), body);
	}

	function create(conn, ctx, body) {
		let result = transaction.transaction(conn, tx_params({
			fn: function(c, p) {
				let errs = resource.validate(body, c, null);
				if (length(errs) > 0)
					return { ok: false, kind: "validation", errors: errs };
				let new_id = ids.new_id(id_prefix);
				let new_opts = resource.toUci(body);
				let resolved_type = create_type(body);
				c.uci_create_section(p, new_id, resolved_type);
				for (let k in new_opts) c.uci_set(p, new_id, k, new_opts[k]);
				let view = { ...new_opts };
				view['.name'] = new_id;
				view['.anonymous'] = false;
				view['.type'] = resolved_type;
				return { ok: true, body: resource.fromUci(view, conn) };
			},
		}));

		return translate_tx(ctx, result);
	}

	function replace(conn, ctx, id, body) {
		let result = transaction.transaction(conn, tx_params({
			fn: function(c, p) {
				let errs = resource.validate(body, c, id);
				if (length(errs) > 0)
					return { ok: false, kind: "validation", errors: errs };
				let existing = load_section(c, p, id);
				if (!existing || !type_predicate(existing['.type']))
					return { ok: false, kind: "not_found",
					         message: sprintf("No %s with id %J", sec_type, id) };
				let existing_view = resource.fromUci(existing, conn);
				if (!existing_view.managed)
					return { ok: false, kind: "unmanaged_resource",
					         message: "Section is not uapi-managed; adopt it first" };
				let pc = precondition_check(ctx, existing_view);
				if (pc != null)
					return { ok: false, kind: "precondition_failed",
					         message: pc.body.message };
				let new_opts = resource.toUci(body);
				for (let k in existing) {
					if (substr(k, 0, 1) == ".") continue;
					if (exists(new_opts, k)) continue;
					c.uci_delete(p, id, k);
				}
				for (let k in new_opts) c.uci_set(p, id, k, new_opts[k]);
				let view = { ...new_opts };
				view['.name'] = id;
				view['.anonymous'] = false;
				view['.type'] = existing['.type'];
				return { ok: true, body: resource.fromUci(view, conn) };
			},
		}));

		return translate_tx(ctx, result);
	}

	function patch(conn, ctx, id, body) {
		let result = transaction.transaction(conn, tx_params({
			fn: function(c, p) {
				let existing = load_section(c, p, id);
				if (!existing || !type_predicate(existing['.type']))
					return { ok: false, kind: "not_found",
					         message: sprintf("No %s with id %J", sec_type, id) };
				let existing_view = resource.fromUci(existing, conn);
				if (!existing_view.managed)
					return { ok: false, kind: "unmanaged_resource",
					         message: "Section is not uapi-managed; adopt it first" };
				let pc = precondition_check(ctx, existing_view);
				if (pc != null)
					return { ok: false, kind: "precondition_failed",
					         message: pc.body.message };

				let existing_json = existing_view;
				let merge_fn = resource.merge_for_patch ?? default_merge_for_patch;
				let merged_json = merge_fn(existing, existing_json, body);

				let errs = resource.validate(merged_json, c, id);
				if (length(errs) > 0)
					return { ok: false, kind: "validation", errors: errs };

				let new_opts = resource.toUci(merged_json);
				for (let k in existing) {
					if (substr(k, 0, 1) == ".") continue;
					if (exists(new_opts, k)) continue;
					c.uci_delete(p, id, k);
				}
				for (let k in new_opts) c.uci_set(p, id, k, new_opts[k]);
				let view = { ...new_opts };
				view['.name'] = id;
				view['.anonymous'] = false;
				view['.type'] = existing['.type'];
				return { ok: true, body: resource.fromUci(view, conn) };
			},
		}));

		return translate_tx(ctx, result);
	}

	function remove(conn, ctx, id) {
		let result = transaction.transaction(conn, tx_params({
			fn: function(c, p) {
				let existing = load_section(c, p, id);
				if (!existing || !type_predicate(existing['.type']))
					return { ok: false, kind: "not_found",
					         message: sprintf("No %s with id %J", sec_type, id) };
				if (!resource.fromUci(existing, conn).managed)
					return { ok: false, kind: "unmanaged_resource",
					         message: "Section is not uapi-managed" };
				c.uci_delete(p, id);
				return { ok: true, body: null };
			},
		}));

		if (result.ok) return errors.no_content(ctx);
		return translate_tx(ctx, result);
	}

	function adopt(conn, ctx, id) {
		let result = transaction.transaction(conn, tx_params({
			fn: function(c, p) {
				let existing = load_section(c, p, id);
				if (!existing || !type_predicate(existing['.type']))
					return { ok: false, kind: "not_found",
					         message: sprintf("No %s with id %J", sec_type, id) };
				if (resource.fromUci(existing, conn).managed)
					return { ok: false, kind: "conflict",
					         message: "Section is already managed" };
				let new_id = ids.new_id(id_prefix);
				c.uci_rename(p, id, new_id);
				let view = { ...existing };
				view['.name'] = new_id;
				view['.anonymous'] = false;
				return { ok: true, body: resource.fromUci(view, conn) };
			},
		}));

		return translate_tx(ctx, result);
	}

	return { list, get_one, create, replace, patch, remove, adopt };
}

function make_singleton(resource, opts) {
	let pkg = resource.package;
	let sec_type = resource.type;
	let reload_services = resource.reload ?? [];
	let tx_overrides = (opts != null && opts.tx != null) ? opts.tx : {};

	function tx_params(extra) {
		let p = { package: pkg, reload_services: reload_services };
		for (let k in tx_overrides) p[k] = tx_overrides[k];
		for (let k in extra) p[k] = extra[k];
		return p;
	}

	function find(conn) {
		let found = null;
		conn.uci_foreach(pkg, sec_type, function(s) {
			found = s;
			return false;
		});
		return found;
	}

	function get(conn, ctx) {
		let s = find(conn);
		if (!s)
			return errors.error(ctx, "not_found",
			                    sprintf("singleton %s.%s missing", pkg, sec_type));
		let body = resource.fromUci(s, conn);
		return set_etag_header(errors.ok(ctx, body), body);
	}

	function patch(conn, ctx, body) {
		let result = transaction.transaction(conn, tx_params({
			fn: function(c, p) {
				let existing = find(c);
				if (!existing)
					return { ok: false, kind: "not_found",
					         message: sprintf("singleton %s.%s missing", pkg, sec_type) };
				let id = existing['.name'];

				let existing_view = resource.fromUci(existing, conn);
				let pc = precondition_check(ctx, existing_view);
				if (pc != null)
					return { ok: false, kind: "precondition_failed",
					         message: pc.body.message };

				let merged = { ...existing_view };
				for (let k in body) merged[k] = body[k];

				let errs = resource.validate(merged, c, id);
				if (length(errs) > 0)
					return { ok: false, kind: "validation", errors: errs };

				let new_opts = resource.toUci(merged);
				for (let k in existing) {
					if (substr(k, 0, 1) == ".") continue;
					if (exists(new_opts, k)) continue;
					c.uci_delete(p, id, k);
				}
				for (let k in new_opts) c.uci_set(p, id, k, new_opts[k]);
				let view = { ...new_opts };
				view['.name'] = id;
				view['.anonymous'] = !!existing['.anonymous'];
				view['.type'] = sec_type;
				return { ok: true, body: resource.fromUci(view, conn) };
			},
		}));

		return translate_tx(ctx, result);
	}

	return { get, patch };
}

function make_collection(resource) {
	let pkg = resource.package;
	let sec_type = resource.type;

	function method_not_allowed(ctx, method) {
		return errors.error(ctx, "method_not_allowed",
		                    sprintf("%s/%s is read-only (%s not supported)",
		                            pkg, sec_type, method));
	}

	function list(conn, ctx, query) {
		return errors.ok(ctx, resource.list_fn(conn, query));
	}

	function get_one(conn, ctx, id) {
		if (resource.id_field == null)
			return method_not_allowed(ctx, "individual lookup");
		for (let item in resource.list_fn(conn))
			if (item[resource.id_field] == id) return errors.ok(ctx, item);
		return errors.error(ctx, "not_found",
		                    sprintf("No %s with %s=%J", sec_type, resource.id_field, id));
	}

	return {
		list,
		get_one,
		create:  function(conn, ctx, body)       { return method_not_allowed(ctx, "POST"); },
		replace: function(conn, ctx, id, body)   { return method_not_allowed(ctx, "PUT"); },
		patch:   function(conn, ctx, id, body)   { return method_not_allowed(ctx, "PATCH"); },
		remove:  function(conn, ctx, id)         { return method_not_allowed(ctx, "DELETE"); },
		adopt:   function(conn, ctx, id)         { return method_not_allowed(ctx, "adopt"); },
	};
}

return { make, make_singleton, make_collection, translate_tx, load_section };
