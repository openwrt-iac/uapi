# Security policy

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: **[Report a vulnerability](https://github.com/openwrt-iac/uapi/security/advisories/new)**.

That opens a private advisory only the maintainers can see, and it is the right channel even
if you are not sure the finding qualifies. Please do not open a public issue for anything that
looks exploitable: uapi runs as root on other people's routers, and a public reproduction is
usable before a fix exists.

Expect an acknowledgement within a few days. This is a small project, so that is a realistic
figure rather than an SLA. If a report goes unanswered for a week, feel free to nudge it.

## What counts as a vulnerability here

uapi does privileged things by design. It runs as root, and a token scoped `*:rw` can
reconfigure the router, install packages and set the root password. That is the product
working, not a flaw, so "a full-access token can break my router" is not a finding.

The useful test is whether a finding **crosses a boundary the API claims to hold**:

- **A scope boundary.** A token reaching an effect outside the scopes it holds. A feed-management
  token that ends up able to install arbitrary packages is a vulnerability; the same token
  changing a feed is not.
- **An authentication boundary.** Anything reaching a privileged path without a valid token, or
  with an expired, revoked or CIDR-excluded one.
- **A disclosure boundary.** Material the API deliberately masks becoming readable by another
  route. Token salts and hashes, cleartext passwords, private keys and certificate material are
  all masked on the curated endpoints, and any path returning them is a finding.
- **Integrity of the write path.** A write that lands somewhere other than where it was aimed:
  injection into a config file, a section written outside the requested package, or a
  transaction leaving partial state behind.

Denial of service against a router you already administer is generally not interesting. A way
to make uapi refuse service to *other* callers, or to exhaust a shared resource from a
read-only scope, is.

## Out of scope

Decisions already recorded rather than defects, with the reasoning in
[`docs/security.md`](docs/security.md):

- The authentication design, including why rpcd sessions are not used. See
  *Authentication-design exclusions*.
- The TLS posture, including plain HTTP being allowed from localhost. See *TLS posture*.
- The rate limiter's stated non-guarantees. See *Rate limit guarantees (and non-guarantees)*.

Disagreeing with one of those is welcome as a normal issue. It is a design discussion, not a
disclosure.

## Supported versions

uapi serves exactly one API major per installation, so operators pinned to an older major stay
on its last release rather than upgrading.

| Version | Supported |
|---|---|
| Current major, latest minor | Security and functional fixes |
| Previous major, last release | Security fixes for 6 months after the current major went stable |
| Anything older | Not supported |

A security fix for the previous major ships as a patch on its own line.
