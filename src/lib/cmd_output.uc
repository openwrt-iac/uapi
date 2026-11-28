let ids = require('ids');

// What a command prints can quote any value of the config that it read, a write-only key
// among them. The error envelope reaches only the writer and keeps it. The diagnostics ring
// and syslog reach other readers and must not, so an error text marks each output that it
// carries, and these marks survive the concatenations and joins that nest one error in another.
// A message can also name a key that the client sent, control characters included, so each mark
// ends with a random id: a fixed mark let a client hide a part of its own error from the ring.
let open = null;
let close = null;

function unmarked(s) {
	return (open == null) ? s : join("", split(join("", split(s, open)), close));
}

function append(text, output) {
	if (open == null) {
		let id = ids.new_ulid();
		open = "\x1e" + id;
		close = "\x1f" + id;
	}
	return text + open + ": " + (output ?? "") + close;
}

function for_writer(s) {
	return (type(s) == "string") ? unmarked(s) : s;
}

// A mark that the text does not close hides the rest of it: an output cut short must not leak.
function without_output(s) {
	if (type(s) != "string" || open == null) return s;
	let parts = split(s, open);
	let out = parts[0];
	for (let i = 1; i < length(parts); i++) {
		let end = index(parts[i], close);
		if (end >= 0) out += substr(parts[i], end + length(close));
	}
	return unmarked(out);
}

// A body keeps the end of an output, where a command prints its cause: a package script can print a
// lot, and a client can put the whole field in the context of a model.
const MAX_OUTPUT = 4096;

function tail(s) {
	if (type(s) != "string" || length(s) <= MAX_OUTPUT) return s;
	// A cut inside a UTF-8 sequence would make the body hold text that is not UTF-8.
	let cut = length(s) - MAX_OUTPUT;
	while (cut < length(s) && (ord(s, cut) & 0xC0) == 0x80) cut++;
	return "..." + substr(s, cut);
}

return { append, for_writer, without_output, tail };
