# Commit-confirmed apply (deferred design)

**Status: DEFERRED, with the authz model now settled.** Not shipped in 2.3.0,
2.4.0 or 2.4.1. The full per-write implementation was built, shipped in the
2.3.0-rc1 pre-release, soaked on live hardware, and then removed before stable;
it is recoverable from commit `a85a5cd`. This file is the design and decision
record, not a description of shipped behavior.

Of the two gates that held it back, one is closed and one is not. The authz
model is decided below, so the feature can now be scoped into a minor without
risking a contract that a later correction would turn into a major. What is
still missing is a first-party consumer: nothing exercises the surface, and
shipping a frozen v2 contract that nothing uses is the reason it came out of
2.3.0 in the first place. No target release until a wrapper is actually being
written. (`apply-confirm` 0.1.0 is released and on the apk feed, so
availability was never the blocker.)

## Why it was deferred from 2.3.0

uapi writes are atomic per request (stage, validate, commit, reload, with
in-band rollback if the reload command fails). What that does not cover is a
change that reloads cleanly yet severs the operator's only management path
(the classic firewall/network lockout). Commit-confirmed apply closes that
gap: snapshot the affected uci packages, arm a deadline, and auto-restore if
no ack arrives. The mechanism works (validated end to end on real hardware).
It was deferred for contract-commitment reasons, not because it is broken:

- **No first-party consumer.** The Terraform provider ships 2.3.0 without
  consuming confirm. Shipping the surface stable would freeze a permanent v2
  contract that nothing exercises.
- **Unsettled authz (the deciding factor at the time).** Freezing rc1's authz
  into v2 would have cost a major bump to correct. Now settled: see "Authz
  model (decided)" below, which departs from rc1 on both arming and ack.

(The dependency is not a factor: `apply-confirm` 0.1.0 is released and on the
apk feed. The hold is the wire-contract commitment, not availability.)

## Architecture (the chosen shape)

A separate package, `apply-confirm` (procd-supervised, durable state under
`/var/lib`), owns the rollback timer and the uci-package snapshots. uapi
gains no daemon of its own; it integrates by invoking the `apply-confirm`
CLI (`stage` / `ack` / `rollback` / `status` / `list`). The snapshot is a
per-uci-package `uci export`; rollback is `uci import` + commit + a service
reload. A single box-global pending window is enforced by an exclusive flock
(`stage` refuses with `already_armed` if one is already armed).

## Wire surface (as built in rc1, the per-write half)

- A write carries `?confirm=<seconds>` (1..3600). uapi snapshots the
  affected packages, commits, reloads, and returns `202 Accepted` with a
  `ConfirmWindow {token, timeout, deadline, packages}` body plus
  `X-Confirm-Token` / `X-Confirm-Deadline` headers. The header form
  `X-Uapi-Confirm` also works behind a proxy that forwards it, but uhttpd's
  CGI strips custom headers, so the query form is the portable interface.
- `GET /confirm` (list), `GET /confirm/<token>` (status), `POST
  /confirm/<token>` (ack), `DELETE /confirm/<token>` (roll back now).
- Scope `uapi:confirm` (`:ro` for status/list, `:rw` for ack/rollback). Arming
  needed no extra scope. **Superseded**: this is the model the authz section
  below rejects, recorded here because it is what commit `a85a5cd` contains and
  a reader recovering that code needs to know it has to change.
- Optional and feature-detected: `501 confirm_unavailable` when
  `apply-confirm` is not installed.

**The ack is client-driven; uapi never auto-acks.** The client confirms only
after verifying the management path still works. A network blip that hides
the `202` also prevents the ack, so the auto-revert and the client's view of
its own apply stay consistent (this is what resolves the original
state-divergence objection that killed the v1-era design).

## The missing half: a standalone arm

The per-write form cannot wrap a whole `terraform apply`: a DAG apply is N
isolated RPCs with no apply-level hook, and each `?confirm` mints a separate
last-writer-wins window. The Terraform-useful shape is `apply-confirm`'s
`stage` primitive exposed over HTTP so a wrapper can arm once, run the apply,
then ack once. Locked design (see `docs/roadmap.md`):

- New `POST /confirm` (the bare-collection slot, today a 405). Originally
  scoped for 2.4.0, which passed without it.
