# homelab

Setup notes and write-ups from my home lab — a Proxmox host I use to
learn infrastructure and security engineering.

This repo is mostly documentation right now. As the environment moves
toward infrastructure-as-code, the Ansible and Terraform that builds it
will live here too.

## Current setup

**Host:** Proxmox VE on a single node, LXC containers for each service.

| Service | What it does |
|---|---|
| Docker host | Runs containerised services |
| Jellyfin | Media server |
| Nginx Proxy Manager | Reverse proxy, TLS termination |
| Pi-hole | DNS and ad blocking, split DNS for internal names |

Internal services are reachable over HTTPS on a private domain using a
Let's Encrypt wildcard certificate issued via DNS-01. Nothing is exposed
to the internet; off-LAN access goes over Tailscale.

## Write-ups

- [Wildcard HTTPS at home, behind an ISP router I thought was a dead end](docs/01-reverse-proxy-dns01.md)
- [OPNsense segmentation](docs/02-opnsense-segmentation.md)
## Roadmap

- [x] Reverse proxy, internal DNS, wildcard TLS
- [x] OPNsense as router, VLAN segmentation, isolated lab network
- [ ] Infrastructure as code: Ansible and Terraform
- [ ] Visibility: SIEM, IDS, honeypot
- [ ] Active Directory lab
- [ ] Detection engineering against my own attacks
