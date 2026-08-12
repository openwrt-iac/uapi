# Testing

Three layers, plus the harness and the load-bearing test inventory.

## Layers

- **Unit tests** (pure ucode): schema validation, `fromUci`/`toUci`, scope matcher, ID generation, error envelope, transaction snapshot logic. Runs anywhere ucode runs. Sub-5s end-to-end.
- **Integration tests** (QEMU + official OpenWrt VM image): full transaction recipe against real ubus/uci, auth on the wire, audit log emission, snapshot-restore. ~1-2 min including boot.
- **Contract / Terraform provider tests**: handled by `openwrt-iac/terraform-provider-uapi` against a running uapi. Seeded by the in-repo curl example suite (`examples/curl/`) and the emitted OpenAPI spec.

## ucode test harness

Thin homegrown harness (`tests/harness.uc`, ~110 lines): `describe` / `it` / `assert_equal` / `assert_true` / `assert_throws`, plain text output, exit code 1 on any failure.

## Injectable ubus surface

All ubus/uci calls route through a single injectable surface (`src/lib/bus.uc`). In production it's the real `ubus.connect()` / `uci.cursor()`; in unit tests it's a stub returning canned responses. This is the difference between covering 30% and covering the transaction recipe's failure paths (specifically the snapshot-restore rollback, which is hard to trigger naturally).

## Load-bearing integration tests

Every regression in this list has cost a real debug round-trip at some point. Keep them green; if one starts failing, that is the prompt to stop and investigate before pushing.

