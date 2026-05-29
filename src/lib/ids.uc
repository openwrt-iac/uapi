let fs = require('fs');

const ALPHABET = "0123456789abcdefghjkmnpqrstvwxyz";
const TIME_LEN = 10;
const RAND_LEN = 16;
const ULID_LEN = TIME_LEN + RAND_LEN;

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

function new_id(type_prefix) {
	let prefix = type_prefix ?? "u";
	if (!match(prefix, /^[a-z]$/))
		die(sprintf("ids.new_id: type_prefix must be a single lowercase letter, got %J", type_prefix));
	return prefix + "_" + new_ulid();
}

function is_valid_id(s) {
	return type(s) == "string" && !!match(s, /^[a-z]_[0-9a-z]{26}$/);
}

return {
	new_id,
	new_ulid,
	is_valid_id,
};
