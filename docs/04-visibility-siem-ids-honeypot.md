# 04 – Visibility: a SIEM, an IDS, and a honeypot

## TL;DR

Phase 3 was about seeing what happens on the network instead of hoping nothing does. I put a Suricata IDS on the OPNsense firewall, stood up a Wazuh SIEM that collects from every host in the lab, and planted a Cowrie honeypot inside the isolated lab network. Then I wrote my own detection rules and tuned the noise down to something a human would actually read.

Two lessons ran through the whole phase. The first is that getting logs *in* is not the same as detecting anything — the data can arrive, parse perfectly, and still raise no alarm, because no rule cares about it. The second is that the scariest failure of the project, a server that looked dead three nights running, was never frozen at all: it was a known network-driver bug, and the logs had been saying so the whole time.

## The shape of it

Everything funnels into one place. Each host runs a Wazuh agent that ships its logs to the manager; OPNsense doubles as the IDS sensor; the honeypot sits in the lab segment where only an intruder would ever touch it.

```
                         Wazuh manager (SIEM)  192.168.1.106
                                   ▲
        ┌──────────┬───────────┬───┴────┬─────────────┬───────────┐
     agent 001  agent 002   agent 003 agent 004    agent 005   agent 006
      docker     jellyfin    pi-hole   nginx-pm     OPNsense      cowrie
        │          │           │         │             │            │
   home network 192.168.1.0/24  ─────────┘        Suricata IDS   honeypot
                                                   (LAN sensor)  10.10.10.0/24
                                                        │          (lab net)
                                                   OPNsense router ── vmbr1
```

Agents 001–004 are the household service containers, 005 is the firewall itself, and 006 is the honeypot. Suricata watches the lab's traffic from inside OPNsense; Cowrie lives one hop further in, on the segment built back in phase 2.

## Suricata: an IDS where the traffic already passes

The IDS runs on the OPNsense LAN interface, which is the chokepoint between the lab and everything else. A sensor only ever sees traffic that routes past where it sits, so putting it at the firewall means all of the lab's north–south traffic crosses it without a separate tap. It also sees that traffic *before* NAT, with the real `10.10.10.x` source addresses, so an alert can point at a machine rather than at the firewall's outside address. The blind spot is east–west traffic between two machines on the same segment — that gets switched on the bridge and never reaches the firewall. That matters for later phases, not this one.

I ran it as an IDS, not an IPS, on purpose. In detect-only mode a false positive is just a harmless noise alert; inline, the same false positive is a dropped packet that can cut real lab traffic. You build trust in the rules first and move to blocking later.

Two things bit me that are worth writing down. Downloading a ruleset isn't the same as enabling it — OPNsense marks rules for download, fetches them to disk, and only alerts once they're switched on, which is why my first tests were silent with the log cheerfully reporting "no rules were loaded." And I started by hand-enabling 763 individual rules, which bloats the config; switching to a single policy ("these rulesets → alert") is the declarative version and the one worth keeping.

The subtle one was direction. The ET SCAN rules are written `EXTERNAL_NET → HOME_NET` — they're built for threats arriving from outside. With `HOME_NET` set to the whole lab subnet, a scan *from* a lab machine was internal→internal, so nothing fired. It was silent by design, not broken. I only confirmed the pipeline worked by shrinking `HOME_NET` to the gateway for a test (and briefly fat-fingering it to `.0`, the network address nobody lives at, before `.1`), then restored it afterwards.

## The SIEM, built as code

The Wazuh manager is a full VM rather than a cloned container, provisioned with Terraform and a cloud-init file that injects the user, SSH key, hostname and network on first boot. That's the same "infrastructure as code" posture as phase 2, one layer up: the machine's identity comes from config, not from clicking through an installer.

The Terraform role for it grew by exactly three privileges, each one discovered by a `403` and added on its own — writing the image to the datastore, setting the machine type, and reading the guest-agent interfaces once the agent was enabled. Least privilege isn't something you design perfectly up front; you grant what the system proves it needs and let the failures name the rest. Same lesson as the `SDN.Use` privilege in phase 2, learned again.

## Agents everywhere, from one role

Every host needed an agent, so I wrote a lean Ansible role rather than pulling in the official `wazuh.wazuh` collection. The collection is large and handles managers, clusters and a dozen platforms; to roll out an agent that's a lot of code I'd neither use nor understand. My own role does exactly the needed steps — repo and signed key, the pinned agent, point it at the manager, enrol, start — and I own every line of it.

