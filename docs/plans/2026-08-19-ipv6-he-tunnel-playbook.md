# IPv6 via Hurricane Electric 6in4 on the rpi5

Operational playbook: install, maintain and remove a Hurricane Electric
tunnelbroker 6in4 tunnel terminated on the Raspberry Pi 5, giving the whole
LAN native-feeling IPv6 while Virgin Media remains IPv4-only.

## Summary

Virgin Media O2 still offers no IPv6 on any residential product, and there is
no published rollout date. A 6in4 tunnel from Hurricane Electric is the
standard workaround: free, a routed /48, and a London PoP so the latency cost
is small.

A **6in4** tunnel cannot live on the UCG. UniFi OS has no 6in4 support, and the
UCG series lacks the `on-boot-script` persistence that made hand-rolled tunnels
survivable on the UDM/UDR — anything configured by hand over SSH is erased by
the next firmware update. So the Pi terminates the tunnel.

Who *routes and firewalls* IPv6 for the LAN is a separate question, and UniFi
Network 10.x has moved it. Work through *Where the tunnel and the routing live*
before building anything: on 10.4+ the UCG may be able to do the routing, or
possibly the whole job via its WireGuard client. This playbook documents the
Pi-does-everything case; the others reuse most of it.

**The consequence to internalise before starting: in the Pi-does-everything
design, the UCG's firewall never sees an IPv6 packet.** Every LAN device gets a
globally routable address with no NAT in front of it, and the Pi's nftables
ruleset becomes the entire inbound perimeter for the whole network. Avoiding
that is the main argument for letting the UCG route.

## Topology

```
        Hurricane Electric  (tserv, London)
                 │
                 │  6in4 / protocol 41
                 │
        Virgin Media Hub  (MODEM MODE — no routing)
                 │
                 │  public IPv4
                 │
              UCG  ── IPv4 router, NAT, DHCPv4, firewall
                 │      IPv6 on every network: None
                 │
        ─────────┴──────────  LAN 10.1.1.0/24
           │                        │
         rpi5                  LAN clients
    10.1.1.5 / ::1            SLAAC from the Pi
    sit tunnel                IPv6 default gw = Pi
    radvd + nftables          IPv4 default gw = UCG
    IPv6 router + firewall
```

IPv4 traffic goes to the UCG. IPv6 traffic goes to the Pi. Clients learn the
IPv6 route from Router Advertisements, which are entirely separate from
DHCPv4, so no client configuration is needed anywhere.

## Where the tunnel and the routing live

Two decisions, not one: **who terminates the tunnel**, and **who routes and
firewalls IPv6 for the LAN**. They have different answers, and the second one
moved with UniFi Network 10.x.

### Verified on UniFi Network 10.6.97 (UCG Fiber, 2026-08-19)

All three capability checks were run in the live UI. **All three pass.** The
UCG can terminate the tunnel and route IPv6 itself — no Pi required.

**1. WireGuard VPN Client carries IPv6.** Settings → VPN → VPN Client → Create
New → Setup: **Manual** exposes:

| Field | Value |
|---|---|
| Tunnel IP → IPv6 Address | Accepts a GUA; netmask dropdown runs the full range, /64 selectable |
| Server Address → IP / Hostname | "IPv4/v6 Address or Hostname" |
| Advanced → IPv6 Maximum Segment Size | Auto / Custom / Off |

There is **no `AllowedIPs` field**. UniFi does not take raw WireGuard config in
Manual mode — routing into the tunnel is expressed separately, in Routing.

**2. IPv6 can be routed to the tunnel.** Settings → Routing → Create New Route
→ **Static**:

- Destination → Network accepts an "IPv4/v6 Subnet".
- Next Hop accepts an "IPv4/v6 Address".
- Choosing **Interface** instead of Next Hop opens a dropdown that lists
  Internet (WAN1/WAN2), **VPN Client**, Site-to-Site VPN, and every Network.

So `::/0` with Interface = the WireGuard VPN client is constructible. This is
already proven for IPv4 on this box: a `0.0.0.0/0 → Mullvad Zurich (VPN,
metric 50)` route is live.

**3. Networks take a static prefix and advertise it.** Settings → Networks →
[network] → IPv6 → Interface Type offers **None / Prefix Delegation / Static**.
Prefix Delegation is greyed out (it needs IPv6 on the WAN), but **Static** is
selectable and exposes IPv6 Address + Netmask (default /64), Client Address
Assignment **SLAAC** or DHCPv6, Auto DNS Server, **Router Advertisement (RA)**
and RA Priority.

That is the missing link: the UCG will emit RAs for a prefix you configure by
hand, with no IPv6 upstream on the WAN at all.

### Consequence

**Architecture A is the design.** The Pi is not needed. The 6in4 material in
Phases 1–5 below is retained only as the fallback if the UCG path fails in
practice.

### The design

```
Route64 r1-lon-uk (Telehouse, LONAP)
  185.121.24.12:20090
         │  WireGuard over IPv4  (UDP — Virgin's protocol-41 behaviour is moot)
  Virgin Hub (modem mode) → UCG Fiber
         │  wg tunnel  2a11:6c7:f06:9c::2/64   (peer ::1)
         │  static route  ::/0 → Interface: Route64 VPN client
         │
  UCG routes + firewalls IPv6, emits RAs per network
         │
  8 VLANs, each a Static /64 out of 2a11:6c7:1400:9c00::/56
```

Live tunnel (created 2026-08-19): **tb34563**, roadwarrior mode — Route64 waits
for the client to connect, so **Virgin's changing IPv4 needs no endpoint
updater at all**. That removes a whole component versus the 6in4 design.

