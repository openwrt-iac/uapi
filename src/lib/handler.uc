let ids = require("ids");
let errors = require("errors");
let transaction = require("transaction");
let jsonpatch = require("jsonpatch");

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

function _hash(s) {
	let hex = (_digest != null) ? _digest.sha256(s) : _fallback_hash(s);
	return substr(hex, 0, 12);
}

function compute_etag(body) {
	if (body == null) return null;
	// Strip the `runtime` block before hashing: it carries live ubus/file-derived
	// state (uptime, signal, lease counts, active addresses) that drifts second-
	// to-second on an unchanged uci section. Including it would make ETags
	// non-deterministic and trip spurious 412s on every If-Match round-trip.
	let canon = body;
	if (type(body) == "object" && body.runtime != null) {
		canon = { ...body };
		delete canon.runtime;
	}
	return _hash(sprintf("%J", canon));
}

// Cursor pagination for collection GETs. The cursor is `c_<last_seen_id>`;
// items after the matching id (lexicographic walk through the result array)
// form the next page. Clients without ?cursor get items 0..limit-1; when
// further items exist, the response carries `Link: <...?cursor=...>; rel="next"`
// (RFC 8288). Without `?limit` the default is 100; the maximum is 500.
const DEFAULT_LIMIT = 100;
const MAX_LIMIT = 500;
const CURSOR_RE = /^c_[A-Za-z0-9_-]+$/;

function paginate(ctx, items, query) {
	let limit = DEFAULT_LIMIT;
	if (query != null && query.limit != null) {
		// Force int conversion: `+s` accepts trailing junk and returns NaN
		// silently. Require digit-only input via the regex, then int().
		if (type(query.limit) != "string" || !match(query.limit, /^[1-9][0-9]{0,4}$/))
			return errors.error(ctx, "bad_request",
				sprintf("limit must be a positive integer 1..%d", MAX_LIMIT));
		let n = int(query.limit);
		if (n < 1 || n > MAX_LIMIT)
			return errors.error(ctx, "bad_request",
				sprintf("limit must be between 1 and %d", MAX_LIMIT));
		limit = n;
	}
	let start = 0;
	if (query != null && query.cursor != null && query.cursor != "") {
		if (!match(query.cursor, CURSOR_RE))
			return errors.error(ctx, "invalid_cursor", "cursor is malformed");
		let after_id = substr(query.cursor, 2);
		let found = false;
		for (let i = 0; i < length(items); i++) {
			if (items[i].id == after_id) { start = i + 1; found = true; break; }
		}
		if (!found)
			return errors.error(ctx, "invalid_cursor", "cursor refers to no current item");
	}
	let end = start + limit;
	let page = slice(items, start, end);
	let resp = errors.ok(ctx, page);
	if (end < length(items) && length(page) > 0) {
		let next = "c_" + page[length(page) - 1].id;
		resp.headers["Link"] = sprintf("<?cursor=%s&limit=%d>; rel=\"next\"", next, limit);
		resp.headers["X-Next-Cursor"] = next;
	}
	return resp;
}

function set_etag_header(resp, body) {
	let etag = compute_etag(body);
	if (etag == null) return resp;
	if (resp.headers == null) resp.headers = {};
	resp.headers["ETag"] = "\"" + etag + "\"";
	return resp;
}

// Returns either the literal "*" or an array of tag strings (without quotes
// or W/ weak prefix), or null when no If-Match was supplied. Empty / malformed
// values resolve to a non-matching sentinel so writes are denied rather than
// silently allowed.
function parse_if_match(header_value) {
	if (type(header_value) != "string") return null;
	let v = trim(header_value);
	if (v == "") return null;
	if (v == "*") return "*";
	let out = [];
	for (let entry in split(v, ",")) {
		let e = trim(entry);
		if (e == "") continue;
		if (substr(e, 0, 2) == "W/") e = trim(substr(e, 2));
		if (substr(e, 0, 1) == "\"") {
			if (length(e) < 2 || substr(e, length(e) - 1) != "\"") continue;
			e = substr(e, 1, length(e) - 2);
		}
		if (e == "") continue;
		push(out, e);
	}
	if (length(out) == 0) return null;
	return out;
}

function precondition_check(ctx, existing_body) {
	let want = parse_if_match(ctx.if_match);
	if (want == null) return null;          // no If-Match -> no check
	if (want == "*" && existing_body != null) return null;  // wildcard ok for any existing
	if (want == "*") return errors.error(ctx, "precondition_failed",
		"If-Match: * requires an existing resource");
	let have = compute_etag(existing_body);
	for (let candidate in want)
		if (candidate == have) return null;
	return errors.error(ctx, "precondition_failed",
		sprintf("If-Match did not match current ETag (current=\"%s\")", have));
}

