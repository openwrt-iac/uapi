let packages = require("packages");
let system_access = require("system_access");
let crontab = require("crontab");

// The non-uci special endpoints as resource declarations: the read shape of a
// collection (list_fn returning the items array, get_fn where ids exist) plus
// the write verbs each one supports. Every function returns a full response.
// path and id_noun drive the 405 messages, which must stay byte-identical to
// what the dispatch chain produced.
return {
	"packages/installed": {
		path: "packages/installed", type: "installed", id_noun: "<name>",
		list_fn:   function(ctx, conn) { return packages.list_installed(ctx).body; },
		get_fn:    function(ctx, conn, id) { return packages.get_installed(ctx, id); },
		create_fn: function(ctx, conn, body) { return packages.install(ctx, body); },
		remove_fn: function(ctx, conn, id) { return packages.remove_installed(ctx, id); },
	},
	"packages/feeds": {
		path: "packages/feeds", type: "feed", id_noun: "<id>",
		list_fn:   function(ctx, conn) { return packages.list_feeds(ctx).body; },
		get_fn:    function(ctx, conn, id) { return packages.get_feed(ctx, id); },
		create_fn: function(ctx, conn, body) { return packages.create_feed(ctx, body); },
		remove_fn: function(ctx, conn, id) { return packages.remove_feed(ctx, id); },
	},
	"system/password": {
		path: "system/password", type: "password", id_noun: "<id>",
		create_fn: function(ctx, conn, body) { return system_access.set_password(ctx, body); },
	},
	"system/authorized_keys": {
		path: "system/authorized_keys", type: "authorized_key", id_noun: "<id>",
		list_fn:    function(ctx, conn) { return system_access.list_keys(ctx).body; },
		get_fn:     function(ctx, conn, id) { return system_access.get_key(ctx, id); },
		create_fn:  function(ctx, conn, body) { return system_access.add_key(ctx, body); },
		replace_fn: function(ctx, conn, body) { return system_access.replace_keys(ctx, body); },
		remove_fn:  function(ctx, conn, id) { return system_access.remove_key(ctx, id); },
	},
	"system/cron_jobs": {
		path: "system/cron_jobs", type: "cron_job", id_noun: "<id>",
		list_fn:   function(ctx, conn) { return crontab.list_entries(ctx, conn).body; },
		get_fn:    function(ctx, conn, id) { return crontab.get_entry(ctx, conn, id); },
		create_fn: function(ctx, conn, body) { return crontab.add_entry(ctx, conn, body); },
		remove_fn: function(ctx, conn, id) { return crontab.remove_entry(ctx, conn, id); },
	},
};