| Value | |
|---|---|
| Endpoint | `185.121.24.12:20090` |
| Tunnel link | `2a11:6c7:f06:9c::2/64`, peer `::1` |
| Delegated prefix | `2a11:6c7:1400:9c00::/56` |
| PersistentKeepalive | 15 |
| Route64 AllowedIPs | `::/1, 8000::/1` (i.e. all of IPv6) |

### Address plan

The /56 gives 256 /64s. Map the VLAN ID into the fourth hextet so nothing needs
thinking about later:

| Network | VLAN | IPv4 | IPv6 prefix |
|---|---|---|---|
| LAN | 1 | 10.1.1.0/24 | `2a11:6c7:1400:9c01::/64` |
| IoT | 2 | 10.1.30.0/24 | `2a11:6c7:1400:9c02::/64` |
| Guest | 3 | 192.168.3.0/24 | `2a11:6c7:1400:9c03::/64` |
| Family | 4 | 192.168.4.0/24 | `2a11:6c7:1400:9c04::/64` |
| DMZ | 5 | 192.168.5.0/24 | `2a11:6c7:1400:9c05::/64` |
| Cilium-External | 50 | 192.168.50.0/24 | `2a11:6c7:1400:9c50::/64` |
| Management | 100 | 10.1.100.0/24 | `2a11:6c7:1400:9c64::/64` |
| Cilium-Internal | 200 | 10.1.200.0/24 | `2a11:6c7:1400:9cc8::/64` |

The gateway address on each is `…::1`. VLANs 100 and 200 use hex `64` and `c8`
because the hextet is hexadecimal — the alternative is decimal-looking labels
that collide, so pick one convention and keep it.

### The idle Mullvad VPN client

The routing view shows `0.0.0.0/0 → Mullvad Zurich` at metric 50, beating
`0.0.0.0/0 → Internet 1` at metric 200. Read as a single FIB with
metric-based selection, that says all IPv4 egresses via Mullvad.

**It does not.** Measured from a LAN host, the public IPv4 is
`92.239.242.145` (AS5089 Virgin Media) — traffic goes straight out of the WAN.

UniFi's VPN Client is a **policy-based routing** feature. Its default route
lives in the client's own routing table, and traffic only enters it when
something opts in — a Policy-Based Route, or the Device/Content Wizard that
generates one. On this gateway both wizards are **Off**, no policy-based route
exists, and the tunnel reports **0 bps in both directions** against nine hours
of uptime. It is connected and idle.

Two consequences:

1. **No conflict with the IPv6 plan.** Adding a Route64 client does not create
   a split-exit problem, because Mullvad is not carrying anything.
2. **The unified Routing view merges policy tables into one list.** A route
   shown there is not necessarily in the main FIB. Verify egress by measuring
   from a client, not by reading metrics off that screen.

The cluster's actual Mullvad usage is the gluetun sidecar in `db3000`, which is
unrelated to this gateway tunnel.

**Leave the UCG Mullvad client in place.** It is idle by design, costs nothing,
and the IPv6 work must not disturb it.

One forward-looking caveat: if traffic is ever opted into Mullvad via a
Policy-Based Route or the Device/Content Wizard, those networks would then
egress IPv4 through Zurich while their IPv6 still exits via Route64 in London.
Dual-stack sites prefer IPv6, so the Mullvad path would be bypassed for most
traffic. If that day comes, either scope the IPv6 prefix away from those
networks or accept the split deliberately — see [A.5](#a5-why-not-mullvad).

### What about BGP?

It looks like a native route to a tunnelbroker. It is not.

**BGP is not a tunnel.** It exchanges routes over an IP adjacency that must
already exist; it cannot create encapsulation. UniFi's BGP feature (UniFi OS
4.1.13+ on the UCG series) is an `frr.conf` upload with `bgpd=yes` — the
routing daemon only. FRR does not create tunnel interfaces in any deployment;
that is a kernel-level `ip link add ... type gre` job, exactly the
non-persistent shell territory the UCG locks down. A tunnelbroker's BGP
offering runs *on top of* one of their tunnels, so it removes nothing. It also
assumes you hold your own ASN and PI space.

### The remaining gap

No Ubiquiti documentation describes a LAN network consuming a **delegated
prefix from a VPN client interface**. Prefix Delegation sources from the WAN.
That is why architecture A depends on the **Static** LAN IPv6 path — you take
the prefix the tunnelbroker gave you and configure it by hand, rather than
expecting UniFi to learn it from the tunnel.

---

## Prerequisites

Complete all of these before Phase 0.

| Item | Requirement |
|---|---|
| Virgin Hub | **Modem mode.** The Hub must not be routing. |
| UCG | Holds the public IPv4 on WAN. |
| rpi5 | Raspberry Pi OS (Bookworm or later), NetworkManager, 64-bit. |
| rpi5 address | **Static IPv4 via DHCP reservation on the UCG** — assumed `10.1.1.5` throughout. Its LAN IPv4 is the tunnel's `local` endpoint and its LAN IPv6 becomes every client's default gateway; neither may move. |
| rpi5 uptime | The Pi becomes a single point of failure for IPv6. Treat it as infrastructure, not a toy. |
| HE account | Free, at <https://tunnelbroker.net>. |

Packages on the Pi:

```bash
sudo apt update
sudo apt install -y radvd nftables iputils-ping curl mtr-tiny iperf3
```

---

## Phase 0 — go/no-go throughput test

**Do this first. It gates the entire project.**