- Body names curated **resources/scopes, never raw packages**; uapi derives
  the package set and reload-service union from `RESOURCE_SOURCES` (the same
  fold `/batch` does).
- Returns the same `ConfirmWindow` 202 body; ack/rollback/status/list reuse
  the existing `/confirm` endpoints unchanged.

## Authz model (decided)

**One rule, for every operation that can move state: the token's authority has
to match the revert's blast radius.**

Arming a window, whether by `?confirm=<seconds>` on a write or by
`POST /confirm`, requires `uapi:confirm:rw` **and** `:rw` on every curated
resource backed by every package in the derived set. ack and rollback require
the same. Status and list require only `uapi:confirm:ro`.

### Why arming cannot ride the write's own scope

`apply-confirm` reverts whole uci packages, and one package backs many resources
(`network` backs 7, `firewall` 5, `dhcp` 6). A token holding only
`network:routes:rw` could arm a window whose expiry restores the entire
`network` package to its arm-time snapshot, discarding a concurrent and properly
authorized write to `network:interfaces` that had already returned `200` and
committed.

That token cannot choose the replacement content, so this is not a write
primitive in disguise. It is still an unauthorized destruction of committed
state, and a silent one: nothing in the other client's `200` says its change was
revoked eight seconds later. Principle 4 settles it. Scope granularity has to
match the mechanism's granularity, and the mechanism's unit is the package.

**Not chosen:** making the revert section-granular so that per-write confirm
could keep riding the write's own scope. `uci import` replaces a whole package,
and a section-level restore can leave a package internally inconsistent, a rule
pointing at a zone that also moved. Package granularity is the honest unit for
what fw4 and netifd actually reload, so the authz moves to meet the mechanism
rather than the reverse.

**Accepted cost:** `?confirm` needs a broader token than the bare write it
guards, which is surprising until you know why. `network:*:rw` satisfies the
whole package, so an operator writes one scope rather than seven, and the `403`
names the resources whose `:rw` is missing rather than leaving them to guess
which of seven it was.

### Why ack and rollback are held to the same rule

`DELETE /confirm/<token>` destroys committed state in the window's packages.
That is the same act as a deadline revert, so it needs the same authority.

`POST /confirm/<token>` (ack) disarms the safety net and makes the change
permanent. Less destructive, but a token that could not have armed the window
should not be the one deciding the box is healthy. Holding both to the arming
rule also means the wrapper that arms is the wrapper that acks, which is the
only sequence this design intends.

**Rejected:** the window-agnostic ack that rc1 shipped, where any
`uapi:confirm:rw` token could ack or roll back a window covering packages it has
no access to at all. There is a single box-global window, so "any window" is
really "the window", which makes this both cheap to get wrong and cheap to fix
before anything depends on it.

### Why status and list are not scoped per resource

`GET /confirm` and `GET /confirm/<token>` return a token, a deadline and a
package list, never configured values, so there is nothing to filter the way
`/diagnostics?validate=1` has to filter findings. An operator needs to see that
a window is armed even when it guards packages they cannot write.

### Implementation note

Nothing new is required. The derived package set is the same fold over
`RESOURCE_SOURCES` that `/batch` already does, and the per-resource check is
`scope.permits(scopes, split(key, ":"), "rw")` across both registries, which is
what the `?validate=1` sweep does. The cost of this decision is a loop, not a
mechanism.

### What this closes

Deciding it now is the point: any of these settled differently after the surface
freezes would cost a major to correct. With the model recorded, the feature can
be scoped into whichever minor its consumer lands in.

## Operator wrapper guidance (for the eventual consumer)

The whole-apply wrap is operator-driven (a script around `terraform apply`),
owned by the provider repo. Two rules it must follow:

- **Mint the wrap token at package granularity** (the token is necessarily
  broader than the apply it guards), or a narrow token gets a 403 on arm.
- **Key ack-vs-rollback on management-path reachability, not the apply's
  exit code.** A partial failure where the box is still reachable should ack
  (Terraform already recorded the resources that succeeded, so acking keeps
  the box consistent with state); only an unreachable box should be left to
  auto-revert. `apply; if reachable then ack else let-expire`, never `if exit
  0 then ack`. Otherwise a forgotten ack reverts the whole armed package to
  its arm-time snapshot, silently undoing committed sibling-resource changes.
