# Field feedback for uapi (from a v2.0.0 provider migration)

Relayed from a real-world migration of a ~127-resource OPNsense router to OpenWrt
driven through `terraform-provider-uapi` v2.0.0 (plan/apply against a live
OpenWrt 25.12.4 box, not just `validate`). These are the items that are
**uapi-side**, not provider-side; the provider can paper over some but the root
fix is in uapi. Ordered by impact.

## What the field run validated (do not regress)

So this is not only complaints. The migration confirmed several design choices
are genuinely good:

- **Singleton adoption** mapped `uapi_unbound_server` onto the existing `ub_main`
  section and `uapi_dhcp_dnsmasq` onto `@dnsmasq[0]` with no duplicate sections
  and no clobbering. Called out as a highlight.
- **The dnsmasq + unbound split** (dnsmasq `noresolv=1` forwarding to a recursive
  unbound on `127.0.0.1:5353`) worked end to end after apply.
- **ETag/If-Match** concurrency and the **ULID stable-id** model.
- **Write-only `password_wo`** for `system_password`.

## C1 [BLOCKING] WireGuard interfaces never come up: ULID section name exceeds IFNAMSIZ

`proto wireguard` interfaces apply with a 2xx and show up in LuCI, but the
tunnels stay permanently down. Root cause: uapi names every managed section with
a ~28-char ULID (e.g. `i_01ktbzbxb5yf83d1a2ez3s4nvq`), and OpenWrt's
`/lib/netifd/proto/wireguard.sh` derives the **kernel netdev name from the
interface section name**. Linux caps interface names at 15 chars (`IFNAMSIZ`),
so netifd cannot create the device:

```
netifd: i_01ktbzbxb5yf83d1a2ez3s4nvq: Error: Attribute failed policy validation.
netifd: i_01ktbzbxb5yf83d1a2ez3s4nvq: Could not sync WireGuard configuration
```

Confirmed directly on the box (the section name is the only variable):

```sh
ip link add dev i_01ktbzbxb5yf83d1a2ez3s4nvq type wireguard   # 28 chars -> rejected
ip link add dev wgtest                       type wireguard   # short name -> OK
```

The UCI is written correctly; `network_interface.device` exists but the
wireguard proto ignores it, so there is no way to give the netdev a short name.

**Why it is the worst kind of bug:** it is a *silent* failure. The write
succeeds, the config looks right in LuCI, and the breakage only appears in
`logread`. A user has no signal from the API that the tunnel can never work.

**The general principle:** wherever an OpenWrt proto/type derives a *kernel
object name* from the UCI section name (rather than from a dedicated name field
like `network_device.name` or `firewall_zone.name`), uapi's ULID section naming
breaks it. WireGuard is the concrete case today; the same trap exists for any
future type with the same naming behavior.