Virgin Media has a long history of mangling protocol 41. Users have reported
6in4 tunnels capped to roughly 20Mbps, and Virgin acknowledged the fault in
2020 ("will be fixed in a future firmware update") without ever confirming a
fix. The useful detail is that it affected Hub 3.0 and Hitron units but not
Hub 4.0, which points at a CPE bug rather than network-level shaping — so a
Hub in modem mode plausibly sidesteps it entirely.

Plausibly. Not certainly. Measure it.

1. Create a throwaway tunnel at <https://tunnelbroker.net> (see Phase 1 for
   the WAN-ping prerequisite, which applies here too).
2. Bring it up on the Pi with the quick-and-dirty non-persistent form:

   ```bash
   HE_SERVER=216.66.80.30              # from your tunnel details page
   HE_CLIENT_V6=2001:470:xxxx:yyyy::2  # "Client IPv6 Address"
   HE_SERVER_V6=2001:470:xxxx:yyyy::1  # "Server IPv6 Address"

   sudo ip tunnel add he-test mode sit remote "$HE_SERVER" local 10.1.1.5 ttl 255
   sudo ip link set he-test up mtu 1480
   sudo ip addr add "${HE_CLIENT_V6}/64" dev he-test
   sudo ip -6 route add ::/0 via "$HE_SERVER_V6" dev he-test
   ```

3. Prime the NAT state and confirm the tunnel is alive:

   ```bash
   ping -6 -c 4 "$HE_SERVER_V6"
   ping -6 -c 4 ipv6.google.com
   ```

4. Measure:

   ```bash
   curl -6 -o /dev/null -w '%{speed_download}\n' \
     http://speedtest.london.linode.com/100MB-london.bin
   # or, against a public iperf3 server
   iperf3 -6 -c IPERF_SERVER -t 20   # e.g. lon.speedtest.clouvider.net
   ```

5. Tear down:

   ```bash
   sudo ip link del he-test
   ```

**Decision:**

- Near line rate → proceed to Phase 1.
- Pinned around 20Mbps → **stop.** The proto-41 cap is real on your line.
  Skip to *Appendix A — WireGuard alternative*.

---

## Phase 1 — create the tunnel

### WAN must answer ping

Hurricane Electric pings your IPv4 endpoint before it will create the tunnel.
If the UCG drops WAN ICMP echo, tunnel creation fails with an unhelpful error.

In UniFi: **Settings → Security → Firewall** — allow inbound ICMP echo-request
on WAN. Verify from an external host before continuing:

```bash
ping -c 3 PUBLIC_IPV4
```

You can re-block it afterwards, but leaving it enabled makes future
troubleshooting far easier and exposes nothing meaningful.

### Create it

1. <https://tunnelbroker.net> → **Create Regular Tunnel**.
2. IPv4 endpoint: your Virgin public IPv4.
3. Tunnel server: **London** — lowest latency from the UK.
4. On the tunnel's page, **Assign a /48** as well as the default routed /64.
   It is free, and it saves renumbering when VLANs arrive.
5. Record everything from the *IPv6 Tunnel Endpoints* and *Routed IPv6
   Prefixes* panels, plus the **Update Key** from the *Advanced* tab.

The London server IPv4 is typically `216.66.80.30` (`tserv1.lon1`), but read
the exact **Server IPv4 Address** from your own tunnel details page rather
than assuming.

### Address plan

Fill this in and keep it with the doc. Every later step references it.

| Name | Value | Source |
|---|---|---|
| HE server IPv4 | `216.66.80.30` | Server IPv4 Address |
| HE server IPv6 | `2001:470:xxxx:yyyy::1` | Server IPv6 Address |
| Pi tunnel IPv6 | `2001:470:xxxx:yyyy::2/64` | Client IPv6 Address |
| Routed /48 | `2001:470:zzzz::/48` | Routed IPv6 Prefixes |
| Tunnel ID | `1234567` | URL / Advanced tab |
| Update key | *(secret)* | Advanced tab |

Carve the /48 by VLAN ID so future segments need no thought. The flat LAN is
VLAN 1:

| Segment | VLAN | Prefix | Router address (the Pi) |
|---|---|---|---|
| LAN (10.1.1.0/24) | 1 | `2001:470:zzzz:1::/64` | `2001:470:zzzz:1::1` |
| *(future)* IoT | 20 | `2001:470:zzzz:20::/64` | `2001:470:zzzz:20::1` |
| *(future)* Guest | 30 | `2001:470:zzzz:30::/64` | `2001:470:zzzz:30::1` |

The tunnel /64 (`xxxx:yyyy`) is point-to-point between the Pi and HE. It is
**not** the LAN prefix — never advertise it.

---

## Phase 2 — UCG configuration

Phases 1–6 document the **6in4-on-the-Pi fallback**, kept in case the UCG path
fails in practice. For the primary design, see *The design* above.

1. **Settings → Networks →** each network **→ IPv6**: set to **None**. This
   stops the UCG emitting Router Advertisements that would compete with the
   Pi's. If both advertise, clients get two default routes and behaviour
   becomes nondeterministic.
2. **WAN ICMP echo**: already enabled in Phase 1. Leave it.
3. **DHCP reservation** for the Pi at `10.1.1.5`, if not done already.
4. Nothing else. No port forwards, no static routes.

### On protocol 41 and NAT

UniFi port forwarding is TCP/UDP only and there is no DMZ host, so protocol 41
cannot be forwarded explicitly. What works in practice is Linux's *generic*
connection tracking: an outbound proto-41 packet from the Pi creates a
conntrack entry, and HE's replies are NAT'd back to it. This is undocumented
and unsupported by Ubiquiti, but it is how most people run HE tunnels behind
consumer NAT.

Two consequences, both handled in Phase 3:

