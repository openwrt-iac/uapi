let fs = require('fs');

const ALPHABET = "0123456789abcdefghjkmnpqrstvwxyz";
const TIME_LEN = 10;
const RAND_LEN = 16;

function now_ms() {
	let c = clock();
	return c[0] * 1000 + int(c[1] / 1000000);
}

function encode_time(ms, len) {
	let out = "";
	for (let i = 0; i < len; i++) {
		out = substr(ALPHABET, ms & 0x1f, 1) + out;
		ms = ms >> 5;
	}
	return out;
}

function read_random(n) {
	let f = fs.open("/dev/urandom", "r");
	if (!f) die("ids.read_random: could not open /dev/urandom");
	let b = f.read(n);
	f.close();
	return b;
}

function encode_random(bytes, num_chars) {
	let out = "";
	let buf = 0;
	let bits = 0;
	let idx = 0;
	for (let i = 0; i < num_chars; i++) {
		while (bits < 5 && idx < length(bytes)) {
			buf = (buf << 8) | ord(bytes, idx);
			idx++;
			bits += 8;
		}
		let v = (buf >> (bits - 5)) & 0x1f;
		out += substr(ALPHABET, v, 1);
		bits -= 5;
		buf &= (1 << bits) - 1;
	}
	return out;
}

function new_ulid() {
	return encode_time(now_ms(), TIME_LEN) + encode_random(read_random(10), RAND_LEN);
}

// rand_len (optional, 1..26) substitutes a flat random suffix of that length
// for the standard 26-char time+rand ULID; the caller is responsible for the
// reason (see network.interfaces for the IFNAMSIZ-bound case).
function new_id(type_prefix, rand_len) {
	let prefix = type_prefix ?? "u";
	if (!match(prefix, /^[a-z]{1,3}$/))
		die(sprintf("ids.new_id: type_prefix must be 1-3 lowercase letters, got %J", type_prefix));
	if (rand_len != null) {
		if (type(rand_len) != "int" || rand_len < 1 || rand_len > 26)
			die(sprintf("ids.new_id: rand_len must be an int in 1..26, got %J", rand_len));
		return prefix + "_" + encode_random(read_random(int((rand_len * 5 + 7) / 8) + 1), rand_len);
	}
	return prefix + "_" + new_ulid();
}

function is_valid_id(s) {
	// Matches every shape new_id can emit: 1-3 lowercase prefix chars, then
	// either the 26-char time+rand ULID or a short rand-only suffix (11
	// chars or longer, capped at 26 to mirror new_id's rand_len max).
	return type(s) == "string" && !!match(s, /^[a-z]{1,3}_[0-9a-z]{11,26}$/);
}

return {
	new_id,
	new_ulid,
	is_valid_id,
};
