#!/bin/sh
set -eu

# Checks every uci option a resource writes against the thing that actually reads it, and
# reports any that nothing reads. A field nothing reads accepts a write, returns 200, and
# changes nothing on the device, which a status code cannot distinguish from a working one.
#
# Removals only happen in a major and only after a window announced in an earlier minor, so
# a dead field found after that window closes waits for the major after next. That is why
# this runs before a major rather than after.
#
# Needs a device with the packages installed, since the readers are what it greps. The SDK
# feeds ship only a Makefile for several of them, which is why this reads a running box:
# firewall4 is ucode, sqm-scripts and the init scripts are shell, and a uci option name a C
# daemon looks up is a literal in its string table.

HOST="${1:-}"
[ -n "$HOST" ] || { echo "usage: $0 <root@device>"; exit 2; }
SSH="ssh -o ConnectTimeout=10 $HOST"

# Per-package corpus: every file that could consume the package's uci. Getting one of these
# wrong is the failure mode that matters, because an empty or partial corpus reports live
# options as dead and looks exactly like a real finding. Three did on the first pass: the
# firewall4 entry was misnamed and reported 63 false positives, openvpn's option table lives
# in /usr/share/openvpn/openvpn.options rather than the init, and unbound_srv/unbound_ext are
# read by a separate package. The self-checks below exist to catch the next one.
probe_script() {
	cat <<'SH'
corpus_for() {
  case "$1" in
    network)   echo "/sbin/netifd /lib/netifd /etc/init.d/network /sbin/ifup /lib/network /usr/sbin/odhcpd" ;;
    firewall)  echo "/usr/share/ucode/fw4.uc /usr/share/firewall4 /etc/init.d/firewall" ;;
    dhcp)      echo "/etc/init.d/dnsmasq /usr/sbin/dnsmasq /usr/sbin/odhcpd /etc/init.d/odhcpd" ;;
    dropbear)  echo "/etc/init.d/dropbear /usr/sbin/dropbear" ;;
    lldpd)     echo "/etc/init.d/lldpd /usr/sbin/lldpd /usr/sbin/lldpcli" ;;
    mwan3)     echo "/etc/init.d/mwan3 /usr/sbin/mwan3 /usr/sbin/mwan3track /usr/sbin/mwan3rtmon /lib/mwan3 /usr/share/rpcd/ucode/mwan3 /etc/hotplug.d/iface" ;;
    openvpn)   echo "/etc/init.d/openvpn /usr/share/openvpn /lib/functions/openvpn.sh /usr/sbin/openvpn /usr/libexec/openvpn-hotplug" ;;
    prometheus-node-exporter-lua) echo "/etc/init.d/prometheus-node-exporter-lua /usr/bin/prometheus-node-exporter-lua /usr/lib/lua/prometheus-collectors" ;;
    snmpd)     echo "/etc/init.d/snmpd /usr/sbin/snmpd /usr/bin/snmpd" ;;
    sqm)       echo "/usr/lib/sqm /etc/init.d/sqm" ;;
    system)    echo "/etc/init.d/system /etc/init.d/sysntpd /etc/init.d/log /lib/functions/system.sh /sbin/procd /etc/init.d/boot /lib/preinit" ;;
    uhttpd)    echo "/etc/init.d/uhttpd /usr/sbin/uhttpd" ;;
    unbound|unbound_ext|unbound_srv) echo "/usr/lib/unbound /usr/lib/unbound-uci-ext /etc/init.d/unbound" ;;
    usteer)    echo "/sbin/usteerd /etc/init.d/usteer" ;;
    vnstat)    echo "/etc/init.d/vnstat /usr/sbin/vnstatd /usr/bin/vnstat" ;;
    wireless)  echo "/lib/netifd/hostapd.sh /lib/netifd/wireless /usr/sbin/hostapd /usr/sbin/wpad /sbin/netifd /lib/netifd" ;;
  esac
}