The agent is pinned to the manager's version (`4.14.10`), not "latest". Agent and manager speak a protocol that can shift between releases, and an agent ahead of its manager can refuse to enrol. Pinning makes the rollout deterministic.

The nicest proof that the role is declarative came from one run across the fleet: the host that already had the agent reported `changed=0`, while the three fresh containers reported `changed=6`. Same role, same run, each host converging to the same end state from wherever it started. That's idempotence you can see.

One chicken-and-egg detail: Ansible logs in as a dedicated `ansible` user, but it can't *create* that user on a host it can't log into yet. The control identity has to be planted once, out of band — here with `pct exec` from the Proxmox host, running as root without SSH. After that, everything is code. Something always has to place the first key.

## Wiring Suricata into Wazuh

OPNsense sends its Suricata events to the manager through the community `os-wazuh-agent` plugin rather than over syslog. Syslog wraps the JSON in a header the Wazuh decoders choke on, and that's where a lot of people get stuck writing custom decoders. The agent reads `eve.json` directly and ships clean JSON, which the built-in decoder and Suricata rules parse with nothing extra. OPNsense enrols as a normal agent and gets file-integrity monitoring and config assessment for free.

The verification had a lesson folded into it. My first scan, run from the Proxmox host, did nothing — the host sits on the home network and has no route into `10.10.10.0/24`, so the packets never reached the sensor. A sensor sees only what passes it. Running the same `nmap` from a lab container put the traffic across the OPNsense LAN interface, Suricata fired ET SCAN, and the alert surfaced in Wazuh as rule 86601 with the full event unpacked — proof of the whole chain from sensor to SIEM.

## A honeypot, and the gap between ingestion and detection

Cowrie is an SSH honeypot: it answers on port 2222, emulates a shell, and logs every keystroke to JSON. I gave it its own Terraform-provisioned container in the lab segment, where no legitimate user has any reason to go — which is the whole point. Every interaction with it is suspicious by definition.

What it emulates is a convincing lie. Logging in and running `cat /etc/shadow` returns a planted file; `uname` reports a different kernel than the real container; the hostname and the users in `/etc/passwd` are stage dressing. A `wget` of a payload is the best part: Cowrie never runs it — it captures the file, hashes it (SHA-256) and files it in a quarantine directory, so you get a sample of the attacker's tooling without executing it. The intruder thinks they own a server; in reality every move is recorded.

Then came the central lesson of the phase. The agent read `cowrie.json`, shipped it, and the manager's JSON decoder unpacked every field perfectly — I watched it do so in `wazuh-logtest`. And nothing alerted. Unlike Suricata, Wazuh ships no Cowrie rules, so the decoded event matched nothing and raised no alarm. The data had *arrived and been understood* — ingestion — but a Wazuh alert only exists when a *rule* matches an event and gives it a level. `wazuh-logtest` made it concrete: decoding succeeded, rule-matching returned nothing. The gap was in the rule layer, not the pipeline.

So I wrote the rules. A silent parent rule matches any Cowrie event but never alerts on its own; child rules hang off it with `if_sid` and look at the specific event id, each mapped to a severity and a MITRE ATT&CK technique:

| Rule | Event | Level | ATT&CK |
|---|---|---|---|
| 100101 | session connect | 3 | T1595 Active Scanning |
| 100102 | login failed | 5 | T1110 Brute Force |
| 100103 | login success | 10 | T1078 Valid Accounts |
| 100104 | command run | 8 | T1059 Command Execution |
| 100105 | file download | 12 | T1105 Ingress Tool Transfer |

The parent means Wazuh never tests six child rules against unrelated logs, and there's one place that defines "what is a Cowrie event". Custom rules live under `/var/ossec/etc/rules/` so an upgrade never overwrites them.

I verified it the only honest way — by attacking the honeypot from a lab machine. A login as `root`, a few commands, a payload download, and a logout all surfaced in the alert log as levelled, ATT&CK-tagged alerts: one connect, one successful login, four commands, one malware download. The detection I designed caught the attack I ran.

## Tuning: a noisy SIEM is an ignored SIEM

