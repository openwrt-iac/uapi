# Installation

## Prerequisites

A router running **OpenWrt 25.12+** (the first apk-based release line). Pulled-in dependencies are all in OpenWrt's `base` feed: `uhttpd`, `uhttpd-mod-ucode`, `ucode`, and the `ucode-mod-{ubus,uci,fs,digest,log}` mods. The package's `Depends:` makes apk resolve them automatically.

## Install from a local .apk

Get the package onto the router (any way you like: scp, USB stick, sysupgrade overlay), then:

```sh
apk add /path/to/uapi-<version>-r1.apk
```

The post-install hook will:

1. Run `/etc/uci-defaults/99-uapi` which adds `list ucode_prefix '/api/v1=/usr/share/uapi/main.uc'` to `uhttpd.main` and reloads uhttpd.
2. Delete itself.
3. Print the bootstrap message.

Verify:

```sh
curl -k https://localhost/api/v1/healthz
# { "status": "ok", "version": "<version>" }
```

## Install from the project feed

The project hosts an apk feed at <https://raspbeguy.github.io/uapi/>. Packages are RSA-4096 signed; the public key lives in the repo at `keys/uapi-feed.pub.pem` and is also served from the feed itself.

```sh
# Trust the feed's signing key (one-time)
curl -fsSL https://raspbeguy.github.io/uapi/uapi-feed.pub.pem \
    | tee /etc/apk/keys/uapi-feed.pub.pem > /dev/null

# Register the feed
echo 'https://raspbeguy.github.io/uapi/packages/all/uapi/packages.adb' \
    > /etc/apk/repositories.d/uapi.list

apk update
apk add uapi
```

The feed currently ships pre-release (`-rc`) packages; expect to upgrade as the project hardens. Until v1.0.0 final, `apk add` will pull the latest release candidate.

## TLS

uapi inherits TLS from the `main` uhttpd instance. By default OpenWrt ships a self-signed certificate (regenerated at first boot via `px5g`); browsers and curl complain, and over a real network this is **not adequate**. Two well-trodden options on OpenWrt:

- **`acme.sh` + `luci-app-acme`**: ACME (Let's Encrypt) on the router itself. Requires the router to be reachable from the internet on port 80 (or DNS-01 challenge support).
- **Front the API with a reverse proxy** holding a real certificate (nginx, Caddy, traefik) on a different machine. Useful when the router lives behind double-NAT.

uapi enforces TLS by default for any request whose `REMOTE_ADDR` is not loopback:

```
HTTP/1.1 403 Forbidden
{ "code": "tls_required", ... }
```

To bypass during testing on a closed network, create the marker file:

```sh
touch /etc/uapi.insecure
```

That **is** a security hole; don't leave it on a production router.

## Multiple uhttpd instances

The package wires only the `uhttpd.main` instance. If you run additional instances (e.g. a separate admin port), add the prefix manually:

```sh
uci add_list uhttpd.<instance>.ucode_prefix='/api/v1=/usr/share/uapi/main.uc'
uci commit uhttpd
/etc/init.d/uhttpd reload
```

## Removal

```sh
apk del uapi
```

The pre-remove hook removes the `ucode_prefix` entry from `uhttpd.main` and reloads uhttpd. `/etc/config/uapi` (the token store) is conffile-marked and preserved across removal and upgrades. To wipe tokens: `rm /etc/config/uapi` after removal.
