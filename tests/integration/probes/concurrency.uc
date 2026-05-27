{%
'use strict';

let fs = require("fs");

let counter = 0;

function pid() {
	let s = fs.open("/proc/self/stat", "r").read("line");
	return int(split(s, " ")[0]);
}

global.handle_request = function(env) {
	sleep(1000);
	counter++;
	let body = sprintf('{"count":%d,"pid":%d}\n', counter, pid());
	uhttpd.send("Status: 200 OK\r\nContent-Type: application/json\r\n\r\n");
	uhttpd.send(body);
};