- **The Pi must send first.** Nothing from HE can arrive until the Pi has
  primed the conntrack entry. Immediately after bring-up the tunnel will look
  completely dead — that is expected.
- **The Pi must keep sending.** The generic conntrack timeout is around 600
  seconds. Go quiet for longer and inbound traffic stops. Hence the keepalive
  service.

---

## Phase 3 — build the Pi

### 3.1 Kernel settings

```bash
sudo tee /etc/sysctl.d/99-ipv6-router.conf >/dev/null <<'EOF'
# The Pi is an IPv6 router for the LAN
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1

# It is a router, not a host: never accept RAs from anyone
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0

# IPv4 routing stays with the UCG
net.ipv4.ip_forward = 0
EOF

sudo sysctl --system
```

### 3.2 LAN interface

Give the Pi its LAN IPv6 gateway address. Adjust the connection name to match
`nmcli connection show`.

```bash
sudo nmcli connection modify 'Wired connection 1' \
  ipv6.method manual \
  ipv6.addresses 2001:470:zzzz:1::1/64 \
  ipv6.never-default yes \
  ipv6.ignore-auto-routes yes \
  ipv6.ignore-auto-dns yes

sudo nmcli connection up 'Wired connection 1'
```

`ipv6.never-default yes` matters: the LAN interface must not carry a default
route, or it will fight the tunnel's.

### 3.3 The tunnel

```bash
sudo nmcli connection add \
  type ip-tunnel \
  con-name he-ipv6 \
  ifname he-ipv6 \
  ip-tunnel.mode sit \
  ip-tunnel.parent eth0 \
  ip-tunnel.local 10.1.1.5 \
  ip-tunnel.remote 216.66.80.30 \
  ip-tunnel.ttl 255 \
  ip-tunnel.mtu 1480 \
  ipv4.method disabled \
  ipv6.method manual \
  ipv6.addresses 2001:470:xxxx:yyyy::2/64 \
  ipv6.gateway 2001:470:xxxx:yyyy::1 \
  connection.autoconnect yes

sudo nmcli connection up he-ipv6
```

Notes:

- `ip-tunnel.local` is the Pi's **private** LAN address, not the public IPv4.
  HE sees the public address because the UCG NATs the packets.
- `ip-tunnel.parent eth0` makes NetworkManager order the tunnel after the LAN
  interface on boot.
- `ip-tunnel.mtu` needs a reasonably recent NetworkManager. If `nmcli` rejects
  it, drop the property and set the MTU from a dispatcher script instead
  (below).

If the `ip-tunnel.mtu` fallback is needed:

```bash
sudo tee /etc/NetworkManager/dispatcher.d/50-he-ipv6-mtu >/dev/null <<'EOF'
#!/bin/sh
[ "$1" = "he-ipv6" ] && [ "$2" = "up" ] && ip link set he-ipv6 mtu 1480
exit 0
EOF
sudo chmod 0755 /etc/NetworkManager/dispatcher.d/50-he-ipv6-mtu
```

Confirm:

```bash
ip -6 addr show dev he-ipv6
ip -6 route show default
```

### 3.4 Keepalive

Holds the UCG's conntrack entry open and primes it on boot. Long-running and
quiet rather than a timer, so it produces one process and no journal spam.

```bash
sudo tee /etc/systemd/system/he-tunnel-keepalive.service >/dev/null <<'EOF'
[Unit]
Description=Keep HE 6in4 NAT state alive through the UCG
After=network-online.target NetworkManager-wait-online.service
Wants=network-online.target

[Service]
ExecStart=/bin/ping -6 -q -i 30 2001:470:xxxx:yyyy::1
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now he-tunnel-keepalive.service
```

30 seconds is comfortably inside the ~600s conntrack timeout and costs
nothing. **Start this before testing anything inbound.**

### 3.5 Endpoint updater

Virgin's IPv4 is semi-static but does move. When it does, HE keeps sending to
the old address and the tunnel dies silently until told otherwise.

Credentials go in a mode-0600 file read by `curl -K`, so they never appear in
the process table:

```bash
sudo install -d -m 0700 /etc/he-tunnel
sudo tee /etc/he-tunnel/update.conf >/dev/null <<'EOF'
url = "https://ipv4.tunnelbroker.net/nic/update?hostname=TUNNEL_ID"
user = "HE_USERNAME:HE_UPDATE_KEY"
EOF
sudo chmod 0600 /etc/he-tunnel/update.conf
```

HE takes the new endpoint from the source address of the request, so no `myip`
parameter is needed. The script only calls out when the address has actually
changed:

```bash
sudo tee /usr/local/sbin/he-endpoint-update >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state=/var/lib/he-tunnel/last-ip
current=$(curl -4 -fsS --max-time 10 https://api.ipify.org) || exit 0

if [[ -f $state && $(< "$state") == "$current" ]]; then
    exit 0
fi

curl -fsS --max-time 30 -K /etc/he-tunnel/update.conf >/dev/null
install -D -m 0644 /dev/null "$state"
printf '%s\n' "$current" > "$state"
logger -t he-tunnel "endpoint updated to $current"
EOF
sudo chmod 0755 /usr/local/sbin/he-endpoint-update
```

```bash
sudo tee /etc/systemd/system/he-endpoint-update.service >/dev/null <<'EOF'
[Unit]
Description=Update HE tunnel IPv4 endpoint
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/he-endpoint-update
EOF

sudo tee /etc/systemd/system/he-endpoint-update.timer >/dev/null <<'EOF'
[Unit]
Description=Check HE tunnel IPv4 endpoint every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now he-endpoint-update.timer
```

---

## Phase 4 — the firewall

