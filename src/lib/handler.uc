let ids = require("ids");
let errors = require("errors");
let transaction = require("transaction");
let jsonpatch = require("jsonpatch");
let mgmt = require("mgmt");

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

// RFC 9110 13.1.2: a false If-None-Match is 304 for GET and HEAD, and 412 for every other
// method. uapi parsed the header for every verb and then dropped it on writes, so a caller
// asking for "create only if absent" had the condition discarded and its write performed.
// This runs inside the transaction closure, before uci_commit, which is what 13.2.2
// requires: a refusal here reverts and nothing is written.
//
// Evaluated after If-Match, per 13.2.2's ordering. `*` means "only if the resource does not
// exist", so on a write against an existing section it always fails.
function none_match_check(ctx, existing_body) {
	let want = parse_if_match(ctx.if_none_match);
	if (want == null) return null;
	if (existing_body == null) return null;         // nothing there: the condition holds
	if (want == "*")
		return errors.error(ctx, "precondition_failed",
			"If-None-Match: * requires the resource not to exist");
	let have = compute_etag(existing_body);
	for (let candidate in want)
		if (candidate == have)
			return errors.error(ctx, "precondition_failed",
				sprintf("If-None-Match matched the current ETag (current=\"%s\")", have));
	return null;
}

function precondition_check(ctx, existing_body) {
	let want = parse_if_match(ctx.if_match);
	if (want == null) return none_match_check(ctx, existing_body);
	if (want == "*" && existing_body != null) return none_match_check(ctx, existing_body);
	if (want == "*") return errors.error(ctx, "precondition_failed",
		"If-Match: * requires an existing resource");
	let have = compute_etag(existing_body);
	let matched = false;
	for (let candidate in want)
		if (candidate == have) matched = true;
	if (!matched)
		return errors.error(ctx, "precondition_failed",
			sprintf("If-Match did not match current ETag (current=\"%s\")", have));
	return none_match_check(ctx, existing_body);
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
//
// Keys read from `spec` here: type, enum, minimum, maximum, pattern, items,
// properties. `default` is intentionally NOT read: it is OpenAPI documentation
// only. Server-side defaults live in each resource's `fromUci`, and applying
// `default` here would silently fill absent fields on every write, defeating
// PATCH-delta semantics and re-creating the perpetual-diff loop the provider's
// clear-on-omit work depends on `default` NOT having runtime effect.
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
	// Every resource opened validate() by re-checking this, 43 copies of one guard, so a
	// module that forgot it would fault instead of returning 422. It is a guarantee here
	// now: validate() is only ever called with an object.
	//
	// It has to test validate_body and not schema_body. At the two merge-patch call sites
	// schema_body is the raw PATCH body, which is legitimately null when the request body
	// is empty; check_schema_types already returns [] for a non-object, so such a PATCH is
	// a no-op today, and guarding schema_body would start answering 422 instead.
	if (type(validate_body) != "object")
		return [ { field: "", code: "invalid_type",
		           message: "body must be a JSON object" } ];
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

// Caller-supplied section ids (body.id) must meet uci section-name rules and
// must not collide with any existing section in the package. The pattern and
// default length cap match what uci itself accepts; per-resource modules can
// tighten further in their own validate() (e.g. network.interfaces enforces
// the 15-char IFNAMSIZ limit because netifd uses the section name as the
// kernel netdev name).
const SECTION_ID_RE = /^[A-Za-z][A-Za-z0-9_]*$/;
const SECTION_ID_MAX_LEN = 32;

function validate_section_id(conn, pkg, id) {
	let errs = [];
	if (type(id) != "string") {
		push(errs, { field: "id", code: "invalid_type",
		             message: "must be a string" });
		return errs;
	}
	if (length(id) == 0 || length(id) > SECTION_ID_MAX_LEN || !match(id, SECTION_ID_RE)) {
		push(errs, { field: "id", code: "invalid_format",
		             message: sprintf("must be 1 to %d characters, start with a letter, and contain only letters, digits, and underscore (uci section-name rules)",
		                              SECTION_ID_MAX_LEN) });
		return errs;
	}
	let existing = null;
	try { existing = conn.uci_get(pkg, id); } catch (_) {}
	if (existing && type(existing) == "object" && existing['.type'] != null) {
		push(errs, { field: "id", code: "conflict",
		             message: sprintf("section '%s.%s' already exists (type=%s)",
		                              pkg, id, existing['.type']) });
	}
	return errs;
}

// Uniqueness for a field whose value other sections key on by value (e.g.
// firewall.zone.name -> src_zone references) or whose duplication breaks the
// daemon (e.g. sqm.queue.interface -> only one queue per interface). Scoped
// to same package, same section type. ignore_section_id excludes the section
// being patched/replaced so an unchanged value passes.
function validate_unique_field(conn, pkg, sec_type, field, value, ignore_section_id) {
	let errs = [];
	if (value == null) return errs;
	let conflict = null;
	conn.uci_foreach(pkg, sec_type, function(s) {
		if (s['.name'] == ignore_section_id) return;
		if (s[field] == value) {
			conflict = s['.name'];
			return false;
		}
	});
	if (conflict != null) {
		push(errs, { field: field, code: "conflict",
		             message: sprintf("section '%s.%s' already uses %s=%J",
		                              pkg, conflict, field, value) });
	}
	return errs;
}

function attach_reload_headers(resp, result) {
	if (result.reload_status != null)
		resp.headers["X-Reload-Status"] = result.reload_status;
	if (type(result.reload_services) == "array" && length(result.reload_services) > 0)
		resp.headers["X-Reload-Services"] = join(",", result.reload_services);
	if (result.kernel_status != null)
		resp.headers["X-Kernel-Status"] = result.kernel_status;
	if (type(result.kernel_applied) == "array" && length(result.kernel_applied) > 0)
		resp.headers["X-Kernel-Applied"] = join(",", result.kernel_applied);
	return resp;
}

// Advisory: the write already happened. It says "you moved the interface you are
// talking through", which is worth knowing while the connection still works, and is
// deliberately not a refusal, since renumbering the management path is a legitimate
// thing to do. The route lookup runs only after a successful write that actually moved a
// watched field, so the common write pays nothing for it.
//
// Its structural limit, stated because it is easy to expect more: if the write really
// does strand the caller, this response never arrives. It informs the survivable cases,
// which are the majority, and `/diagnostics` carries the same information ahead of a
// write for anyone who wants to check first.
function attach_mgmt_warning(resp, conn, ctx, id, changed) {
	if (changed == null || length(changed) == 0) return resp;
	// 200 for a replace or patch, 204 for a delete. Anything else is a write that did
	// not happen, and there is nothing to warn about.
	if (resp == null || (resp.status != 200 && resp.status != 204)) return resp;
	// The third argument is mgmt.uc's existing route-lookup seam. Production never sets
	// it, so this is the real `ip route get`; a test can substitute one, which is the
	// only way to reach the DELETE arm without stranding the box running the test.
	let path = mgmt.inbound_interface(conn, ctx.remote_addr, ctx.device_lookup);
	if (path == null || path.interface == null || path.interface != id) return resp;
	if (resp.headers == null) resp.headers = {};
	resp.headers["X-Mgmt-Path-Warning"] =
		sprintf("interface=%s changed=%s", id, join(",", changed));
	return resp;
}

function translate_tx(ctx, result) {
	if (result.ok) {
		let resp = attach_reload_headers(errors.ok(ctx, result.body), result);
		return (result.body != null) ? set_etag_header(resp, result.body) : resp;
	}
	if (result.kind == "locked")
		return errors.locked_from(ctx, null, result);
	if (result.kind == "lock_unavailable")
		return errors.lock_unavailable(ctx, result.error);
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

// PUT/replace semantics: the body is the whole resource, so any uci option
// not in new_opts is removed. Iterates the RAW existing section, so options
// the resource does not model are normalized away too (uapi owns the section
// on replace). The leading-dot keys (.name/.type/.anonymous) are pseudo.
function diff_apply(c, p, id, existing, new_opts) {
	for (let k in existing) {
		if (substr(k, 0, 1) == ".") continue;
		if (exists(new_opts, k)) continue;
		c.uci_delete(p, id, k);
	}
	for (let k in new_opts) c.uci_set(p, id, k, new_opts[k]);
}

// PATCH semantics: a partial update must not wipe options the resource does
// not model. old_opts is toUci(fromUci(existing)) -- exactly the modeled keys
// the section currently carries. We only delete within that footprint (a key
// the patch cleared); raw uci options outside it (toUci cannot emit them) are
// left untouched. Without this, a PATCH that touches one field would delete
// every stock/operator option the resource happens not to model.
function diff_apply_patch(c, p, id, old_opts, new_opts) {
	for (let k in old_opts) {
		if (substr(k, 0, 1) == ".") continue;
		if (exists(new_opts, k)) continue;
		c.uci_delete(p, id, k);
	}
	for (let k in new_opts) c.uci_set(p, id, k, new_opts[k]);
}

// A write-only field is masked on read, so a client that reads a section and
// writes it back never carries the secret. Every write path therefore has to
// restore it from uci, or a read-modify-write either erases the secret (PUT is
// full-replace) or trips a conditional-required rule (encryption=psk2 needs a
// key). Absent and explicit null both mean "keep": an IaC client that emits
// null for every unset optional attribute must not destroy a working key, so
// clearing a secret is deliberately not expressible.
function carry_write_only(resource, body, existing) {
	let sp = (resource != null) ? resource.schema_properties : null;
	if (type(sp) != "object" || type(body) != "object" || type(existing) != "object")
		return body;

	let out = { ...body };
	for (let k in sp)
		if (type(sp[k]) == "object" && sp[k].writeOnly
		    && out[k] == null && existing[k] != null)
			out[k] = existing[k];
	return out;
}

// Reduce a PATCH body against existing state to a post-image plus a schema-
// validation target. JSON Patch (RFC 6902) synthesises the full post-image,
// so we schema-check that; merge-patch (RFC 7396) is partial, so we schema-
// check only the delta. Returns either { ok: true, merged, schema_body } or
// an error result that the caller short-circuits with.
// The top-level fields a JSON Patch names, taken from the first segment of each
// op path. A resource whose read view exposes one uci option under two names has
// to know which of them the caller actually touched, and with merge-patch that is
// simply the body's keys. Without this the JSON Patch flavour cannot tell, and a
// single `replace /ipaddr` looked like a body asserting two different addresses.
function patch_touched_fields(ops, patched) {
	if (type(ops) != "array" || type(patched) != "object") return null;
	let out = {};
	for (let op in ops) {
		if (type(op) != "object" || type(op.path) != "string" || op.path == "") return null;
		let seg = split(op.path, "/")[1];
		if (seg == null || seg == "") return null;
		out[seg] = patched[seg];
	}
	return out;
}

function apply_patch_body(existing, existing_view, body, ctx, merge_fn, resource) {
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
		let post = carry_write_only(resource, jp.value, existing);
		// Run the resource's own merge over just the fields the patch named, so both
		// patch flavours resolve an aliased field the same way.
		let touched = (resource != null && resource.merge_for_patch != null)
		              ? patch_touched_fields(body, post) : null;
		if (touched != null)
			post = carry_write_only(resource,
			                        resource.merge_for_patch(post, touched), existing);
		return { ok: true, merged: post, schema_body: post };
	}
	// A merge patch is a partial object. Anything else used to be folded into the read
	// view and answered 200 without writing anything, so a malformed body was
	// indistinguishable from a successful no-op. Only the merge flavour is restricted:
	// the JSON Patch branch above takes an array of ops by definition.
	//
	// A null body is not the same thing and stays a no-op. That is a request naming no
	// fields, which is what an empty request body has always meant here. A literal `null`
	// body lands here too, and deliberately so: it is indistinguishable from an absent one
	// by this point, and the raw text that would separate them is the whole batch document
	// for a sub-request, so there is no reading of it that holds at both entry points.
	if (body != null && type(body) != "object")
		return { ok: false, kind: "validation",
		         errors: [ { field: "", code: "invalid_type",
		                     message: "body must be a JSON object" } ] };
	return { ok: true, merged: carry_write_only(resource, merge_fn(existing_view, body), existing),
	         schema_body: body };
}

function default_merge_for_patch(existing_json, body) {
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
	// Optional per-resource id chooser; null falls through to the default ULID.
	let id_for_create = resource.id_for_create ?? function(body) { return null; };

	// unique_field on a dynamic-type resource would iterate by the sentinel
	// sec_type and silently miss every real section. Refuse to load so the
	// gap surfaces at startup rather than as a quiet runtime no-op.
	if (resource.unique_field != null && resource.type_predicate != null)
		die(sprintf("resource %s.%s: unique_field is not supported on dynamic-type resources",
		            pkg, sec_type));

	function check_unique_field(c, source, ignore_id) {
		if (resource.unique_field == null) return [];
		let val = source[resource.unique_field];
		if (type(val) != "string" || length(val) == 0) return [];
		return validate_unique_field(c, pkg, sec_type, resource.unique_field, val, ignore_id);
	}

	function tx_params(extra) {
		let p = { package: pkg, reload_services: reload_services };
		for (let k in tx_overrides) p[k] = tx_overrides[k];
		for (let k in extra) p[k] = extra[k];
		return p;
	}

	// What a write has to push to the kernel is only knowable inside the tx fn: for
	// wireguard peers the parent interface is encoded in the uci section type
	// rather than stored as an option, so a DELETE can only read it off the section
	// it is about to remove, and the preshared key has to come from the uci options
	// because the read view masks it. The array is handed to the transaction before
	// fn runs and read after the commit, so fn filling it in between is the whole
	// point. /batch passes its own sink in ctx so every sub-request accumulates
	// into one ordered list applied once.
	function collect_kernel_ops(sink, kind, opts, sec_type, existing) {
		if (resource.kernel_ops == null) return;
		let ops = resource.kernel_ops(kind, opts, sec_type, existing);
		if (type(ops) != "array") return;
		for (let op in ops) push(sink, op);
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
		let kops = ctx.kernel_sink ?? [];
		let result = transaction.transaction(conn, tx_params({
			wg_ops: kops,
			fn: function(c, p) {
				// Section-name resolution: caller's body.id wins, else the
				// per-resource id_for_create hook (e.g. network.interfaces
				// aliasing body.name; wireguard's wg_<rand> IFNAMSIZ-tight
				// fallback), else a server-emitted ULID.
				let caller_id = (type(body) == "object" && body.id != null) ? body.id : null;
				let hook_id = (caller_id == null) ? id_for_create(body) : null;
				let new_id = caller_id ?? hook_id ?? ids.new_id(id_prefix);

				// Validate anything that wasn't a server-emitted ULID:
				// body.id is caller-supplied; hook_id may be caller-derived
				// (network.interfaces aliases body.name) or server-derived
				// (wireguard short fallback). Server-derived ids match the
				// rules by construction; we validate anyway so the cost is
				// just one extra uci_get per non-ULID create.
				if (caller_id != null || hook_id != null) {
					let id_errs = validate_section_id(c, p, new_id);
					if (length(id_errs) > 0)
						return { ok: false, kind: "validation", errors: id_errs };
				}

				let errs = _validate_with_schema(resource, body, body, c, null);
				if (length(errs) > 0)
					return { ok: false, kind: "validation", errors: errs };

				let uf_errs = check_unique_field(c, body, null);
				if (length(uf_errs) > 0)
					return { ok: false, kind: "validation", errors: uf_errs };

				let new_opts = resource.toUci(body);
				let resolved_type = create_type(body);
				c.uci_create_section(p, new_id, resolved_type);
				for (let k in new_opts) c.uci_set(p, new_id, k, new_opts[k]);
				let view = { ...new_opts };
				view['.name'] = new_id;
				view['.anonymous'] = false;
				view['.type'] = resolved_type;
				let out = resource.fromUci(view, conn);
				collect_kernel_ops(kops, "create", new_opts, resolved_type, null);
				return { ok: true, body: out };
			},
		}));

		return translate_tx(ctx, result);
	}

	function replace(conn, ctx, id, body) {
		let kops = ctx.kernel_sink ?? [];
		let mgmt_changed = null;
		let result = transaction.transaction(conn, tx_params({
			wg_ops: kops,
			fn: function(c, p) {
				// Read before validating so a masked secret can be restored first,
				// but keep reporting validation ahead of not_found. Kept in its own
				// binding rather than reassigning body, because it holds a plaintext
				// secret and must not outlive the write.
				let existing = load_section(c, p, id);
				let write_body = carry_write_only(resource, body, existing);
				if (resource.resolve_for_replace != null)
					write_body = resource.resolve_for_replace(write_body);
				let errs = _validate_with_schema(resource, write_body, write_body, c, id);
				if (length(errs) > 0)
					return { ok: false, kind: "validation", errors: errs };
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

				let uf_errs = check_unique_field(c, write_body, id);
				if (length(uf_errs) > 0)
					return { ok: false, kind: "validation", errors: uf_errs };

				if (resource.mgmt_path_guard)
					mgmt_changed = mgmt.changed_fields(existing_view, write_body);

				let new_opts = resource.toUci(write_body);
				diff_apply(c, p, id, existing, new_opts);
				let view = { ...new_opts };
				view['.name'] = id;
				view['.anonymous'] = false;
				view['.type'] = existing['.type'];
				let out = resource.fromUci(view, conn);
				collect_kernel_ops(kops, "update", new_opts, existing['.type'], existing);
				return { ok: true, body: out };
			},
		}));

		return attach_mgmt_warning(translate_tx(ctx, result), conn, ctx, id, mgmt_changed);
	}

	function patch(conn, ctx, id, body) {
		let kops = ctx.kernel_sink ?? [];
		let mgmt_changed = null;
		let result = transaction.transaction(conn, tx_params({
			wg_ops: kops,
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
				let r = apply_patch_body(existing, existing_view, body, ctx, merge_fn, resource);
				if (!r.ok) return r;

				let errs = _validate_with_schema(resource, r.schema_body, r.merged, c, id);
				if (length(errs) > 0)
					return { ok: false, kind: "validation", errors: errs };

				let uf_errs = check_unique_field(c, r.merged, id);
				if (length(uf_errs) > 0)
					return { ok: false, kind: "validation", errors: uf_errs };

				// Against the merged body, not the request body: a PATCH naming only
				// `proto` still has to be compared field by field against what was there.
				if (resource.mgmt_path_guard)
					mgmt_changed = mgmt.changed_fields(existing_view, r.merged);

				let new_opts = resource.toUci(r.merged);
				diff_apply_patch(c, p, id, resource.toUci(existing_view), new_opts);
				let view = { ...new_opts };
				view['.name'] = id;
				view['.anonymous'] = false;
				view['.type'] = existing['.type'];
				let out = resource.fromUci(view, conn);
				collect_kernel_ops(kops, "update", new_opts, existing['.type'], existing);
				return { ok: true, body: out };
			},
		}));

		return attach_mgmt_warning(translate_tx(ctx, result), conn, ctx, id, mgmt_changed);
	}

	function remove(conn, ctx, id) {
		let kops = ctx.kernel_sink ?? [];
		// Deleting the interface the caller arrived through strands them as surely as
		// renumbering it, and none of LuCI's four field names covers a delete.
		let mgmt_changed = resource.mgmt_path_guard ? [ "removed" ] : null;
		let result = transaction.transaction(conn, tx_params({
			wg_ops: kops,
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
				collect_kernel_ops(kops, "remove", null, existing['.type'], existing);
				return { ok: true, body: null };
			},
		}));

		if (result.ok)
			return attach_mgmt_warning(attach_reload_headers(errors.no_content(ctx), result),
			                           conn, ctx, id, mgmt_changed);
		return translate_tx(ctx, result);
	}

	function adopt(conn, ctx, id) {
		// Named sections (the box's default `lan` / `wan` zones, anything
		// uci-set out-of-band) are addressable as-is; adopt is an idempotent
		// acknowledgement that doesn't change uci state. Short-circuit
		// before the transaction so we don't acquire a per-package lock or
		// fire a service reload for a no-op. The previous transactional
		// path called reload(services) unconditionally on the success path,
		// which meant N adopts during a Terraform import triggered N
		// firewall/network reloads with brief visible glitches each.
		let preview = load_section(conn, pkg, id);
		if (!preview || !type_predicate(preview['.type']))
			return errors.error(ctx, "not_found",
			                    sprintf("No %s with id %J", sec_type, id));
		if (!preview['.anonymous']) {
			let view = resource.fromUci(preview, conn);
			return set_etag_header(errors.ok(ctx, view), view);
		}
		// Anonymous (cfgXXXXXX) section: needs a uci_rename to a stable
		// name, so we go through the full transaction (snapshot + commit +
		// reload + restore-on-failure).
		let result = transaction.transaction(conn, tx_params({
			fn: function(c, p) {
				let existing = load_section(c, p, id);
				if (!existing || !type_predicate(existing['.type']))
					return { ok: false, kind: "not_found",
					         message: sprintf("No %s with id %J", sec_type, id) };
				if (!existing['.anonymous']) {
					// Section was renamed between the preview load and the
					// transaction; treat as the named-ack path.
					return { ok: true, body: resource.fromUci(existing, conn) };
				}
				let new_id = id_for_create(resource.fromUci(existing, conn))
				             ?? ids.new_id(id_prefix);
				c.uci_rename(p, id, new_id);
				let view = { ...existing };
				view['.name'] = new_id;
				view['.anonymous'] = false;
				return { ok: true, body: resource.fromUci(view, conn) };
			},
		}));

		return translate_tx(ctx, result);
	}

	// The same pre-validate path a write takes, run over what is already in uci.
	// Both steps matter and neither is obvious: carry_write_only, or every section
	// holding a masked secret reports its own secret as missing, which on a
	// wireguard-heavy router condemns the most important sections on the box; and
	// check_schema_types, because enum and range constraints live in
	// schema_properties rather than in validate(), so skipping it would miss a
	// whole class of tightening while looking thorough.
	//
	// carry_write_only makes this the only path that puts a real secret into a body
	// whose error messages are returned to a caller holding just `:ro`, which the
	// masked read view never exposes. So no validate() message may interpolate a
	// writeOnly value; see docs/adding-a-resource.md § Write-only fields.
	function sweep(conn) {
		let out = [];
		conn.uci_foreach(pkg, null, function(s) {
			if (!type_predicate(s['.type'])) return;
			let id = s['.name'];
			let view, errs;
			try {
				view = resource.fromUci(s, conn);
				let body = carry_write_only(resource, view, s);
				errs = _validate_with_schema(resource, body, body, conn, id);
			} catch (e) {
				// A resource that throws on a section it cannot read is itself a
				// finding, and must not take the whole sweep down with it.
				errs = [ { field: "", code: "unreadable", message: "" + e } ];
			}
			if (length(errs ?? []) > 0)
				push(out, { id: id, managed: (view != null) ? !!view.managed : null,
				            errors: errs });
		});
		return out;
	}

	return { list, get_one, create, replace, patch, remove, adopt, sweep };
}