1. **Concurrency model confirmation.** `tests/integration/01_concurrency_model_test.sh` claims "5 concurrent requests fork; at least 2 distinct PIDs, uhttpd caps CGI children at 3", and asserts `count == 1` on every response. The claim string is printed by the test beside the assertion and is checked by `lint-doc-refs`, so this description cannot drift from what the test does: it said "5 distinct PIDs" for several releases while the test asserted 2.
2. **Happy-path write.** PUT → 200 → GET reflects new state → audit log line in syslog.
3. **Validation failure.** Bad payload → 422 with field errors → no uci change.
4. **Reload failure rollback.** Construct a config uci accepts but the daemon rejects → 500 `reload_failed_restored` → uci back to prior state.
5. **Auth paths.** Missing/bad token → 401. Insufficient scope → 403. Plain HTTP from remote → 403 `tls_required`.
6. **Adoption flow.** Pre-existing anonymous section → `managed: false` → PUT denied with `unmanaged_resource` → `POST .../adopt` → writable.
7. **APK install smoke test.** Fresh OpenWrt 25.12 → `apk add uapi` → the uci-defaults hook wires uhttpd → curl works.
8. **Stock-config compatibility round-trip** (`tests/integration/44_stock_config_test.sh`, 2.3.0+). For every curated CRUD resource whose package ships in the bare OpenWrt image: `GET` the section, adopt it if `managed: false`, `PUT` the body back verbatim, then `GET` again and diff the persistable shape. Singletons follow the same pattern with `PATCH` instead of `PUT` (singletons don't expose PUT, per `handler.make_singleton`). A 422 or a diff surfaces a regression where uapi rejects (or silently mutates) what OpenWrt itself ships. Catches the validation-stricter-than-the-platform class. Scope is every curated resource whose package is on the box: the bare-image ones (firewall, network, dhcp, dropbear, system) plus lldpd and vnstat, which `install_uapi` installs at bootstrap. The families still outside the image are listed under "Which resources a daemon has to be installed to test" below. No test numbered after this one may depend on pristine stock config, because PUT-self cumulatively rewrites the VM's `/etc/config/*` (`toUci` drops options not in `schema_properties`) and a later test reading a stock value would see drift.

9. **Read-honesty round-trip** (`tests/integration/47_read_honesty_test.sh`, 2.5.0+). The resources layer 8 cannot reach (wireguard interface and peer, wireless, plus the `ipaddr` / `ipaddrs` pair), round-tripped both verbatim and with one field changed, with the masked credential read back out of uci and the address list checked on the netdev. See the section below for why each part is there.

## The no-partial-state property

`tests/unit/no_partial_state_test.uc` (2.5.0+) is the first architectural principle stated as a test: a write that fails leaves uci exactly as it found it. It runs over the same 45 fixtures as the read-honesty property, injecting the failure at reload, the one point where uci has already been committed and the daemon then refuses. That is the case the restore path exists for and the only one where a partial state can survive a request.

Before this, "no partial-failure states, no config drift" was asserted in ten documentation files and covered by one unit test on the transaction module. Never per resource, which is where it can actually go wrong: the transaction restores a snapshot, but whether a given resource's write falls entirely inside that snapshot depends on the resource.

Two things the injection had to get right, both learned by getting them wrong:

- **Only the first reload fails.** The restore path reloads too, so a stub that fails every call produces `reload_failed_unrecovered` and exercises the wrong branch. The case worth covering is a daemon that refuses the new config and accepts the restored one.
- **The test asserts the write actually failed** before comparing state. A `200` would mean the injected error never reached the transaction, and the comparison would then pass for the wrong reason.

Validated by neutering the restore (`conn.uci_import` in `transaction.uc`): 5 of the 45 cases fail with the before-and-after uci printed. The other 40 write back the body they just read, so uci ends where it started whether or not the restore ran. The 5 that fail are the writes that do not store what they read verbatim: `dhcp/hosts.tag` and `snmpd/agents.agentaddress` turn a scalar into a list, `unbound/server` and `lldpd/config` move the value onto the uci key their daemon actually reads, and `network/interfaces` writes back a field the seed left absent.

Not covered: a crash between commit and reload. Nothing in-process can restore after that, `docs/architecture.md` says so, and it is the reason commit-confirmed apply was designed at all.

## The read-honesty property

Principle 4 as a test: read a section, write the body back, read again, and nothing may change or be rejected. Two layers state it, `tests/unit/read_honesty_test.uc` and `tests/integration/47_read_honesty_test.sh` (both 2.5.0+). Each runs in two forms, because the forms catch different defects.

- **Body written back verbatim.** Catches a read the write path cannot reproduce. This is how 2.4.0 destroyed write-only credentials: the read masks them, so the body a client echoes cannot carry them, and the write dropped what it could not see.
- **One field changed first, the rest left as read.** Catches a read whose fields are not independently writable, which the verbatim form structurally cannot see. This is how the `ipaddr` / `ipaddrs` pair became unwritable in 2.4.1: unmodified, the scalar agrees with the list, so the contradiction only appears once the list moves and the previously-read scalar travels beside it. It is also the shape of every real apply.

Both forms were validated by re-introducing the bug they claim to catch, at both layers, and each catches only its own. Neutering `carry_write_only` fails four unit cases on the verbatim form and exits the integration test non-zero; neutering `resolve_for_replace` failed one case, and only on the modified form. That second measurement was taken against 2.x, and 3.0.0 deleted the seam it neutered along with the mirrored pair that needed it, so it cannot be repeated as written. The form stays because the class outlives the instance: any read whose fields are not independently writable produces the same signature, and only the modified form perturbs one field at a time to expose it.

Every writable resource carries a case: a companion test walks `src/resources/` and fails naming any module with a `validate()` that has none. There is no exempt category. The first version demanded cases only from modules with a masked field or a merge hook, four of forty-three, which would not have demanded `dhcp/hosts` and so would not have caught the `tag` bug that shipped in the same release as the property itself.

A second companion test enforces something the first version got wrong: **no case may seed a field at the value `fromUci` would synthesize for it.** If a seed uses the default, dropping that field from `toUci` is invisible, because the re-read fills the default back in and before matches after. Measured rather than assumed: deleting `out.forward` from `firewall.zones` went unnoticed while the seed said `REJECT`, the documented default, and was caught immediately once the seed said `DROP`. The check found seven more cases seeding booleans at their defaults that a hand audit had missed.

What the integration layer adds is the part a stub bus cannot reach. It reads the secret back out of uci, which matters because the view masks credentials: a write that replaced one with a different non-empty value satisfies any view-level comparison, and only the stored bytes disprove it. It also confirms the modified address list reached the netdev rather than only uci. Both were measured with the bug present: `preshared_key` was emptied in uci while the response stayed 200.

Relationship to the stock-config round-trip (layer 8 above): 44 covers many more resources against genuinely stock configuration, but it PUTs verbatim only and its scope is bare-image packages, excluding wireless outright. Neither the secret-destruction nor the mirror-field class is reachable from it, because both live in wireguard, wireless and openvpn. 47 is the narrow complement: four resources, both forms, plus the uci and netdev checks.

Test 47 deletes the wireguard netdev in cleanup, not just the uci section. A wireguard netdev that outlives its config takes only part of it back on the next `ifup`: a re-run saw the v6 addresses return without the v4 one, which would have made the kernel assertion grade leftover state instead of the write under test.

No layer here can see a uci option no resource models at all. PUT deliberately drops unmodelled options, so a view-level comparison cannot detect the loss; that is a curation-completeness question, and layer 8 is what answers it.

## Every gate ships with a demonstrated failure

`make gate-selftest` breaks each gate on purpose and asserts it says so. Thirty-four probes across ten gates: the eight `lint` sub-targets, `openapi-check` and `coverage`, with each distinct rejection shape probed separately (fifteen for `lint-openapi-shape`, seven for `lint-doc-refs`, three for `lint-defaults`, two each for `lint-reserved` and `coverage`).

It exists because `lint-emdash` shipped for several releases without ever running in CI. It lists tracked files with `git ls-files`, the CI container installed no `git`, and `|| true` turned the failure into a pass, so it reported success without reading a file. From the outside a green check and a working check look identical: "the gate runs" and "the gate works" are different claims, and only a planted defect separates them.

Each rejection shape the bullets below describe has its own probe, so the list of what a gate catches is executable rather than prose that can drift from it: `lint-openapi-shape` documented four shapes while only one was probed, which is how prose and behaviour separate. If you add a shape to a gate, add its probe, and if the two disagree the self-test says so.

Adding a gate means adding a probe. The completeness check derives the gate list from the Makefile's `lint:` chain rather than a hand-kept copy, so a new gate with no probe fails the self-test instead of passing quietly. That was verified by adding a gate with no probe and watching it fail.

Three properties worth knowing before editing it:

- **Probes run in a throwaway git worktree**, so a mutation can never reach the tree you are working in, and an interrupted run cannot leave your checkout dirty.
- **The worktree mirrors your working tree, not `HEAD`.** Uncommitted changes are carried across and committed as a throwaway baseline inside the worktree. Without that, a gate and its probe arriving in one commit could not be validated until after committing, and the reset between probes would revert them.
- **A probe that changes nothing is reported as a broken probe**, not as a blind gate. The two are indistinguishable from an exit code alone, and telling them apart is the whole point. Each probe also asserts a fragment of the expected message, so a gate failing for an unrelated reason does not read as a pass.

It found a real hole on its first complete run: `coverage`'s dead-export gate could never fire. `used_internally` scanned for the export's name as a token, and the module's own export block names every export, so every export counted as used and the `exit_code = 1` on dead exports was unreachable. Excluding the export block from that scan fixed it, verified in both directions: a planted dead export is now reported, and all 135 real exports still pass.

## Lint suite

`make lint` chains these sub-targets:

- `lint-emdash`: forbids em-dashes in tracked sources (CLAUDE.md style rule, enforced).
- `lint-syntax`: `ucode -c` on every `.uc` file in `src/`, `cli/`, `tests/`.
- `lint-reserved`: fails on schema property names that collide with Terraform meta-arguments or HCL block keywords.
- `lint-refs`: walks every `$ref` under `#/components/` in `build/openapi.json` and fails on dangling targets.
- `lint-openapi-shape` (2.4.0+): structural checks over `build/openapi.json` that a conformance validator does not make, because the shapes are legal JSON Schema and merely useless to a generator: a schema `required` naming a property the schema does not declare, an `if` with no `then` or `else` (and the reverse), an empty or non-array `enum`, and any value that is the string `"NaN"`. The NaN one exists because ucode's `+` on two arrays yields NaN rather than concatenating, which is how an `enum` of `"NaN"` reached the published spec. It also checks that emitted response headers are declared on the responses that can carry them and nowhere else: the four transaction headers (`X-Reload-Status`, `X-Reload-Services`, `X-Kernel-Status`, `X-Kernel-Applied`) appear as a complete set on every curated-resource write and on the `POST /batch` 207, which commits and reloads once for the whole set and reports them aggregated, and on nothing else, `ETag` appears on exactly the curated CRUD and singleton reads and writes that call `set_etag_header` (which excludes the collection-kind lease views, curated but bare), and `X-Mgmt-Path-Warning` appears on exactly the collection POST 200 and the item PUT 200, PATCH 200 and DELETE 204 of each resource whose module sets `mgmt_path_guard` (the create arm is there because a new section can claim the management device). The curated path set is derived from the generator's own `ENDPOINTS` catalog and the guarded set from `src/resources/`, so neither is kept by hand and a new resource is covered the day it is added. The reverse error is the one that motivated them: three headers were emitted and declared nowhere at all, which a generated client cannot see. It also requires every `deprecated: true` property to carry a description opening with `Deprecated`: the flag tells codegen a field is going away, and only the text tells an operator why, which is what a provider prints in a plan warning. Eight fields shipped the flag with no reason attached. The match is case-insensitive because `network/interfaces.name` predated the convention and opened `DEPRECATED in 2.2.0`; 3.0.0 removed every deprecated property, so the rule currently guards the next one rather than an existing field.
- `lint-doc-refs` (2.5.0+): walks `docs/*.md`, `CLAUDE.md`, `README.md`, `CONTRIBUTING.md` and `.github/workflows/ci.yml`, and fails on a reference that does not resolve: a repo path that is not there, a `module.export` a module does not export, a backticked `make <target>` the Makefile does not define, a `claims "..."` string no test prints, an active `docs/deprecations.md` row the spec's own description does not announce, and an error code documented as returned that nothing in `src/` emits (plus the reverse, a published enum code absent from `docs/errors.md`). Waivers live in `tests/lint_doc_refs.uc::WAIVERS`, keyed by the reference with the reason as the value, because some references are deliberately unresolvable: `bench/baseline.json` is cited precisely because it does not exist. What it does not catch is stated in its own header and is the larger half: "this job proves X" where the job exists and does something adjacent, and modal invariants like `never` or `atomic`. Both of those shapes shipped false claims that had to be caught by reading.
- `lint-wire-names` (2.5.0+): every API field whose name is not the uci option it writes has to be accounted for, with the reason as the value. Two shapes hide here and only one is harmless. A **rename** is one API name for one uci key spelled to the wire's conventions (`resource_limits` for uci's `resource`, `sys_location` for `sysLocation`), and stays. An **alias** is two API names for the same key, which is what a major removes: it makes a round-trip ambiguous, forces a merge hook to decide which name the caller meant, and cannot be expressed once request and response schemas split. 3.0.0 removed all three aliases that existed when this lint was written, so it currently guards an empty set. That is the point: it exists so a fourth cannot arrive unnoticed and force the next major to repeat the removal.
- `lint-defaults` (2.2.2+): for every `fromUci` unconditional default, verifies a matching `default:` annotation in `schema_properties`; for every `x-uapi-clear-on-omit` flag, verifies the fromUci shape is `section.X ?? null` and the schema type includes `"null"`.
- `50_response_conformance_test.sh` (3.0.0+): validates live response bodies against their published 200 schemas, and asserts the served `openapi.json` matches the tree's. The document-only gates cannot see an `allOf` whose branches are each valid but whose composition nothing can satisfy; that shape shipped twice, in `TokenMetadata` and in the `wireless/interfaces` `key` conditional.