**Fix options (the maintainer's call; I recommend 1, with 3 as the floor):**

1. **Allow a caller-supplied short section name (<=15 chars) for `proto
   wireguard` interfaces**, used as both the uapi `id` and the kernel ifname.
   This breaks the "every id is a ULID" invariant for this one proto, but for
   wireguard the section name *is* the device name, so there is no way around it.
   Most surgical and it makes the resource actually usable.
2. Introduce a wireguard `network_device` (short `name`) + bind the interface to
   it, if netifd supports a wg device + ifname indirection. (I do not think
   OpenWrt's wireguard proto has that indirection, so this may not be viable.)
3. **At minimum, fail loudly at write time:** if a `proto wireguard` interface
   would get a section name >15 chars, reject the write with a clear
   `validation_failed`/`conflict` pointing at `IFNAMSIZ`, instead of committing
   UCI that can never come up. This is the floor regardless of 1/2, because
   silent non-functional success is the real harm.

This generalizes the "success != converged" theme from the rc-era feedback:
here a 2xx is "the UCI committed," not "the interface can exist." A write-time
length check closes the gap deterministically.

## H1 [HIGH] `423 global lock` on per-resource creates under default parallelism

With Terraform's default parallelism of 10, ~10 concurrent creates of the *same*
resource type fail:

```
Error: Error creating dhcp host
  uapi 423 locked: Another write transaction holds the global lock
```

The provider already retries 423/429 with backoff; raising/time-bounding that
budget is the provider-side lever and I will handle it there. The **uapi-side
question** is the message and the granularity: this is `dhcp/hosts`, which I
understood to take the **per-package** lock, yet the error says "global lock."
Two things to check:

- Is `dhcp/hosts` (and other curated collections) actually serializing on the
  *global* lock rather than the per-package one? If so, 10 same-package creates
  contend a single global lock and the parallelism is fully wasted.
- If it is genuinely per-package, the error string "global lock" is misleading
  and worth correcting (it sent the field debugging down the wrong path).

Either way, a note in the docs that the global serialization makes Terraform
parallelism counterproductive (recommend `-parallelism=1`) would help; that part
I will add provider-side.

## H2 [HIGH] Adoption has no inverse (no release / un-adopt), so destroy can't restore

`POST .../adopt` (managed false -> true) is one-directional. The field run found
that `terraform destroy` of adopted resources leaves the box worse than found:
adopted singletons keep the user's mutated values, adopted collection sections
get deleted outright, and a **pre-existing `unbound-daemon` package got
uninstalled**. "Adopt on create" sets the expectation of "release on destroy,"
but there is no operation that means "stop managing this, leave it as it was."

**Most of this is mine to fix on the provider side** and I will: snapshot the
pre-adoption section at create and PATCH it back on destroy; record whether a
package was already installed and skip uninstall if it was. But two things would
be cleaner (or are only possible) with uapi help:

1. **A release / un-adopt operation** symmetric with adopt: flip a section's
   `managed` back to `false` and leave its values intact, without deleting it.
   Today destroying an adopted *collection* section can only delete it (destroying
   something that pre-existed) or leave it managed-and-mutated. A release
   primitive lets a client "stop managing, leave as-is," which is the correct
   teardown for anything that pre-existed adoption.
2. **Help capture pre-adoption state**: either return the pre-adopt section
   snapshot in the adopt response, or document that the client must GET-before-
   adopt to capture it. (The provider can do the GET-before-adopt itself; this is
   only about whether uapi wants to make it first-class.)

**Recommendation:** at minimum add the **release/un-adopt** endpoint. It is
small, exactly symmetric with adopt, and it is the missing primitive that lets
every downstream tool implement correct "release on destroy." The snapshot and
restore on top of it are then purely a provider concern.

## M2 [MEDIUM] `unbound_server` has no listen-address / bind option

To run unbound as a loopback-only recursive backend (`127.0.0.1@5353`, behind
dnsmasq), there is no curated field to set unbound's `interface:`/bind. The only
escape hatch is `manual_conf`, which is all-or-nothing. The field user had to add
`interface: 127.0.0.1@5353` to `/etc/unbound/unbound_srv.conf` out of band, which
defeats managing unbound through uapi.

**Suggestion:** add a `listen_interface` (list) / `bind` field to the
`unbound/server` schema, or a narrower "extra `server:` lines" escape hatch that
is not all-or-nothing like `manual_conf`. The dnsmasq+unbound split is a common
and validated pattern (see the positives above), so the loopback-bind case is
worth making first-class.

## Minor: the package-install contract

It was unclear whether `unbound_server` / `sqm_queue` / `snmpd_*` require the
underlying package installed first. uapi does the right thing at runtime (returns
`503 init_script_missing` when the daemon is absent), but the contract is not
documented. Either document "install the package before configuring" plainly, or
consider whether a config write for an absent daemon should be a clearer,
earlier error. (The provider can also document `depends_on = [uapi_package...]`;
that part is on me.)

## Summary for triage

- **C1** is the blocker for a major OpenWrt use case (WireGuard) and is purely
  uapi-side. Even if a full naming fix waits, ship the write-time length check
  (option 3) so it stops failing silently.
- **H1** is mostly a provider retry-budget fix (mine), but please confirm whether
  curated collection creates take the global or per-package lock, and fix the
  message if it is the latter.
- **H2** is mostly a provider fix (snapshot/restore on destroy, package
  install-ownership), but the one uapi-side enabler is a **release/un-adopt**
  endpoint, the missing inverse of adopt.
- **M2** is a clean, well-motivated schema addition.

Everything else from the field report (minimal doc examples, nested-`match`
worked examples, SQM units, SNMP RO example, OpenTofu-registry publish) is
provider/docs/publishing and I am handling it on the provider side.
