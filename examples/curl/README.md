# Curl examples

Scripts that call a running uapi instance. Most show one curated resource.
`adopt.sh` shows adoption of an unmanaged section, and `raw.sh` shows `/raw/`.

Each script requires `UAPI_BASE` and `UAPI_TOKEN` in the environment and fails
closed if either is unset. They make their requests with `curl -k` so a
self-signed uhttpd cert does not get in the way; remove that flag in production
once you have proper TLS.

```sh
export UAPI_BASE=https://192.168.1.1/api/v4
export UAPI_TOKEN=<bearer printed by 'uapi-token create' on the router>

./firewall_rules.sh
./firewall_zones.sh
./dhcp_hosts.sh
./system.sh
```

The scripts do not remove what they create, so you can look at the result in
LuCI. A script that creates something ends with the command that deletes it.
