# Installation

## Prerequisites

A router running **OpenWrt 25.12+** (the first apk-based release line). Pulled-in dependencies are all in OpenWrt's `base` feed: `uhttpd`, `uhttpd-mod-ucode`, `ucode`, the `ucode-mod-{ubus,uci,fs,digest,log}` mods, and `rpcd-mod-iwinfo` (for the wireless `runtime` block). The package's `Depends:` makes apk resolve them automatically.

## Install from a local .apk

Get the package onto the router (any way you like: scp, USB stick, sysupgrade overlay), then:

```sh
apk add /path/to/uapi-<version>-r1.apk
```

The post-install hook will:

1. Run `/etc/uci-defaults/99-uapi` which adds `list ucode_prefix '/api/v3=/usr/share/uapi/main.uc'` to `uhttpd.main` and restarts uhttpd.
2. Delete itself.
3. Print the bootstrap message (first install only; suppressed on upgrade or reinstall).

Verify:

```sh
curl -k https://localhost/api/v3/healthz
# { "status": "ok", "version": "<version>",
#   "checks": { "ubus": "ok", "uci": "ok",
#               "lock_dir": "ok", "time_sync": "ok" } }
```

## Install from the project feed

The project hosts an apk feed at <https://openwrt-iac.github.io/feed/>. Packages are RSA-4096 signed; the public key is served from the feed root at <https://openwrt-iac.github.io/feed/uapi-feed.pub.pem> and the key source of truth lives at `openwrt-iac/openwrt-iac.github.io:keys/uapi-feed.pub.pem`. The feed aggregates stable releases from every repo under the `openwrt-iac` org (uapi, unbound-uci-ext, ...), so one `apk` repositories line installs any of them.

```sh
# Trust the feed's signing key (one-time). uclient-fetch ships with OpenWrt;
# curl does not, so a stock router cannot run a curl-based instruction.
uclient-fetch -qO /etc/apk/keys/uapi-feed.pub.pem \
    https://openwrt-iac.github.io/feed/uapi-feed.pub.pem

# Register the feed
echo 'https://openwrt-iac.github.io/feed/packages/all/uapi/packages.adb' \
    > /etc/apk/repositories.d/uapi.list

apk update
apk add uapi
```

To move an existing install to a newer release, `upgrade` rather than `add`:

```sh
apk update
apk upgrade uapi
```

`apk add uapi` does **not** upgrade a package that is already installed. On
apk-tools 3.0.5, as shipped in OpenWrt 25.12.x, it resolves to the installed
version, reinstalls it, and reports `OK`, so an operator who reaches for `add`
sees success and no new version and is likely to conclude the feed is stale.
`apk list uapi` shows what the feed actually offers, marking a newer one
`upgradable from: <installed>`.

This applies to `apk add <name>`, resolving from a repository. `apk add
<file.apk>`, the local-file form at the top of this page, does upgrade: it
installs the version in that file whether or not an older one is present.

The feed carries **stable releases only**. Release candidates (`-rc`, `-alpha`, `-beta`, `-pre`) are intentionally excluded so that `apk add uapi` and `apk upgrade uapi` never resolve to a not-yet-ready build. RC APKs land on the GitHub Release page (marked Pre-release); to install one, download it manually and `apk add --allow-untrusted /tmp/uapi-<rc>.apk`.

Every stable release stays available indefinitely, so pinning works: `apk add 'uapi<3.0.0'` holds a client to the v2 wire contract, and `apk add uapi=<version>-r1` pins an exact build. `CHANGELOG.md` and the GitHub Releases page are the sources of truth for what the current line is; this page deliberately does not name it, because a version written here goes stale the moment the next one ships.

## TLS

uapi inherits TLS from the `main` uhttpd instance. By default OpenWrt ships a self-signed certificate (regenerated at first boot via `px5g`); browsers and curl complain, and over a real network this is **not adequate**. Two well-trodden options on OpenWrt:

- **`acme.sh` + `luci-app-acme`**: ACME (Let's Encrypt) on the router itself. Requires the router to be reachable from the internet on port 80 (or DNS-01 challenge support).
- **Front the API with a reverse proxy** holding a real certificate (nginx, Caddy, traefik) on a different machine. Useful when the router lives behind double-NAT.

### Mutual TLS (client certificate auth)

`uhttpd` supports verifying client certificates if you set `option tls_client_cert_file` (path to a CA cert in PEM form) and `option tls_require_client_cert '1'` on the listener:

```sh
uci set uhttpd.main.tls_client_cert_file='/etc/uapi/clients-ca.pem'
uci set uhttpd.main.tls_require_client_cert='1'
uci commit uhttpd
/etc/init.d/uhttpd restart
```

After that, every request must present a certificate signed by the CA at `/etc/uapi/clients-ca.pem`. Combine this with a bearer-token scoped to read-only and you have two-factor service-account auth: the cert proves the caller is approved infrastructure; the token proves what scope it is allowed to exercise. uapi does not look at the client certificate fields itself; uhttpd terminates and validates them.

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
uci add_list uhttpd.<instance>.ucode_prefix='/api/v3=/usr/share/uapi/main.uc'
uci commit uhttpd
/etc/init.d/uhttpd reload
```

## Removal

```sh
apk del uapi
```

The pre-remove hook removes the `ucode_prefix` entry from `uhttpd.main` and reloads uhttpd. `/etc/config/uapi` (the token store) is conffile-marked and preserved across removal and upgrades. To wipe tokens: `rm /etc/config/uapi` after removal.