function make_singleton(resource, opts) {
	let pkg = resource.package;
	let sec_type = resource.type;
	let reload_services = resource.reload ?? [];
	let tx_overrides = (opts != null && opts.tx != null) ? opts.tx : {};
	// Opt-in upsert for singletons where the underlying uci package can be
	// absent entirely (e.g. unbound-uci-ext's extension UCIs that ship a
	// default `main` section the operator could conceivably wipe). Without
	// the flag, a missing section returns 404 so the operator notices that
	// the wrapping package isn't installed correctly.
	let create_if_missing = !!resource.create_if_missing;
	let singleton_section_name = resource.singleton_section_name ?? "main";

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
				let synthesized = false;
				if (!existing) {
					if (!create_if_missing)
						return { ok: false, kind: "not_found",
						         message: sprintf("singleton %s.%s missing", pkg, sec_type) };
					// Synthesize the section. uci_create_section makes a
					// named section that subsequent find() calls would see;
					// we also build a local stub here so the patch logic
					// below treats it as if it had pre-existed empty.
					c.uci_create_section(p, singleton_section_name, sec_type);
					existing = {};
					existing['.name'] = singleton_section_name;
					existing['.anonymous'] = false;
					existing['.type'] = sec_type;
					synthesized = true;
				}
				let id = existing['.name'];

				let existing_view = resource.fromUci(existing, conn);
				// A synthesized section did not exist when the request arrived, and a
				// precondition asks about the resource the caller addressed, not about the
				// stub staged a few lines up. Passing the stub made `If-None-Match: *`
				// answer 412 for a resource GET reports as 404, which is exactly the
				// create-if-absent case RFC 9110 13.1.2 says must proceed.
				let pc = precondition_check(ctx, synthesized ? null : existing_view);
				if (pc != null)
					return { ok: false, kind: "precondition_failed",
					         message: pc.body.message };

				let singleton_merge = function(view, b) {
					let merged = { ...view };
					for (let k in b) merged[k] = b[k];
					return merged;
				};
				let r = apply_patch_body(existing, existing_view, body, ctx, singleton_merge, resource);
				if (!r.ok) return r;

				let errs = _validate_with_schema(resource, r.schema_body, r.merged, c, id);
				if (length(errs) > 0)
					return { ok: false, kind: "validation", errors: errs };

				let new_opts = resource.toUci(r.merged);
				diff_apply_patch(c, p, id, resource.toUci(existing_view), new_opts);
				let view = { ...new_opts };
				view['.name'] = id;
				view['.anonymous'] = !!existing['.anonymous'];
				view['.type'] = sec_type;
				return { ok: true, body: resource.fromUci(view, conn) };
			},
		}));

		return translate_tx(ctx, result);
	}

	// Same reasoning as the CRUD sweep above; a singleton has one section to check.
	function sweep(conn) {
		// By type, via the same finder `get` uses. Looking it up by
		// singleton_section_name misses every singleton whose uci section is not
		// called `main`, which includes firewall/defaults.
		let s = null;
		try { s = find(conn); } catch (e) { return []; }
		if (!s) return [];
		let id = s['.name'] ?? singleton_section_name;
		let view, errs;
		try {
			view = resource.fromUci(s, conn);
			let body = carry_write_only(resource, view, s);
			errs = _validate_with_schema(resource, body, body, conn, id);
		} catch (e) {
			errs = [ { field: "", code: "unreadable", message: "" + e } ];
		}
		if (length(errs ?? []) == 0) return [];
		return [ { id: id, managed: true, errors: errs } ];
	}

	return { get, patch, sweep };
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
