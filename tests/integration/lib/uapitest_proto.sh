#!/bin/sh
# A proto handler that uapi does not model, for 62_unmodelled_proto_test: it keeps the config that
# netifd hands it, so the test reads what a handler receives after a uapi write.
. /lib/functions.sh
. ../netifd-proto.sh
init_proto "$@"

proto_uapitest_init_config() {
	no_device=1
	available=1
	proto_config_add_string ipaddr
	proto_config_add_string peer
	proto_config_add_array servers
	proto_config_add_boolean flag
}

proto_uapitest_setup() {
	local cfg="$1"
	json_dump > "/tmp/uapitest-$cfg.json"
	ip link add "ut-$cfg" type dummy
	ip link set "ut-$cfg" up
	proto_init_update "ut-$cfg" 1
	proto_send_update "$cfg"
}

proto_uapitest_teardown() {
	ip link del "ut-$1" 2>/dev/null
}

add_protocol uapitest
