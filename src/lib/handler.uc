let ids = require("ids");
let errors = require("errors");
let transaction = require("transaction");

function build_field_errors(raw_errs) {
	let out = [];
	for (let e in raw_errs)
		push(out, errors.field_error(e.field, e.code, e.message));
	return out;
}

function translate_tx(ctx, result) {
	if (result.ok) return errors.ok(ctx, result.body);
	if (result.kind == "locked") return errors.locked(ctx);
	if (result.kind == "validation")
		return errors.validation_failed(ctx, build_field_errors(result.errors));
	if (result.kind == "reload_failed_restored")
		return errors.reload_failed_restored(ctx, result.reload_error);
	if (result.kind == "reload_failed_unrecovered")
		return errors.reload_failed_unrecovered(ctx, result.reload_error, result.restore_error);
	return errors.error(ctx, "internal_error",
	                    sprintf("transaction returned unknown kind %J", result.kind));
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

	function tx_params(extra) {
		let p = { package: pkg, reload_services: reload_services };
		for (let k in tx_overrides) p[k] = tx_overrides[k];
		for (let k in extra) p[k] = extra[k];
		return p;
	}

	function list(conn, ctx, query) {
		let want_managed = query.managed;
		let out = [];
		conn.uci_foreach(pkg, sec_type, function(s) {
			let r = resource.fromUci(s);
			if (want_managed == "true" && !r.managed) return;
			if (want_managed == "false" && r.managed) return;
			push(out, r);
		});
		return errors.ok(ctx, out);
	}

	function get_one(conn, ctx, id) {
		let s = load_section(conn, pkg, id);
		if (!s || s['.type'] != sec_type)
			return errors.error(ctx, "not_found",
			                    sprintf("No %s with id %J", sec_type, id));
		return errors.ok(ctx, resource.fromUci(s));
	}

	function create(conn, ctx, body) {
		let errs = resource.validate(body, conn);
		if (length(errs) > 0)
			return errors.validation_failed(ctx, build_field_errors(errs));

		let new_id = ids.new_id(substr(sec_type, 0, 1));
		let new_opts = resource.toUci(body);

		let result = transaction.transaction(conn, tx_params({
			fn: function(c, p) {
				c.uci_create_section(p, new_id, sec_type);
				for (let k in new_opts) c.uci_set(p, new_id, k, new_opts[k]);
				let view = { ...new_opts };
				view['.name'] = new_id;
				view['.anonymous'] = false;
				view['.type'] = sec_type;
				return { ok: true, body: resource.fromUci(view) };
			},
		}));

		return translate_tx(ctx, result);
	}

	function replace(conn, ctx, id, body) {
		let existing = load_section(conn, pkg, id);
		if (!existing || existing['.type'] != sec_type)
			return errors.error(ctx, "not_found",
			                    sprintf("No %s with id %J", sec_type, id));
		if (!resource.fromUci(existing).managed)
			return errors.error(ctx, "unmanaged_resource",
			                    "Section is not uapi-managed; adopt it first");

		let errs = resource.validate(body, conn);
		if (length(errs) > 0)
			return errors.validation_failed(ctx, build_field_errors(errs));

		let new_opts = resource.toUci(body);
		let result = transaction.transaction(conn, tx_params({
			fn: function(c, p) {
				for (let k in existing) {
					if (substr(k, 0, 1) == ".") continue;
					if (exists(new_opts, k)) continue;
					c.uci_delete(p, id, k);
				}
				for (let k in new_opts) c.uci_set(p, id, k, new_opts[k]);
				let view = { ...new_opts };
				view['.name'] = id;
				view['.anonymous'] = false;
				view['.type'] = sec_type;
				return { ok: true, body: resource.fromUci(view) };
			},
		}));

		return translate_tx(ctx, result);
	}

	function patch(conn, ctx, id, body) {
		let existing = load_section(conn, pkg, id);
		if (!existing || existing['.type'] != sec_type)
			return errors.error(ctx, "not_found",
			                    sprintf("No %s with id %J", sec_type, id));
		if (!resource.fromUci(existing).managed)
			return errors.error(ctx, "unmanaged_resource",
			                    "Section is not uapi-managed; adopt it first");

		let merged_json = { ...resource.fromUci(existing), ...body };
		if (body.match != null) {
			merged_json.match = { ...resource.fromUci(existing).match, ...body.match };
		}

		let errs = resource.validate(merged_json, conn);
		if (length(errs) > 0)
			return errors.validation_failed(ctx, build_field_errors(errs));

		let new_opts = resource.toUci(merged_json);
		let result = transaction.transaction(conn, tx_params({
			fn: function(c, p) {
				for (let k in existing) {
					if (substr(k, 0, 1) == ".") continue;
					if (exists(new_opts, k)) continue;
					c.uci_delete(p, id, k);
				}
				for (let k in new_opts) c.uci_set(p, id, k, new_opts[k]);
				let view = { ...new_opts };
				view['.name'] = id;
				view['.anonymous'] = false;
				view['.type'] = sec_type;
				return { ok: true, body: resource.fromUci(view) };
			},
		}));

		return translate_tx(ctx, result);
	}

	function remove(conn, ctx, id) {
		let existing = load_section(conn, pkg, id);
		if (!existing || existing['.type'] != sec_type)
			return errors.error(ctx, "not_found",
			                    sprintf("No %s with id %J", sec_type, id));
		if (!resource.fromUci(existing).managed)
			return errors.error(ctx, "unmanaged_resource",
			                    "Section is not uapi-managed");

		let result = transaction.transaction(conn, tx_params({
			fn: function(c, p) {
				c.uci_delete(p, id);
				return { ok: true, body: null };
			},
		}));

		if (result.ok) return errors.no_content(ctx);
		return translate_tx(ctx, result);
	}

	return { list, get_one, create, replace, patch, remove };
}

return { make, translate_tx };
