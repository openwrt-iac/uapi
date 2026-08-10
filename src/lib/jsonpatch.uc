// JSON Patch (RFC 6902). Operates on a target object and returns either the
// mutated copy or a structured error describing which op failed and why.
// The result is wrapped { ok: true, value } / { ok: false, ... } so the handler
// can translate to the standard error envelope without raising.

function _unescape_token(t) {
	let out = "";
	let i = 0;
	while (i < length(t)) {
		if (i + 2 <= length(t) && substr(t, i, 2) == "~1") { out += "/"; i += 2; }
		else if (i + 2 <= length(t) && substr(t, i, 2) == "~0") { out += "~"; i += 2; }
		else { out += substr(t, i, 1); i++; }
	}
	return out;
}

function _split_pointer(pointer) {
	if (type(pointer) != "string") return null;
	if (pointer == "") return [];
	if (substr(pointer, 0, 1) != "/") return null;
	let parts = split(substr(pointer, 1), "/");
	let out = [];
	for (let p in parts) push(out, _unescape_token(p));
	return out;
}

function _is_array_index(arr, token) {
	if (token == "-") return true;
	if (type(token) != "string" || !match(token, /^(0|[1-9][0-9]*)$/)) return false;
	let n = int(token);
	return n >= 0 && n <= length(arr);
}

function _array_index(arr, token) {
	if (token == "-") return length(arr);
	return int(token);
}

function _deep_clone(v) {
	let t = type(v);
	if (t == "array") {
		let out = [];
		for (let item in v) push(out, _deep_clone(item));
		return out;
	}
	if (t == "object") {
		let out = {};
		for (let k in v) out[k] = _deep_clone(v[k]);
		return out;
	}
	return v;
}

function _deep_equal(a, b) {
	let ta = type(a), tb = type(b);
	if (ta != tb) return false;
	if (ta == "array") {
		if (length(a) != length(b)) return false;
		for (let i = 0; i < length(a); i++)
			if (!_deep_equal(a[i], b[i])) return false;
		return true;
	}
	if (ta == "object") {
		let ka = [], kb = [];
		for (let k in a) push(ka, k);
		for (let k in b) push(kb, k);
		if (length(ka) != length(kb)) return false;
		for (let k in ka)
			if (!_deep_equal(a[k], b[k])) return false;
		return true;
	}
	return a == b;
}

function _resolve_parent(root, parts) {
	if (length(parts) == 0) return { error: "cannot operate on root parent" };
	let cur = root;
	for (let i = 0; i < length(parts) - 1; i++) {
		let key = parts[i];
		if (type(cur) == "array") {
			if (!_is_array_index(cur, key) || key == "-")
				return { error: sprintf("invalid array index %J at /%s", key, join("/", slice(parts, 0, i + 1))) };
			let idx = int(key);
			if (idx >= length(cur))
				return { error: sprintf("array index out of range at /%s", join("/", slice(parts, 0, i + 1))) };
			cur = cur[idx];
		} else if (type(cur) == "object") {
			if (!exists(cur, key))
				return { error: sprintf("missing path component /%s", join("/", slice(parts, 0, i + 1))) };
			cur = cur[key];
		} else {
			return { error: sprintf("path traversal into a scalar at /%s", join("/", slice(parts, 0, i))) };
		}
	}
	return { parent: cur, key: parts[length(parts) - 1] };
}

function _resolve_value(root, parts) {
	let cur = root;
	for (let i = 0; i < length(parts); i++) {
		let key = parts[i];
		if (type(cur) == "array") {
			if (!_is_array_index(cur, key) || key == "-")
				return { error: sprintf("invalid array index %J", key) };
			let idx = int(key);
			if (idx >= length(cur)) return { error: "array index out of range" };
			cur = cur[idx];
		} else if (type(cur) == "object") {
			if (!exists(cur, key)) return { error: sprintf("missing path component %J", key) };
			cur = cur[key];
		} else {
			return { error: "path traversal into a scalar" };
		}
	}
	return { value: cur };
}

function _add(root, parts, value) {
	if (length(parts) == 0) return { value: _deep_clone(value) };
	let r = _resolve_parent(root, parts);
	if (r.error != null) return { error: r.error };
	let parent = r.parent, key = r.key;
	if (type(parent) == "array") {
		if (!_is_array_index(parent, key))
			return { error: sprintf("invalid array index %J for add", key) };
		let idx = _array_index(parent, key);
		let out = [];
		for (let i = 0; i < idx; i++) push(out, parent[i]);
		push(out, value);
		for (let i = idx; i < length(parent); i++) push(out, parent[i]);
		// Mutate in place: ucode arrays are reference-shared via parent.
		while (length(parent) > 0) pop(parent);
		for (let x in out) push(parent, x);
	} else if (type(parent) == "object") {
		parent[key] = value;
	} else {
		return { error: "add into a scalar parent" };
	}
	return { value: root };
}

