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

// libuci replaces a package by renaming a temp file from the same directory over it, under an
// flock on the package file, and the restore writes the same way. A reader sees the old file or
// the new one, a kill or a full overlay leaves the old one whole, and the restore waits for a
// `uci commit` that is writing the package, as another commit would. ucode has no fsync: the
// commit that follows a restore rewrites the file through libuci, which syncs it.
function replace_config(fs_mod, file, content) {
	let path = fs_mod.realpath(file);
	let st = (path != null) ? fs_mod.stat(path) : null;
	let lock = (st != null) ? fs_mod.open(path, "r") : null;
	if (lock == null) die(sprintf("restore of %s: cannot open it", file));
	let tmp = sprintf("%s/.%s.uapi-restore", fs_mod.dirname(path), fs_mod.basename(path));
	let err = null;
	if (!lock.lock("x"))
		err = "cannot lock it: " + fs_mod.error();
	else {
		// A fixed name, so a restore killed before its rename leaves one file that the next
		// restore of the package removes. uapi's lock of the package keeps two from sharing it.
		fs_mod.unlink(tmp);
		let f = fs_mod.open(tmp, "wx", 0o600);
		if (f == null)
			err = "cannot create " + tmp;
		else {
			f.write(content);
			f.close();
			// close() drops the result of fclose, and flush() answers inverted on the ucode
			// that CI runs (docs/ucode-quirks.md), so the file is read back instead.
			let held = fs_mod.readfile(tmp) ?? "";
			if (held != content)
				err = sprintf("cannot write %s: it holds %d of %d bytes", tmp, length(held), length(content));
			else if (!fs_mod.chmod(tmp, st.mode) || !fs_mod.rename(tmp, path))
				err = sprintf("cannot rename %s over it: %s", tmp, fs_mod.error());
			if (err != null) fs_mod.unlink(tmp);
		}
	}
	lock.lock("u");
	lock.close();
	if (err != null) die(sprintf("restore of %s: %s", file, err));
}

function connect(opts) {
	let ubus_mod = opts?.ubus ?? require('ubus');
	let uci_mod = opts?.uci ?? require('uci');
	let fs_mod = opts?.fs ?? require('fs');
	let config_dir = opts?.config_dir ?? "/etc/config";
	let conn = ubus_mod.connect();
	if (!conn) die("ubus: connect failed");
	let cursor = uci_mod.cursor(config_dir);
	let debug = opts?.debug ? require('log') : null;

	// libuci gives a package that it loads by name the delta file of that name in each directory
	// of its search path, and /tmp/.uci, where `uci set` stages, is always one of them: cursor()
	// adds a directory but cannot remove that one, which is why rpcd clears the list itself. So
	// the cursor loads each package by its path, which reads the file alone.
	//
	// libuci commits a package loaded by path by writing the copy that it holds, where it reads a
	// package loaded by name again and replays the delta. So the commit reloads the file and
	// replays the writes kept here, and a commit by LuCI or a shell while the request ran stays.
	let writes = {};
	function load(pkg) {
		if (writes[pkg] == null && cursor.load(config_dir + "/" + pkg))
			writes[pkg] = [];
	}
	function drop(pkg) {
		cursor.unload(pkg);
		delete writes[pkg];
		return true;
	}
	function write(pkg, op) {
		load(pkg);
		let r = op();
		push(writes[pkg], op);
		return r;
	}

	// The cursor reports a failed write by returning null and raises nothing: on a missing
	// package, `set` and `commit` both answer null with "Entry not found", so a write that stored
	// nothing answered 200. A delete of what is already gone has the result it asked for.
	function wrote(op, pkg, r) {
		if (r == null) die(sprintf("uci %s %s: %s", op, pkg, cursor.error() ?? "failed"));
		return r;
	}
	function removed(pkg, r) {
		let err = cursor.error();
		if (r == null && err != "Entry not found")
			die(sprintf("uci delete %s: %s", pkg, err ?? "failed"));
		return r;
	}

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
			load(pkg);
			if (option != null)
				return cursor.get(pkg, section, option);
			return cursor.get_all(pkg, section);
		},
		// uci cannot represent an empty list: uval_to_uci returns false for a
		// zero-length array and the set is silently discarded, so a cleared list used
		// to answer 200 with the old value still in place. `[]` is the absence of a
		// value, so setting one is a delete. Doing it here rather than in each caller
		// is deliberate: there are six write loops across handler.uc and raw.uc, and
		// teaching only some of them is how the first version of this fix turned an
		// accepted create into a 500.
		uci_set: function(pkg, section, option, value) {
			if (type(value) == "array" && length(value) == 0)
				return write(pkg, () => removed(pkg, cursor.delete(pkg, section, option)));
			return write(pkg, () => wrote("set", pkg, cursor.set(pkg, section, option, value)));
		},
		uci_create_section: function(pkg, name, sec_type) {
			return write(pkg, () => wrote("set", pkg, cursor.set(pkg, name, sec_type)));
		},
		uci_rename: function(pkg, section, new_name) {
			return write(pkg, () => wrote("rename", pkg, cursor.rename(pkg, section, new_name)));
		},
		uci_delete: function(pkg, section, option) {
			return write(pkg, () => removed(pkg, option != null
				? cursor.delete(pkg, section, option)
				: cursor.delete(pkg, section)));
		},
		uci_commit: function(pkg) {
			let ops = writes[pkg] ?? [];
			drop(pkg);
			load(pkg);
			for (let op in ops) op();
			return wrote("commit", pkg, cursor.commit(pkg));
		},
		uci_package_exists: function(pkg) {
			return fs_mod.stat(config_dir + "/" + pkg) != null;
		},
		// cursor.revert() refuses a package loaded by path, and the writes of a request live
		// only in the cursor's copy, so dropping the copy reverts them.
		uci_revert: drop,
		uci_unload: drop,
		uci_export: function(pkg) {
			let f = fs_mod.open(config_dir + "/" + pkg, "r");
			if (!f) return "";
			let content = f.read("all") ?? "";
			f.close();
			return content;
		},
		uci_import: function(pkg, snapshot) {
			replace_config(fs_mod, config_dir + "/" + pkg, snapshot);
			return drop(pkg);
		},
		uci_foreach: function(pkg, sec_type, fn) {
			load(pkg);
			return cursor.foreach(pkg, sec_type, fn);
		},
	};
}

function stub(initial) {
	let init = initial ?? {};
	let st = {
		uci: deepcopy(init.uci ?? {}),
		missing_packages: init.missing_packages ?? [],
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
			if (option == null) return { ...deepcopy(sec), '.name': section };
			return sec[option];
		},

		// The real binding cannot store a zero-length array, so setting one deletes the
		// option. The stub used to accept it and store `[]`, which is why no unit test
		// could see a cleared list being silently dropped.
		uci_set: function(pkg, section, option, value) {
			if (type(value) == "array" && length(value) == 0) {
				if (st.uci[pkg] && st.uci[pkg][section]) delete st.uci[pkg][section][option];
				record("delete", pkg, section, option);
				return true;
			}
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

		uci_package_exists: function(pkg) {
			return index(st.missing_packages, pkg) == -1;
		},

		uci_revert: function(pkg) {
			record("revert", pkg);
			return true;
		},

		uci_unload: function(pkg) {
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