This is the security boundary for every IPv6-capable device on the network.
Write it before advertising anything.

```bash
sudo tee /etc/nftables.conf >/dev/null <<'EOF'
#!/usr/sbin/nft -f

flush ruleset

define HE_SERVER  = 216.66.80.30
define WAN_IF     = "he-ipv6"
define LAN_IF     = "eth0"
define LAN_PREFIX = 2001:470:zzzz:1::/64

table inet filter {

    chain input {
        type filter hook input priority filter; policy drop;

        iif lo accept
        ct state established,related accept
        ct state invalid drop

        # 6in4 encapsulation, from the HE tunnel server only.
        # Without this the Pi drops its own tunnel traffic.
        ip protocol 41 ip saddr $HE_SERVER accept

        # ICMPv6 the protocol actually requires (RFC 4890).
        # Blanket-dropping ICMPv6 breaks neighbour discovery and PMTUD.
        icmpv6 type {
            destination-unreachable, packet-too-big, time-exceeded,
            parameter-problem, echo-request, echo-reply,
            nd-router-solicit, nd-router-advert,
            nd-neighbor-solicit, nd-neighbor-advert
        } accept

        icmp type { destination-unreachable, echo-request, time-exceeded } accept

        # Management, LAN only
        iifname $LAN_IF tcp dport 22 accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;

        ct state invalid drop

        # Clamp MSS to the 1480-byte tunnel path, before the established
        # accept — otherwise reply-direction SYN-ACKs match as established
        # and only the outbound SYN gets clamped.
        # Without this, large responses stall behind PMTUD blackholes.
        tcp flags syn tcp option maxseg size set rt mtu

        ct state established,related accept

        icmpv6 type {
            destination-unreachable, packet-too-big, time-exceeded,
            parameter-problem, echo-request, echo-reply
        } accept

        # LAN -> Internet
        iifname $LAN_IF oifname $WAN_IF ip6 saddr $LAN_PREFIX accept

        # Internet -> LAN: nothing by default.
        # Add explicit per-host, per-port allows here, e.g.
        # iifname $WAN_IF oifname $LAN_IF \
        #     ip6 daddr 2001:470:zzzz:1::60 tcp dport { 80, 443 } accept
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF

sudo nft -c -f /etc/nftables.conf      # syntax check first
sudo systemctl enable --now nftables
sudo nft list ruleset                  # confirm what is loaded
```

Keeping SSH reachable from the LAN over IPv4 means a mistake in the IPv6 rules
never locks you out of the Pi.

---

## Phase 5 — advertise to clients, in two steps

The staged rollout is the client-side equivalent of the Phase 0 throughput
gate. Advertise the prefix *without* a default route first, prove IPv6 works,
then flip the switch. If something is wrong, no client has ever had a broken
default route.

### 5.1 Stage — addresses only, no default route

```bash
sudo tee /etc/radvd.conf >/dev/null <<'EOF'
interface eth0
{
    AdvSendAdvert on;
    MinRtrAdvInterval 30;
    MaxRtrAdvInterval 100;
    AdvLinkMTU 1480;

    # STAGING: hand out addresses but do not become anyone's default route.
    AdvDefaultLifetime 0;

    prefix 2001:470:zzzz:1::/64
    {
        AdvOnLink on;
        AdvAutonomous on;
        AdvRouterAddr on;
    };
};
EOF

sudo systemctl enable --now radvd
sudo systemctl status radvd
```

DNS is deliberately not advertised. Clients keep using the UCG's IPv4
resolver, which returns AAAA records perfectly well. Add an `RDNSS` clause
only if the Pi itself runs a resolver.

On a client, confirm it picks up a global address from the right prefix:

```bash
# macOS
ifconfig en0 | grep inet6
# Linux
ip -6 addr show scope global
```

The client should now have a `2001:470:zzzz:1::…` address and **no** IPv6
default route. From the Pi, confirm the path works end to end:

```bash
ping -6 -c 4 ipv6.google.com
mtr -6 -rwc 20 ipv6.google.com
```

### 5.2 Go live

Only when the above is clean:

```bash
sudo sed -i 's/^    AdvDefaultLifetime 0;/    AdvDefaultLifetime 1800;/' /etc/radvd.conf
sudo sed -i '/# STAGING: hand out addresses/d' /etc/radvd.conf
sudo systemctl restart radvd
```

Clients pick up the default route within one RA interval — under two minutes,
usually seconds.

---

## Phase 6 — verification

| Check | Command / action | Expected |
|---|---|---|
| Tunnel interface | `ip -6 addr show he-ipv6` | Client IPv6 address present, state UP |
| Default route | `ip -6 route show default` | `via <HE server IPv6> dev he-ipv6` |
| Far end reachable | `ping -6 -c4 <HE server IPv6>` | 0% loss |
| Internet from Pi | `ping -6 -c4 ipv6.google.com` | 0% loss |
| Keepalive running | `systemctl is-active he-tunnel-keepalive` | `active` |
| Client address | `ip -6 addr` on a client | GUA from `2001:470:zzzz:1::/64` |
| Client route | `ip -6 route show default` on a client | via the Pi's `::1` |
| Client internet | `curl -6 https://ifconfig.co` | returns the client's GUA |
| End-to-end score | <https://test-ipv6.com> | 10/10 |
| MTU sanity | Load several large, image-heavy HTTPS sites | No half-loaded pages or stalls |
| Throughput | `iperf3 -6 -c IPERF_SERVER -t 20` | Comparable to Phase 0 |
| Firewall holds | From outside: `nmap -6 -Pn <a client GUA>` | All ports filtered |

