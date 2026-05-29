function deepcopy(v) {
	if (type(v) == "array") {
		let out = [];
		for (let x in v) push(out, deepcopy(x));
		return out;
	}
	if (type(v) == "object") {
		let out = {};
		for (let k in v) out[k] = deepcopy(v[k]);
		return out;
	}
	return v;
}

function connect(opts) {
	let ubus_mod = require('ubus');
	let uci_mod = require('uci');
	let fs_mod = require('fs');
	let conn = ubus_mod.connect();
	if (!conn) die("ubus: connect failed");
	let cursor = uci_mod.cursor();
	let debug = (opts != null && opts.debug) ? require('log') : null;

	return {
		call: function(service, method, args) {
			if (debug)
				debug.syslog(debug.LOG_DEBUG,
					sprintf("uapi-bus call %s.%s args=%J", service, method, args ?? {}));
			let r = conn.call(service, method, args ?? {});
			if (r == null) {
				let err = ubus_mod.error();
				if (err != null)
					die(sprintf("ubus call %s.%s: %s", service, method, err));
			}
			return r;
		},
		uci_get: function(pkg, section, option) {
			if (option != null)
				return cursor.get(pkg, section, option);
			return cursor.get_all(pkg, section);
		},
		uci_set: function(pkg, section, option, value) {
			return cursor.set(pkg, section, option, value);
		},
		uci_create_section: function(pkg, name, sec_type) {
			return cursor.set(pkg, name, sec_type);
		},
		uci_rename: function(pkg, section, new_name) {
			return cursor.rename(pkg, section, new_name);
		},
		uci_delete: function(pkg, section, option) {
			return option != null
				? cursor.delete(pkg, section, option)
				: cursor.delete(pkg, section);
		},
		uci_commit: function(pkg) {
			return cursor.commit(pkg);
		},
		uci_revert: function(pkg) {
			return cursor.revert(pkg);
		},
		uci_export: function(pkg) {
			let f = fs_mod.open("/etc/config/" + pkg, "r");
			if (!f) return "";
			let content = f.read("all") ?? "";
			f.close();
			return content;
		},
		uci_import: function(pkg, snapshot) {
			let f = fs_mod.open("/etc/config/" + pkg, "w");
			if (!f) die("uci_import: cannot open /etc/config/" + pkg);
			f.write(snapshot);
			f.close();
			cursor.unload(pkg);
			cursor.load(pkg);
			return true;
		},
		uci_foreach: function(pkg, sec_type, fn) {
			return cursor.foreach(pkg, sec_type, fn);
		},
	};
}

function stub(initial) {
	let init = initial ?? {};
	let st = {
		uci: deepcopy(init.uci ?? {}),
		ubus_responses: { ...(init.ubus ?? {}) },
		ubus_calls: [],
		uci_ops: [],
	};

	function record(...args) {
		push(st.uci_ops, args);
	}

	function ensure_section(pkg, section) {
		if (!st.uci[pkg]) st.uci[pkg] = {};
		if (!st.uci[pkg][section]) st.uci[pkg][section] = {};
		return st.uci[pkg][section];
	}

	return {
		_state: st,

		set_ubus_response: function(service, method, response) {
			st.ubus_responses[service + " " + method] = response;
		},

		call: function(service, method, args) {
			let normalized_args = args ?? {};
			push(st.ubus_calls, [service, method, normalized_args]);
			let key = service + " " + method;
			let resp = st.ubus_responses[key];
			if (type(resp) == "function") return resp(normalized_args);
			if (type(resp) == "object" && exists(resp, "_error")) die(resp._error);
			return resp;
		},

		uci_get: function(pkg, section, option) {
			let s = st.uci[pkg];
			if (!s) return null;
			let sec = s[section];
			if (!sec) return null;
			if (option == null) return deepcopy(sec);
			return sec[option];
		},

		uci_set: function(pkg, section, option, value) {
			let sec = ensure_section(pkg, section);
			sec[option] = value;
			record("set", pkg, section, option, value);
			return true;
		},

		uci_create_section: function(pkg, name, sec_type) {
			if (!st.uci[pkg]) st.uci[pkg] = {};
			st.uci[pkg][name] = { ['.type']: sec_type };
			record("create_section", pkg, name, sec_type);
			return true;
		},

		uci_rename: function(pkg, section, new_name) {
			if (!st.uci[pkg] || !st.uci[pkg][section]) return false;
			st.uci[pkg][new_name] = st.uci[pkg][section];
			delete st.uci[pkg][section];
			record("rename", pkg, section, new_name);
			return true;
		},

		uci_delete: function(pkg, section, option) {
			if (!st.uci[pkg] || !st.uci[pkg][section]) return false;
			if (option == null) {
				delete st.uci[pkg][section];
				record("delete-section", pkg, section);
			} else {
				delete st.uci[pkg][section][option];
				record("delete-option", pkg, section, option);
			}
			return true;
		},

		uci_commit: function(pkg) {
			record("commit", pkg);
			return true;
		},

		uci_revert: function(pkg) {
			record("revert", pkg);
			return true;
		},

		uci_export: function(pkg) {
			return sprintf("%J", st.uci[pkg] ?? {});
		},

		uci_import: function(pkg, snapshot) {
			st.uci[pkg] = json(snapshot);
			record("import", pkg);
			return true;
		},

		uci_foreach: function(pkg, sec_type, fn) {
			let sections = st.uci[pkg] ?? {};
			for (let name in sections) {
				let s = sections[name];
				if (sec_type != null && s['.type'] != sec_type) continue;
				let view = { ...s };
				view['.name'] = name;
				let r = fn(view);
				if (r === false) return false;
			}
			return true;
		},
	};
}

return { connect, stub };