### Asserting that a write reached the daemon

A 200 and a successful read-back prove only that uci accepted the write. Both were true of the redirect bug that made every uapi-created port forward silently vanish. Where a daemon compiles uci into something else, the integration library asserts against that compiled form instead:

- `assert_fw4_emits` / `assert_fw4_omits` / `assert_fw4_loads` check what firewall4 renders from uci and that `nft -c` accepts the whole ruleset. Rendering is used rather than the applied table because CI stubs `/etc/init.d/firewall`, and because `nft -f` is atomic, so one bad token rejects every rule while `firewall reload` still exits 0.
- `assert_dnsmasq_emits` / `assert_dnsmasq_omits` / `assert_dnsmasq_loads` check `/var/etc/dnsmasq.conf.<id>`, which dnsmasq compiles from `/etc/config/dhcp` on reload, and run `dnsmasq --test` over it. `--test` is the counterpart to `nft -c`: it reports a bad option or a bad value without disturbing the running server.

There is deliberately **no equivalent for network**. netifd reports a status object for an interface whose proto it does not recognise (silently falling back to `none`) and for one whose device does not exist, so "netifd knows about it" passes for broken configuration and would be a tautological assertion. `available: false` is not a usable signal either, since it is also false for a perfectly valid interface that has no device to bind to. A meaningful check would need a test interface bound to a real device, which the suite does not currently create.