seen() {
  c=$(corpus_for "$1"); [ -n "$c" ] || return 2
  for f in $c; do
    [ -e "$f" ] || continue
    grep -r -a -q -w -- "$2" "$f" 2>/dev/null && return 0
  done
  return 1
}

# Two probes per package, both naming an option that only appears in the real option table.
# One probe is not enough: openvpn/client passed against a corpus that could not see a single
# openvpn option, because the init happens to declare a shell local of that name.
for probe in "network:proto" "network:ip6assign" "firewall:src" "firewall:mtu_fix" \
             "dhcp:leasetime" "dhcp:dhcp_option" "dropbear:Port" "dropbear:RootPasswordAuth" \
             "lldpd:lldp_class" "lldpd:enable_cdp" "mwan3:reliability" "mwan3:track_ip" \
             "openvpn:client_to_client" "openvpn:persist_tun" "snmpd:community" "snmpd:sysLocation" \
             "sqm:download" "sqm:qdisc" "system:hostname" "system:timezone" \
             "uhttpd:listen_http" "uhttpd:cert" "unbound:recursion" "unbound_srv:srv_line" \
             "usteer:debug_level" "usteer:band_steering_threshold" "vnstat:interface" \
             "wireless:channel" "wireless:encryption" "prometheus-node-exporter-lua:listen_interface"; do
  p=${probe%%:*}; o=${probe##*:}
  seen "$p" "$o" || echo "SELFCHECK	$p	$o	corpus cannot see the option table"
done
seen firewall zzz_invented_option && echo "SELFCHECK	firewall	zzz_invented_option	an invented option matched"

while IFS="$(printf '\t')" read -r pkg mod opt; do
  seen "$pkg" "$opt"
  case $? in
    1) echo "DEAD	$pkg	$mod	$opt" ;;
    2) echo "SELFCHECK	$pkg	$mod	no corpus defined for this package" ;;
  esac
done
SH
}

# Accounted for as of 2026-08-09. Each is either already announced for removal, a deliberate
# decision, or an artifact of reading the option names out of the source. Anything not on
# this list is a new finding and fails the run.
accounted() {
	cat <<'EOF'
lldpd.config.uc	lldp_capabilities	legacy key cleared on write (out.x = [] deletes it), not a field
snmpd.system.uc	sysServices	legacy key cleared on write, not a field
unbound.server.uc	dnssec_enabled	legacy key cleared on write, not a field
wireless.interfaces.uc	assoclist_count	runtime field, never written to uci
wireless.interfaces.uc	txpower_actual	runtime field, never written to uci
system.uc	notes	read by LuCI (system.js), metadata by design, stays
EOF
}

inv=$(ucode scripts/audit_inventory.uc)
total=$(echo "$inv" | wc -l | tr -d ' ')
probe_script | $SSH "cat > /tmp/uapi-audit.sh"
out=$(echo "$inv" | $SSH "sh /tmp/uapi-audit.sh")

broken=$(echo "$out" | grep '^SELFCHECK' || true)
if [ -n "$broken" ]; then
	echo "$broken" | sed 's/^SELFCHECK\t/  /'
	echo "FAIL: the audit cannot see what it claims to check, so its result means nothing"
	exit 1
fi

tmp=$(mktemp); trap 'rm -f "$tmp" "$tmp.acc"' EXIT
echo "$out" | grep '^DEAD' > "$tmp" || true
accounted > "$tmp.acc"

new=$(awk -F'\t' 'NR==FNR { keep[$1 "\t" $2]=1; next }
                  !( ($3 "\t" $4) in keep ) { print "    " $3 "." $4 }' "$tmp.acc" "$tmp")

dead=$(wc -l < "$tmp" | tr -d ' ')
echo "  $total uci options checked against the reader that consumes them"
echo "  $dead with no reader, $(wc -l < "$tmp.acc" | tr -d ' ') of them accounted for"
if [ -n "$new" ]; then
	printf "\n  NEW, neither announced nor a known artifact:\n%s\n" "$new"
	echo "FAIL: a field nothing reads is unannounced; announce it before the major closes the window"
	exit 1
fi
echo "OK: nothing unaccounted for"