That last row is worth doing properly. Run it from a machine off your network.

---

## Maintenance

### Routine

| Cadence | Task |
|---|---|
| Continuous | Alerting on tunnel far-end reachability (below) |
| Monthly | `journalctl -u he-endpoint-update --since '30 days ago'` — confirm endpoint changes were caught |
| Monthly | Re-run the Phase 0 throughput test; Virgin's proto-41 behaviour has changed before |
| On Pi OS upgrade | Re-verify `nft list ruleset` and `ip -6 route` after reboot |
| Annually | Confirm the HE tunnel is still active — HE reclaims long-idle tunnels |

### Monitoring

The cluster already runs Prometheus. The single most valuable signal is
reachability of the tunnel far end. Add a blackbox-exporter ICMP probe against
the HE server IPv6 address and a probe against a public IPv6 host, then alert
on either failing for five minutes. That distinguishes "tunnel down" from
"HE having a bad day".

Also worth an alert: `he-tunnel-keepalive.service` not active. If it dies, the
tunnel degrades ten minutes later with no other warning, which is a miserable
thing to debug cold.

### Streaming services

Netflix and several others treat Hurricane Electric prefixes as proxy space
and will refuse to play. The usual fix is to blackhole their IPv6 ranges on
the Pi so affected clients fall back to IPv4:

```bash
sudo ip -6 route add blackhole 2620:10c:7000::/44   # example — verify current ranges
```

Make it persistent via an `ip-tunnel`-up dispatcher script or a small
`systemd` oneshot ordered after `he-ipv6`. Verify the ranges before adding
them; they change.

### Adding a VLAN later

The /48 is already carved. For VLAN 20:

1. Create the VLAN in UniFi with IPv6 set to **None**.
2. Change the Pi's switch port to a trunk carrying that VLAN.
3. Add the sub-interface and address:

   ```bash
   sudo nmcli connection add type vlan con-name vlan20 ifname eth0.20 \
     dev eth0 id 20 \
     ipv4.method disabled \
     ipv6.method manual ipv6.addresses 2001:470:zzzz:20::1/64 \
     ipv6.never-default yes
   ```

4. Add a matching `interface eth0.20` block to `radvd.conf`.
5. Add the prefix to nftables — extend `LAN_PREFIX` to a set, and add the
   interface to the forward rule.

### If the /48 or tunnel endpoint changes

HE prefixes are stable for the life of the tunnel. If you rebuild the tunnel
you get new addressing, which means updating: the Pi's tunnel and LAN
addresses, `radvd.conf`, `nftables.conf`, the keepalive target, and any AAAA
records in DNS. Deprecate the old prefix (see Uninstall, step 1) before
introducing the new one so clients do not sit on dead addresses.

### Future work — Kubernetes dual-stack

Native IPv6 for cluster workloads is a separate project. It means enabling
dual-stack in the Talos machine config and Cilium, assigning a /64 from the
/48 to the cluster, and giving Traefik an IPv6 LoadBalancer address via
Cilium LB-IPAM. Do not attempt it as part of this playbook — get the LAN
working and stable first.

In the meantime, exposing a service over IPv6 is a single nftables forward
rule to the Traefik LoadBalancer's host plus an AAAA record.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Tunnel just created, completely dead | UCG conntrack not primed — HE cannot reach the Pi until the Pi sends first | Start `he-tunnel-keepalive`, or `ping -6` the far end manually. This is the single most common "it doesn't work" moment |
| HE refuses to create the tunnel | Endpoint not pingable | Allow inbound ICMP echo on the UCG's WAN |
| Tunnel works, then dies after ~10 minutes idle | Keepalive stopped, conntrack entry expired | `systemctl status he-tunnel-keepalive`; interval must stay well under 600s |
| Tunnel dead after an outage | Virgin handed out a new IPv4 | `sudo /usr/local/sbin/he-endpoint-update`; check the timer is enabled |
| Wired clients get IPv6, wireless do not | UniFi WiFi multicast filtering eating RAs | Check the network's Multicast/Broadcast control and IGMP snooping settings |
| Clients have a GUA but no default route | `AdvDefaultLifetime 0` still set from staging | Phase 5.2 |
| Two IPv6 default routes on clients | UCG still advertising | Set IPv6 to **None** on every UniFi network |
| Pages load halfway then stall | MTU / PMTUD blackhole | Confirm tunnel MTU is 1480, `AdvLinkMTU 1480` is set, MSS clamp rule present, and ICMPv6 packet-too-big is not being dropped |
| Everything works but caps near 20Mbps | Virgin's protocol-41 behaviour | Appendix A |
| Netflix reports a proxy | HE prefix geo-blocked | Blackhole their IPv6 ranges |
| IPv6 slower than IPv4 for one site | Poor routing from HE's London PoP | `mtr -6` to confirm; blackhole that prefix if it matters |
| Pi rebooted, no IPv6 anywhere | A unit did not come back | `systemctl is-active radvd nftables he-tunnel-keepalive` and `nmcli con show --active` |

---

## Emergency kill switch

IPv6 has broken something and you need it gone across the LAN in seconds. This
is not the uninstall — it is the "make it stop" button.

```bash
sudo sed -i 's/^    AdvDefaultLifetime .*/    AdvDefaultLifetime 0;/' /etc/radvd.conf
sudo systemctl restart radvd
```

Clients drop the IPv6 default route within one RA interval and fall straight
back to IPv4. They keep their IPv6 addresses, which is harmless — nothing
routes anywhere.

Do **not** simply `systemctl stop radvd`. With no final advertisement, clients
hold the stale default route until it ages out, which can be half an hour of
IPv6 blackhole.