### The dead-field audit

`scripts/audit-dead-fields.sh root@<device>` checks every uci option a resource writes against the thing that reads it, and fails on any that nothing reads. A field nothing reads accepts a write, answers 200, and changes nothing on the device, which no status code distinguishes from a working one. It needs a device rather than CI, because the readers are what it greps: firewall4 is ucode, the init scripts are shell, and a uci option name a C daemon looks up is a literal in its string table. Several of those packages ship only a Makefile in the SDK feed, so a running box is the only place they can be read at all.

**The corpus is the part that goes wrong, and it fails in the direction of looking productive.** An empty or partial corpus reports live options as dead, which is indistinguishable from a real finding. Three corpora were wrong on the first pass: the firewall4 entry was misnamed and produced 63 false positives including `src` and `target`, openvpn's option table turned out to live in `/usr/share/openvpn/openvpn.options` rather than the init, and `unbound_srv` / `unbound_ext` are read by a separate package entirely. So the script self-checks first, with two probes per package rather than one, and refuses to report a result if any probe cannot find an option that is unmistakably live. One probe was not enough: `openvpn/client` passed against a corpus that could not see a single openvpn option, because the init declares a shell local of that name.

Known-accounted entries live in the script beside the corpus, each with its reason: announced for removal, a deliberate decision such as `system.notes` which LuCI reads, or an artifact of reading option names out of the source such as a legacy key that is cleared on write. Anything else is a new finding and fails the run.