function build_field_errors(raw_errs) {
	let out = [];
	for (let e in raw_errs)
		push(out, errors.field_error(e.field, e.code, e.message));
	return out;
}

// Without this gate, wrong-type fields fall through resource.validate() and
// reach toUci() where they are silently dropped. Surface as 422 instead.
// Errors merge+dedup with resource.validate's by (field, code).
function _json_type_matches(want, val) {
	if (type(want) == "array") {
		for (let w in want)
			if (_json_type_matches(w, val)) return true;
		return false;
	}
	let got = type(val);
	if (want == "integer") return got == "int";
	if (want == "number")  return got == "int" || got == "double";
	if (want == "boolean") return got == "bool";
	if (want == "null")    return val == null;
	return want == got;
}

// Map ucode's type() names back to JSON Schema vocabulary so error messages
// don't mix vocabularies ("must be string, got int" -> "must be string, got
// integer"). Falls through for shared names (string, array, object, null).
function _json_type_name(val) {
	let got = type(val);
	if (got == "int")    return "integer";
	if (got == "double") return "number";
	if (got == "bool")   return "boolean";
	return got;
}

function _format_want(want) {
	if (type(want) == "array")
		return length(want) > 0 ? join(" or ", want) : "<unspecified>";
	return "" + want;
}

// _check_value and check_schema_types are mutually recursive (object specs
// recurse into properties, array specs recurse into items). ucode `function`
// declarations do NOT hoist, so we forward-declare with `let` first.
let _check_value;
let check_schema_types;

_check_value = function(spec, val, field_path, errs) {
	let want = spec.type;
	if (want != null && !_json_type_matches(want, val)) {
		push(errs, {
			field: field_path, code: "invalid_type",
			message: sprintf("must be %s, got %s",
			                 _format_want(want), _json_type_name(val)),
		});
		return;
	}
	if (spec.enum != null && type(spec.enum) == "array") {
		let ok = false;
		for (let e in spec.enum) if (e == val) ok = true;
		if (!ok) push(errs, {
			field: field_path, code: "not_in_enum",
			message: sprintf("must be one of %J", spec.enum),
		});
	}
	let is_num = (type(val) == "int" || type(val) == "double");
	if (is_num && spec.minimum != null && val < spec.minimum)
		push(errs, { field: field_path, code: "out_of_range",
		             message: sprintf("must be >= %d", spec.minimum) });
	if (is_num && spec.maximum != null && val > spec.maximum)
		push(errs, { field: field_path, code: "out_of_range",
		             message: sprintf("must be <= %d", spec.maximum) });
	if (type(val) == "string" && spec.pattern != null) {
		let re = regexp(spec.pattern);
		if (re != null && !match(val, re))
			push(errs, { field: field_path, code: "invalid_format",
			             message: sprintf("must match %s", spec.pattern) });
	}
	if (type(val) == "array" && spec.items != null) {
		for (let i = 0; i < length(val); i++)
			_check_value(spec.items, val[i],
			             sprintf("%s[%d]", field_path, i), errs);
	}
	if (type(val) == "object" && spec.properties != null) {
		for (let e in check_schema_types(spec.properties, val, field_path))
			push(errs, e);
	}
};

check_schema_types = function(schema_properties, body, prefix) {
	let errs = [];
	if (type(body) != "object" || schema_properties == null) return errs;
	for (let key in schema_properties) {
		let spec = schema_properties[key];
		if (type(spec) != "object") continue;
		if (!exists(body, key)) continue;
		let val = body[key];
		if (val == null) continue;
		let field_path = (prefix != null && prefix != "") ? prefix + "." + key : key;
		_check_value(spec, val, field_path, errs);
	}
	return errs;
};

// schema_body: type-checked by check_schema_types (the wire delta from the
// client). validate_body: passed to resource.validate (the FULL post-merge
// view for cross-field checks). For POST/PUT both are the same body. For
// PATCH they differ: the merge inherits fromUci's view of existing options,
// which uci returns as strings even for integer-typed schema fields, so type-
// checking the merge would falsely 422 on any patch that didn't touch the
// integer field. Schema-check the delta only.
function _validate_with_schema(resource, schema_body, validate_body, conn, id) {
	let type_errs = check_schema_types(resource.schema_properties, schema_body);
	let val_errs = resource.validate(validate_body, conn, id);
	let seen = {};
	let merged = [];
	for (let e in type_errs) {
		let k = (e.field ?? "") + "|" + (e.code ?? "");
		if (seen[k]) continue;
		seen[k] = true;
		push(merged, e);
	}
	if (val_errs != null) {
		for (let e in val_errs) {
			let k = (e.field ?? "") + "|" + (e.code ?? "");
			if (seen[k]) continue;
			seen[k] = true;
			push(merged, e);
		}
	}
	return merged;
}