function _remove(root, parts) {
	if (length(parts) == 0) return { error: "cannot remove root" };
	let r = _resolve_parent(root, parts);
	if (r.error != null) return { error: r.error };
	let parent = r.parent, key = r.key;
	if (type(parent) == "array") {
		if (key == "-") return { error: "cannot remove the append marker" };
		if (!match(key, /^(0|[1-9][0-9]*)$/)) return { error: "invalid array index" };
		let idx = int(key);
		if (idx >= length(parent)) return { error: "array index out of range" };
		let kept = [];
		for (let i = 0; i < length(parent); i++) if (i != idx) push(kept, parent[i]);
		while (length(parent) > 0) pop(parent);
		for (let x in kept) push(parent, x);
	} else if (type(parent) == "object") {
		if (!exists(parent, key)) return { error: sprintf("missing key %J", key) };
		delete parent[key];
	} else {
		return { error: "remove from a scalar parent" };
	}
	return { value: root };
}

function _replace(root, parts, value) {
	let probe = _resolve_value(root, parts);
	if (probe.error != null) return { error: probe.error };
	let rm = _remove(root, parts);
	if (rm.error != null) return rm;
	return _add(rm.value, parts, value);
}

function apply(target, patch) {
	if (type(patch) != "array")
		return { ok: false, code: "validation_failed", message: "JSON Patch body must be an array of operations" };
	let working = _deep_clone(target);
	for (let i = 0; i < length(patch); i++) {
		let op = patch[i];
		if (type(op) != "object" || type(op.op) != "string" || type(op.path) != "string")
			return { ok: false, code: "validation_failed",
			         message: sprintf("op %d: must be an object with string op + path", i),
			         op_index: i };
		let parts = _split_pointer(op.path);
		if (parts == null)
			return { ok: false, code: "validation_failed",
			         message: sprintf("op %d: invalid JSON pointer %J", i, op.path),
			         op_index: i };
		let r;
		if (op.op == "add") {
			if (!exists(op, "value"))
				return { ok: false, code: "validation_failed",
				         message: sprintf("op %d: add requires value", i), op_index: i };
			r = _add(working, parts, op.value);
		} else if (op.op == "remove") {
			r = _remove(working, parts);
		} else if (op.op == "replace") {
			if (!exists(op, "value"))
				return { ok: false, code: "validation_failed",
				         message: sprintf("op %d: replace requires value", i), op_index: i };
			r = _replace(working, parts, op.value);
		} else if (op.op == "move" || op.op == "copy") {
			if (type(op.from) != "string")
				return { ok: false, code: "validation_failed",
				         message: sprintf("op %d: %s requires from", i, op.op), op_index: i };
			let from_parts = _split_pointer(op.from);
			if (from_parts == null)
				return { ok: false, code: "validation_failed",
				         message: sprintf("op %d: invalid from pointer %J", i, op.from),
				         op_index: i };
			let g = _resolve_value(working, from_parts);
			if (g.error != null)
				return { ok: false, code: "validation_failed",
				         message: sprintf("op %d: from: %s", i, g.error), op_index: i };
			if (op.op == "move") {
				let rm = _remove(working, from_parts);
				if (rm.error != null) return { ok: false, code: "validation_failed",
					message: sprintf("op %d: move-remove: %s", i, rm.error), op_index: i };
				working = rm.value;
			}
			r = _add(working, parts, _deep_clone(g.value));
		} else if (op.op == "test") {
			if (!exists(op, "value"))
				return { ok: false, code: "validation_failed",
				         message: sprintf("op %d: test requires value", i), op_index: i };
			let g = _resolve_value(working, parts);
			if (g.error != null)
				return { ok: false, code: "precondition_failed",
				         message: sprintf("op %d (test): %s", i, g.error), op_index: i };
			if (!_deep_equal(g.value, op.value))
				return { ok: false, code: "precondition_failed",
				         message: sprintf("op %d (test): value mismatch", i), op_index: i };
			r = { value: working };
		} else {
			return { ok: false, code: "validation_failed",
			         message: sprintf("op %d: unknown op %J", i, op.op), op_index: i };
		}
		if (r.error != null)
			return { ok: false, code: "validation_failed",
			         message: sprintf("op %d (%s): %s", i, op.op, r.error), op_index: i };
		working = r.value;
	}
	return { ok: true, value: working };
}

return { apply };
