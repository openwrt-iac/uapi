---
name: Bug report
about: Something uapi does that it should not, or does not do that it should
---

<!--
Terse is fine. The four prompts below are what usually make a report reproducible
on the first pass. Skip any that genuinely do not apply.
-->

**What happened, and what you expected instead.**

**The exact request and response.** Method, path, request body, status code, and the
error body if there was one.

**Versions.** uapi (`apk info uapi`), the OpenWrt release, and the device.

**What the device shows.** The relevant `uci show <package>`, and where the config is
meant to reach a daemon, what that daemon actually did: `wg show`, `nft list ruleset`,
`ip route`, `ip rule`, `logread`. A write answering `200` does not always mean the
state was applied, so this is often the part that identifies the bug.
