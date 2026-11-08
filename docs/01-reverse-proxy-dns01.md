# Wildcard HTTPS at home, behind an ISP router I thought was a dead end

I run a small homelab on Proxmox: a few LXC containers, a Jellyfin media server, and a reverse proxy I had set up months ago and never gotten to work. Reaching anything meant remembering the IP address for each specific container. I had read enough forums to conclude that my ISP's router made a working reverse proxy impossible, and I left it at that.

That conclusion was wrong, and the way it was wrong turned out to be the interesting part.

## Two problems, not one

The thing I had mixed up: a reverse proxy and *external access* are separate concerns. The proxy itself needs nothing from the router. It listens on the LAN, something resolves a name to its address, and it forwards to the right backend. The router only enters the picture when traffic has to come in from outside.

What I actually wanted was to type `jellyfin.<mydomain>` at home and have it work, with real HTTPS and no browser warnings. That requires exactly two things: an internal DNS server that answers for those names, and a certificate a browser will trust.

I already had both pieces installed. Nginx Proxy Manager was the proxy. Pi-hole was already running as an ad blocker, and Pi-hole is a DNS server. Nothing was missing. The pieces just weren't wired together.

## Why the certificate was the real blocker

Let's Encrypt won't issue a certificate unless you prove you control the domain. The default method, HTTP-01, works by Let's Encrypt connecting *to you* on port 80. That is the part that depends on the router, and it's where the "my ISP makes this impossible" belief comes from. It also can't issue wildcard certificates at all.

DNS-01 proves control differently: the client creates a TXT record in the domain's DNS, Let's Encrypt reads it, and the record is removed. Nothing connects inward. No port is opened. The router is not involved in any way.

That single difference is what unlocked the whole thing. It also gets me wildcards, which means one certificate covers every service I will ever add.

## What I built

**A domain.** I was putting this off because of the cost, then found the GitHub Student Developer Pack covers a free first year through several registrars. I picked a `.dev` because the renewal price was among the lowest and the extension suits what I'm doing. Note that `.dev` and `.app` are on the browsers' HSTS preload list — they *cannot* be served over plain HTTP, ever. In my case that was fine, since valid certificates were the goal anyway.

**Cloudflare for DNS.** Not to serve anything — I deliberately keep zero public DNS records. Cloudflare is there because DNS-01 needs an API that can create a TXT record automatically at renewal time, three months from now, at 3 AM, with nobody watching. Most registrars don't offer one.

**A scoped API token.** Permissions limited to `DNS:Edit` on that one zone, nothing else. More on why below.

**A wildcard certificate** for `*.<mydomain>`, issued via DNS-01 against Cloudflare, renewing automatically.

**Split DNS in Pi-hole.** A single line in `/etc/dnsmasq.d/99-wildcard.conf`:

```
address=/<mydomain>/<proxy-ip>
```

One line covers every subdomain I will ever create. The names exist only inside my network, which is why having no public DNS records is a feature and not an oversight.

**Tailscale for resolution off-LAN.** My ISP router has no DHCP option for handing out a custom DNS server, so I pointed Tailscale at Pi-hole as a restricted nameserver for just my domain. Everything else resolves normally. Side benefit: the names now work from anywhere I'm on the tailnet, not just at home.

Adding a service is now one entry in the proxy. No certificate work, no DNS record, no ports.

## What went wrong on the way

The build took maybe an hour. The debugging took longer, and that's the part worth writing down.

**Cloudflare imported my registrar's parking records.** When you add a zone, Cloudflare scans for existing records and brings them along. I ended up with three A records pointing at a parking page, including a wildcard — proxied, so lookups returned Cloudflare's IPs instead of an honest failure. Every time I thought Pi-hole was broken, I was actually getting a real answer from the wrong place. Deleting them made the failures honest.

**Pi-hole v6 ignores `/etc/dnsmasq.d/` by default.** My wildcard file was correct and being silently skipped. The fix is `etc_dnsmasq_d = true` in `/etc/pihole/pihole.toml`. Also, v6 dropped `pihole restartdns` — it's `systemctl restart pihole-FTL` now.

**`pct enter` gives you a reduced PATH.** `/usr/local/bin` isn't in it, so `pihole` came back as "command not found" even though the binary was sitting right there. Ten minutes of believing the installation was broken.

**The original DNS problem wasn't what I thought.** Earlier that day I'd had the classic "connected but no pages load" symptom, which cleared the moment I turned on a commercial VPN. I assumed leftover VPN DNS settings. It was actually Tailscale and the commercial VPN fighting over DNS — two VPNs, one resolver, neither willing to lose.

**Switching containers from DHCP to static silently broke DNS.** I pinned static IPs so nothing would shift after a reboot. Everything kept working, because the proxy and its backends talk over IP. Then an update failed with "could not resolve host." Without DHCP, Proxmox falls back to the *host's* DNS configuration — and my host runs Tailscale, so it was handing containers `100.100.100.100`, an address only reachable from a machine on the tailnet. The containers weren't. Fixed per-container in Proxmox, but the lesson is that the failure was invisible until something happened to need a hostname.

## The uncomfortable part: the token sits in plaintext

Nginx Proxy Manager warns you, in red, that the credentials you paste are stored unencrypted in its database and on disk. That stopped me, and it should.

It also can't be otherwise. For the certificate to renew unattended, the process must be able to read that token and present it to the API. Any encryption scheme just relocates the problem: now there's a decryption key that has to be readable on the same box. Dedicated secret managers exist and are better, but they bottom out in a root secret stored somewhere too.

What actually limits the damage isn't secrecy, it's scope. That token can create and delete DNS records in one zone. It cannot touch my account, other domains, billing, or anything else. If the container is compromised, an attacker can issue certificates for my domain and redirect its DNS, which is bad — but bounded, and I'd notice.

Plenty of guides tell you to paste your Cloudflare Global API Key here instead. Same plaintext file, unlimited blast radius. The two choices look identical in the config and are not remotely equivalent.

One consequence I hadn't thought about until afterwards: my container backups now contain a readable credential. Worth knowing where those backups live.

## Still open

The names only resolve for devices that query Pi-hole, which right now means devices on the tailnet or ones I configured by hand. My ISP router has no DHCP DNS field, so the general fix is to put a real firewall in front of it and let that hand out DHCP — which is the next phase anyway, along with VLAN segmentation and an isolated lab network.

I also want a DMARC record on the domain. I don't send mail from it, which is exactly why nobody else should be able to either.

## What I'd tell myself a month ago

The blocker was never the hardware. It was a belief I'd adopted from forum threads and never tested, and it stopped me from finishing something that was already 80% built. The actual work was an evening. The belief cost months.
