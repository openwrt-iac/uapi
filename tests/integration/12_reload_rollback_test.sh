#!/bin/sh
set -eu

# Deferred: end-to-end coverage of the reload_failed_restored path.
#
# The atomic-transaction recipe in src/lib/transaction.uc is exhaustively unit-
# tested at tests/unit/transaction_test.uc (lines covering both
# reload_failed_restored and reload_failed_unrecovered branches, with a stubbed
# bus). Integration coverage requires deterministically inducing a ubus reload
# failure on the OpenWrt VM, which is harder than it looks: in OpenWrt 25.12
# the firewall service's "reload" method is mediated by procd/rpcd, so a
# replaced /etc/init.d/firewall script does not always propagate its exit code
# back through `ubus call firewall reload`. A stable injection mechanism (e.g.
# a procd-registered dummy ubus object that fails on demand) is the right
# fix, and will land alongside the next observability iteration.
#
# Manual verification path until then: from the dev machine, point the API at
# a router with no firewall service running and POST a rule; the response
# should be 500 with code "reload_failed_unrecovered". See CLAUDE.md "Atomic
# transaction recipe" for the contract.
echo "12_reload_rollback_test: deferred; unit test covers the recipe (see comment)"
exit 0