To restore, set the lifetime back to 1800 and restart.

---

## Uninstall

Order matters. Tearing down the tunnel before withdrawing the advertisements
leaves every client blackholing IPv6 for up to 30 minutes.

**1. Deprecate the prefix.** Withdraw the default route *and* mark existing
addresses deprecated, so clients stop opening new connections from them:

```bash
sudo tee /etc/radvd.conf >/dev/null <<'EOF'
interface eth0
{
    AdvSendAdvert on;
    MinRtrAdvInterval 30;
    MaxRtrAdvInterval 100;
    AdvDefaultLifetime 0;

    prefix 2001:470:zzzz:1::/64
    {
        AdvOnLink off;
        AdvAutonomous on;
        AdvPreferredLifetime 0;
        AdvValidLifetime 0;
    };
};
EOF

sudo systemctl restart radvd
```

If radvd refuses to start with a lifetime of `0`, use `1` for both.

**2. Wait.** Give it ten minutes and confirm on a client that the IPv6 default
route is gone and traffic has moved to IPv4.

Note that clients may hold the *deprecated* address for up to about two hours
— RFC 4862 imposes a floor on how fast a valid lifetime can be reduced, to
stop forged RAs from evicting addresses. This is expected and harmless: a
deprecated address is not used for new connections. Do not read it as a failed
uninstall.

**3. Stop advertising.**

```bash
sudo systemctl disable --now radvd
```

**4. Tear down the tunnel and its services.**

```bash
sudo systemctl disable --now he-tunnel-keepalive.service
sudo systemctl disable --now he-endpoint-update.timer
sudo nmcli connection down he-ipv6
sudo nmcli connection delete he-ipv6

sudo rm -f /etc/systemd/system/he-tunnel-keepalive.service
sudo rm -f /etc/systemd/system/he-endpoint-update.{service,timer}
sudo rm -f /usr/local/sbin/he-endpoint-update
sudo rm -f /etc/NetworkManager/dispatcher.d/50-he-ipv6-mtu
sudo rm -rf /etc/he-tunnel /var/lib/he-tunnel
sudo systemctl daemon-reload
```

**5. Revert the Pi's LAN interface and kernel settings.**

```bash
sudo nmcli connection modify 'Wired connection 1' \
  ipv6.method disabled \
  ipv6.addresses '' \
  ipv6.never-default no
sudo nmcli connection up 'Wired connection 1'

sudo rm -f /etc/sysctl.d/99-ipv6-router.conf
sudo sysctl --system
```

**6. Firewall.** Either revert `/etc/nftables.conf` to whatever preceded this
work, or if the Pi had no firewall before:

```bash
sudo systemctl disable --now nftables
sudo rm -f /etc/nftables.conf
```

**7. Remove every AAAA record published during the tunnel's life.** Easy to
forget, and the consequence is real: dual-stack visitors prefer AAAA, so a
stale record blackholes them until it times out. Check Cloudflare for the
domain and any internal DNS.

**8. Delete the tunnel at HE.** <https://tunnelbroker.net> → the tunnel →
*Advanced* → **Remove Tunnel**. This releases the /48 back to HE; you will not
get the same one again.

**9. UCG.** Networks stay on IPv6 **None** — that is the correct setting with
no IPv6 upstream. Optionally remove the WAN ICMP echo rule if you added it
solely for HE.

---

## Appendix A — WireGuard alternative

Use this if Phase 0 shows the protocol-41 cap, or if the NAT-conntrack
dependency proves flaky in practice.

The idea is the same tunnel with a different encapsulation: WireGuard is UDP,
so Virgin's protocol-41 handling becomes irrelevant, and it traverses NAT
properly with a real keepalive rather than a conntrack side-effect.

Everything downstream is **identical** — the same radvd config, the same
nftables ruleset, the same staged rollout, the same uninstall. Only `WAN_IF`
changes from `he-ipv6` to `wg0`, and the addressing comes from the new prefix.

### A.1 The two shapes

**Tunnelbroker over WireGuard.** Someone else runs the far end and delegates a
prefix. Free, nothing to patch, no server to own. You depend on their uptime.

**Your own VPS.** A cheap instance running `wg` with
`net.ipv6.conf.all.forwarding=1` and a route for the delegated prefix pointing
down the tunnel. More control, a machine to keep patched, a few pounds a month.

The Pi side is the same either way: a WireGuard client with
`PersistentKeepalive = 25`, holding a /64 from the delegated prefix.

### A.2 What actually matters when choosing

Three criteria, in order. Most provider comparisons ignore all three.

1. **Routed, not on-link.** A *routed* prefix is a static route and nothing
   else. An *on-link* prefix means the upstream expects neighbour discovery on
   the segment, so forwarding it onward needs `ndppd` proxying ND for
   addresses that are not really there. It works, but it is a hack with an
   extra daemon to fail. Ask the provider which they do — it is rarely stated
   on the pricing page.
2. **Prefix size ≥ /56.** A /64 is exactly one subnet. It cannot be carved
   per-VLAN, so it breaks the "flat now, VLANs later" plan in the address plan
   above. /56 gives 256 /64s; /48 gives 65,536.
3. **Latency to the PoP.** This becomes the default route for every device on
   the LAN, so the hop is paid on all IPv6 traffic. London is ~5–10ms;
   Luxembourg or Frankfurt ~20–30ms. Noticeable, not fatal.

### A.3 Options