With everything reporting, the manager was loud. The temptation is to guess at what's noisy; instead I counted, ranking the rules by how often they fired. The point of starting with frequency is that false positives collect at the top — you tune where the volume is, not where the severity is, because the high-severity alerts are the ones you want to keep.

One rule was three-quarters of all alerts: a rootcheck "possible hidden file" firing on `/dev/.lxc/proc/...`. Those paths are the container runtime's own bind-mounts — `lxcfs` plumbing, not a rootkit. Rootcheck, a legacy module, reads an LXC artifact as an intrusion. I silenced exactly that false positive with a single rule (match the path, set level 0) and left rootcheck otherwise looking for real signs.

The counterpoint matters as much as the fix: not all volume is noise. Login sessions, `sudo` to root and successful SSH logins were all frequent too — but that's *my own* admin activity, and it's the audit trail you most want during an incident. You don't suppress those; you filter the view. Tuning is telling a false positive apart from something legitimate-but-frequent, not minimising the number of alerts.

The last source was a leftover from phase 2. The firewall log was full of blocked broadcast and multicast — but none of it reached the SIEM, so I found it in OPNsense's own log. Every entry came from the *home* network (mDNS, IGMP, directed broadcast) hitting the firewall's outside interface, which sits on the home LAN. The segmentation was correctly refusing it; it was just logging every drop. A block-without-logging rule for the broadcast and multicast ranges kept the security outcome and gave back a readable log — only meaningful traffic left.

## The incident: a server that looked dead and never was

Three evenings running, the host went unreachable — Proxmox GUI, SSH and Jellyfin all timing out — while the router answered with zero loss. It looked like a hard freeze, and I spent three nights treating it as one.

I eliminated causes one at a time, with evidence, even the wrong ones. A commercial VPN: ruled out, no loss to the router. Memory pressure and the ZFS ARC: capped the ARC to 4 GB, correct hygiene but not the cause, and no out-of-memory events in the log. Dying hardware: a 20 GB `memtester` pass and the kernel's EDAC counters both came back clean, which cleared the RAM.

The answer was in the log at the end of each "frozen" session: `Power key pressed short → Powering off → System is powering down`. A short press of the power button had triggered an orderly ACPI shutdown — which a genuinely frozen CPU cannot do. The machine was alive the whole time; only the network was dead. Just before each "death" the log showed `e1000e ... Detected Hardware Unit Hang`: the onboard Intel NIC's transmit queue locking up. Everything on the host rides that one NIC, so losing it looks exactly like a freeze from the outside, while the router — a different device — keeps answering.

It's a known e1000e bug. The fix was to disable the hardware offloads that trigger it (`ethtool -K nic0 gso off gro off tso off`) and make it stick with a small script in `/etc/network/if-up.d/`. No new parts, a software change, and the host has been up continuously since.

The method is the lesson. *Absence* of logs was evidence — no OOM, no panic, no memory errors ruled out whole categories — and the one signature that was present pointed at the network layer, not the compute layer. A host that's unreachable over the network is not necessarily a frozen host; a hung NIC looks identical from the outside, and only the logs tell them apart. The ARC cap and the memory monitoring weren't wasted either: they're what made the NIC conclusion airtight.

## What's not done yet

- **Rotate the Wazuh admin credentials** the installer generated. Hygiene, not urgent.
- **Document the appliance-state config.** The OPNsense pieces — the Suricata plugin settings and the broadcast/multicast rule — live in the firewall's UI, not in Git. The firewall config carries secrets, so it stays out of the public repo until I have a clean way to handle them; for now it's written down here.
- **Disable rootcheck on the containers at the source**, rather than suppressing its one false positive at the SIEM. The legacy module earns its keep on a real host, less so on a container fleet.
- **Modernise `apt_repository` → `deb822_repository`** in the roles — deferred deprecation, same call as phase 2.

## What I'd tell myself

Ingestion is the easy half. Pointing agents at a manager and watching logs pour in feels like progress, but a SIEM that collects everything and detects nothing is just an expensive log bucket. Detection is a decision you have to write down — this event, at this severity, means this — and until you do, the data is only waiting to be ignored.

And when something looks catastrophic, read before you spend. The three "freezes" would have had me buying a power supply and memory I couldn't afford, chasing a fault that didn't exist. The logs turned a mysterious hardware death into a known driver bug with a free fix. The absence of an error can be the clue that solves it.