Validated in both directions: adding an option nothing reads is reported as new, and blinding one package's corpus fails the run instead of reporting that package's options as dead.

**Two categories were attempted mechanically and rejected, which is worth recording so nobody rebuilds them.** Checking whether a daemon ever iterates the uci **section type** a resource models would have caught `vnstat/interfaces`, but it reports 13 false positives for every true one: netifd, odhcpd and mwan3 parse uci in C, so their iteration is invisible to the `config_foreach` idiom the check keys on, and wireguard peers use per-interface section names that never appear as a literal. Checking whether a **boolean-typed** field is read as free text (the `lldp_description` shape) conflates two different things: a reader taking the value with `config_get` and comparing it to `1` is the ordinary raw-compare class, not a type error. Of its seven candidates, `unbound_srv.ip_transparent` turned out to accept exactly what the field's helper emits and says so in a comment. Both remain human review.

### Which resources a daemon has to be installed to test

A resource whose package is not on the box answers 503 `init_script_missing`, which is correct behaviour and also indistinguishable from a correct model: nothing exercises the resource, so a section-type mismatch looks exactly like a working one. That is how `vnstat/interfaces` shipped modelling `config interface` sections vnstat has never read.

`install_uapi` installs lldpd and vnstat2 at bootstrap (about 560 KiB together), so `lldpd/config` and `vnstat/config` are exercised by `49_daemon_gated_resources_test.sh` and included in the stock-config round-trip. `40_unbound_uci_ext_test.sh` installs unbound itself, so `unbound/*` is covered only while that test runs.

Six resource families remain uncovered because their packages stay outside the image: `snmpd/*`, `mwan3/*`, `sqm/queues`, `usteer/config`, `prometheus_node_exporter_lua/config` and `openvpn/*`. That is a standing gap rather than a decision that they cannot be tested, and the prometheus one matters least because most of its surface is now deprecated. Anything asserting what those daemons do has to be run by hand on a real device.

`make openapi-validate` (2.4.0+) runs a real OpenAPI 3.1 conformance validator over the emitted document. It is deliberately **not** part of `make lint`, which stays dependency-free; it needs `python3` and `openapi-spec-validator`, and CI runs it as its own step so the gate is enforced without every local `make lint` requiring a pip install. It fails rather than skips when the validator is absent, since a check that quietly passes is worse than no check. The two gates are complementary and were measured to be so: the conformance run catches type and keyword violations anywhere in the document, and misses the two semantic cases above, which are valid JSON Schema.

## CI shape

- Every commit/PR: unit suite + lint.
- Every PR + push to main: unit + integration suite (QEMU).
- Release tag: + multi-arch verify-build (cross-compile sanity) + release-apk job (publishes the GitHub Release with CHANGELOG-extracted notes).

## OpenAPI emission

Generated at build time (`make openapi`) from the inline `schema_properties` blocks in each resource module. Shipped as `/usr/share/uapi/openapi.json` and surfaced at `/api/v3/openapi.json`. The spec is the contract document and the input for openapi-codegen consumers (the Terraform provider in particular).

`make openapi-check` regenerates the spec into a temp file and diffs against the committed `build/openapi.json`. CI runs this as a sanity gate; if it fails, the committed spec is out of sync with the resource modules and one of them has to give.

## Curl example suite

In-repo at `examples/curl/`, sixteen files covering a subset of the curated resources rather than all of them, one per distinct shape: plain collections, a singleton, an adopt flow, a masked credential, a non-uci resource and the raw passthrough. Doubles as documentation and seed for provider contract tests. `adopt.sh` was added in 2.5.0 after an audit found the flow every operator meets on pre-existing config had no runnable example at all.

## Coverage gates

`make coverage` reports:

- Module coverage: every `.uc` file under `src/lib/` and `src/resources/` exercised by at least one unit test. Target: 100% (every module covered, even shallowly).
- Direct-call coverage: every exported function from `src/lib/` invoked by name in at least one unit test. Threshold: 80%. Functions reached only through production code paths count toward "total covered" but not "directly tested."

The thresholds are guardrails, not strict; if coverage drops below them, the CI step fails and the responsible commit has to add a missing test or justify the gap.