function attach_reload_headers(resp, result) {
	if (result.reload_status != null)
		resp.headers["X-Reload-Status"] = result.reload_status;
	if (type(result.reload_services) == "array" && length(result.reload_services) > 0)
		resp.headers["X-Reload-Services"] = join(",", result.reload_services);
	return resp;
}

function translate_tx(ctx, result) {
	if (result.ok) {
		let resp = attach_reload_headers(errors.ok(ctx, result.body), result);
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
	if (result.kind == "init_script_missing")
		return errors.error(ctx, "init_script_missing", result.message);
	if (result.kind == "reload_failed_restored")
		return errors.reload_failed_restored(ctx, result.reload_error);
	if (result.kind == "reload_failed_unrecovered")
		return errors.reload_failed_unrecovered(ctx, result.reload_error, result.restore_error);
	return errors.error(ctx, "internal_error",
	                    sprintf("transaction returned unknown kind %J", result.kind));
}

// Replace any uci options not in new_opts; set the rest. The two-loop shape
// is required because uci_set on an existing key updates; we have to
// explicitly delete the keys the new body omitted. The leading-dot keys
// (.name/.type/.anonymous) are pseudo and must not be touched.
function diff_apply(c, p, id, existing, new_opts) {
	for (let k in existing) {
		if (substr(k, 0, 1) == ".") continue;
		if (exists(new_opts, k)) continue;
		c.uci_delete(p, id, k);
	}
	for (let k in new_opts) c.uci_set(p, id, k, new_opts[k]);
}

// Reduce a PATCH body against existing state to a post-image plus a schema-
// validation target. JSON Patch (RFC 6902) synthesises the full post-image,
// so we schema-check that; merge-patch (RFC 7396) is partial, so we schema-
// check only the delta. Returns either { ok: true, merged, schema_body } or
// an error result that the caller short-circuits with.
function apply_patch_body(existing, existing_view, body, ctx, merge_fn) {
	if (ctx != null && ctx.json_patch == true) {
		let jp = jsonpatch.apply(existing_view, body);
		if (!jp.ok) {
			if (jp.code == "precondition_failed")
				return { ok: false, kind: "precondition_failed",
				         message: jp.message };
			return { ok: false, kind: "validation",
			         errors: [errors.field_error(
			           sprintf("[%d]", jp.op_index ?? 0),
			           "invalid_format", jp.message)] };
		}
		return { ok: true, merged: jp.value, schema_body: jp.value };
	}
	return { ok: true, merged: merge_fn(existing, existing_view, body),
	         schema_body: body };
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
		return paginate(ctx, out, query);
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
				let errs = _validate_with_schema(resource, body, body, c, null);
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
				let errs = _validate_with_schema(resource, body, body, c, id);
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
				diff_apply(c, p, id, existing, new_opts);
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

				let merge_fn = resource.merge_for_patch ?? default_merge_for_patch;
				let r = apply_patch_body(existing, existing_view, body, ctx, merge_fn);
				if (!r.ok) return r;

				let errs = _validate_with_schema(resource, r.schema_body, r.merged, c, id);
				if (length(errs) > 0)
					return { ok: false, kind: "validation", errors: errs };

				let new_opts = resource.toUci(r.merged);
				diff_apply(c, p, id, existing, new_opts);
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
				let existing_view = resource.fromUci(existing, conn);
				if (!existing_view.managed)
					return { ok: false, kind: "unmanaged_resource",
					         message: "Section is not uapi-managed" };
				let pc = precondition_check(ctx, existing_view);
				if (pc != null)
					return { ok: false, kind: "precondition_failed",
					         message: pc.body.message };
				c.uci_delete(p, id);
				return { ok: true, body: null };
			},
		}));

		if (result.ok)
			return attach_reload_headers(errors.no_content(ctx), result);
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

				let singleton_merge = function(_e, view, b) {
					let merged = { ...view };
					for (let k in b) merged[k] = b[k];
					return merged;
				};
				let r = apply_patch_body(existing, existing_view, body, ctx, singleton_merge);
				if (!r.ok) return r;

				let errs = _validate_with_schema(resource, r.schema_body, r.merged, c, id);
				if (length(errs) > 0)
					return { ok: false, kind: "validation", errors: errs };

				let new_opts = resource.toUci(r.merged);
				diff_apply(c, p, id, existing, new_opts);
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
		return paginate(ctx, resource.list_fn(conn, query), query);
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

return { make, make_singleton, make_collection, translate_tx, load_section,
         check_schema_types };
