# Commit-confirmed apply (deferred design)

**Status: DEFERRED. Not shipped in 2.3.0.** Targeted for a 2.4.0 minor once
the authz model below is settled and a concrete consumer wants it
(`apply-confirm` 0.1.0 is already released on the apk feed, so the
dependency is no longer a blocker). The full per-write implementation was
built, shipped in the
2.3.0-rc1 pre-release, soaked on live hardware, and then removed before
stable; it is recoverable from commit `a85a5cd`. This file is the design and
decision record for the eventual 2.4.0 work, not a description of shipped
behavior.

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
- **Unsettled authz (the deciding factor).** Freezing the current authz into
  v2 would cost a major bump to change later. See "Authz model to settle".

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
- Scope `uapi:confirm` (`:ro` for status/list, `:rw` for ack/rollback).
- Optional and feature-detected: `501 confirm_unavailable` when
  `apply-confirm` is not installed.

**The ack is client-driven; uapi never auto-acks.** The client confirms only
after verifying the management path still works. A network blip that hides
the `202` also prevents the ack, so the auto-revert and the client's view of
its own apply stay consistent (this is what resolves the original
state-divergence objection that killed the v1-era design).

## The missing half: a standalone arm (the 2.4.0 ask)

The per-write form cannot wrap a whole `terraform apply`: a DAG apply is N
isolated RPCs with no apply-level hook, and each `?confirm` mints a separate
last-writer-wins window. The Terraform-useful shape is `apply-confirm`'s
`stage` primitive exposed over HTTP so a wrapper can arm once, run the apply,
then ack once. Locked design (see `docs/roadmap.md`):

- New `POST /confirm` (the bare-collection slot, today a 405).
- Body names curated **resources/scopes, never raw packages**; uapi derives
  the package set and reload-service union from `RESOURCE_SOURCES` (the same
  fold `/batch` does).
- Returns the same `ConfirmWindow` 202 body; ack/rollback/status/list reuse
  the existing `/confirm` endpoints unchanged.

## Authz model to settle (the reason for one coherent 2.4.0 cut)

Ship per-write and standalone together so the authz is decided once:

- Per-write arming currently needs no extra scope; it rides the write's own
  resource `:rw`. But `apply-confirm` reverts the whole uci **package**,
  while uapi scopes are per **resource**, and one package backs many
  resources (`network` backs 7, `firewall` 5, `dhcp` 6). So a per-write arm
  with only `network:routes:rw` can cause a deadline revert of the whole
  `network` package, including `network:interfaces` the token cannot write.
- The standalone arm must therefore require `uapi:confirm:rw` **and** `:rw`
  on every curated resource backed by the *derived* package set
  (package-granularity authz).
- ack/rollback are window-agnostic today (a `uapi:confirm:rw` token can ack
  any window). Decide whether that should become window/package-scoped.

Any of these decided differently than rc1 shipped would be a breaking change
once frozen into v2. That is why the whole feature waits for one reviewed
authz model rather than shipping the per-write half now.

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
