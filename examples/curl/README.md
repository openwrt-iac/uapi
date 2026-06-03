# Curl examples

One script per resource, demonstrating CRUD against a running uapi instance.

Each script reads `UAPI_BASE` (default `https://router.local/api/v2`) and `UAPI_TOKEN` (no default; required) from the environment. They make their requests with `curl -k` so a self-signed uhttpd cert does not get in the way; remove that flag in production once you have proper TLS.

```sh
export UAPI_BASE=https://192.168.1.1/api/v2
export UAPI_TOKEN=<bearer printed by 'uapi-token create' on the router>

./firewall_rules.sh
./firewall_zones.sh
./dhcp_hosts.sh
./system.sh
```

The scripts intentionally do not clean up after themselves on the happy path so you can inspect the result in LuCI; each ends with a "to delete: curl ..." reminder.