| Option | Cost | Prefix | Routed? | Nearest PoP | Verdict |
|---|---|---|---|---|---|
| **Hurricane Electric** (6in4) | Free | /48 | Yes | London | First choice — *if* Phase 0 passes |
| **Route64** (AS212895) | Free | /56 | Yes | London | Best free fallback. WireGuard, so proto-41 is moot |
| **BuyVM KVM Slice** (Luxembourg) | $2/mo | /48 free | Yes | Luxembourg | Best paid option. Genuinely routed, no `ndppd`, unmetered |
| **Hetzner Cloud** | ~€4/mo | /64 | Verify | Falkenstein / Helsinki | Only one /64 — no room for VLANs |
| **Vultr** | ~$3.50/mo | /64 | **On-link** | London | Needs `ndppd`. Reserved /64 add-on is also on-link |
| **DigitalOcean** | ~$4/mo | **/124** | n/a | London | **Rule out.** 16 addresses total; cannot serve a LAN |

**Recommended order:** HE → Route64 → BuyVM.

### A.4 Notes on the shortlist

**Route64** is a free non-profit tunnelbroker offering a routed /56 over
WireGuard (also SIT, GRE, GRETAP, L2TPv3, VXLAN), with a London PoP and around
200Mbit of transit. Signup is automated. It is the natural fallback: free like
HE, but UDP-encapsulated, so it sidesteps the entire Virgin protocol-41
question.

The caveat is operational, not technical. It is essentially a one-person
non-profit, support runs through Discord and can take days, and there is no
SLA. That is a real consideration for something the whole LAN's IPv6 default
route depends on — though the failure mode is graceful, since clients fall back
to IPv4 the moment the RAs stop.

**BuyVM** includes a **free routed /48** with every KVM Slice, starting at
$2/mo unmetered, with rDNS delegation. A genuinely routed /48 at that price is
unusual — most budget providers give an on-link /64 and leave you to `ndppd`.
Luxembourg is the EU location, so expect ~20–30ms rather than London's ~5–10ms.
You also get a general-purpose box out of it.

**Hetzner and Vultr** both give a single /64, which is the blocking problem
regardless of routing: no room to give each future VLAN its own /64. Vultr's is
additionally on-link.

**DigitalOcean** allocates a /124 — 16 addresses, no more available. It cannot
delegate anything and is not a candidate.

Try HE first. Its London PoP keeps the latency penalty small, it hands out a
/48, and it is free.

### A.5 Why not Mullvad

A commercial privacy VPN cannot substitute for the VPS, even though the
transport is the same WireGuard. Mullvad specifically:

- **Delegates no prefix.** It assigns a single `/128` from a ULA range
  (`fc00:bbbb:bbbb:bb01::x/128`) and NAT66s it to a shared public exit. There
  is no `/64` to advertise, so radvd has nothing to hand out.
- **Would be ignored by clients even with NAT66.** Giving the LAN ULA
  addresses and masquerading out through Mullvad technically works, but RFC
  6724 address selection makes clients prefer IPv4 over a ULA source for
  global destinations. The plumbing would exist and go almost entirely unused.
- **Offers no inbound.** Port forwarding was removed in July 2023 and the exit
  address is shared, so nothing on the LAN is ever reachable from outside.

Beyond IPv6, routing the whole LAN through a privacy VPN geo-shifts every
device's egress — captchas and streaming blocks considerably worse than HE's.
That is a separate decision from wanting IPv6.

The `db3000` gluetun/transmission Mullvad connection is unaffected by any of
this and should stay as it is.

---

## References

- [Hurricane Electric Tunnel Broker](https://tunnelbroker.net/)
- [Is Virgin Media traffic shaping protocol 41 (6in4 IPv6)?](https://www.jmwhite.co.uk/blog/is-virgin-media-traffic-shaping-protocol-41-6in4-ipv6)
- [Virgin Media UK Move to Fix 20Mbps Speed Cap on IPv6 Tunnels](https://www.ispreview.co.uk/index.php/2020/08/virgin-media-uk-move-to-fix-20mbps-speed-cap-on-ipv6-tunnels.html)
- [Quick Update for Virgin Media Speed Issues on IPv6 Tunnels](https://www.ispreview.co.uk/index.php/2020/09/quick-update-for-virgin-media-speed-issues-on-ipv6-tunnels.html)
- [unifi-utilities — UCG Ultra discussion](https://github.com/orgs/unifi-utilities/discussions/626)
- [UniFi — Border Gateway Protocol (BGP)](https://help.ui.com/hc/en-us/articles/16271338193559-UniFi-Border-Gateway-Protocol-BGP)
- [Feature request — IPv6 support in UniFi WireGuard VPN](https://community.ui.com/questions/Feature-Request-IPv6-support-in-UniFi-WireGuard-VPN-configuration/29ef190f-87e9-4d08-8d91-237449ccdd1c)
- [NetworkManager ip-tunnel settings](https://networkmanager.dev/docs/api/latest/settings-ip-tunnel.html)
- [RFC 4890 — Filtering ICMPv6 Messages in Firewalls](https://www.rfc-editor.org/rfc/rfc4890)
- [IPv6 tunnel broker setup — ArchWiki](https://wiki.archlinux.org/title/IPv6_tunnel_broker_setup)
- [Mullvad — Removing the support for forwarded ports](https://mullvad.net/en/blog/removing-the-support-for-forwarded-ports)
- [RFC 6724 — Default Address Selection for IPv6](https://www.rfc-editor.org/rfc/rfc6724)
- [ROUTE64 — free IPv6 tunnelbroker and transit](https://www.route64.org/en)
- [BuyVM — KVM Slices](https://buyvm.net/kvm-dedicated-server-slices/)
- [DigitalOcean — IPv6 limits](https://docs.digitalocean.com/products/networking/ipv6/details/limits/)
