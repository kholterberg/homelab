# Infrastructure as code: Terraform and Ansible

Up to this point the homelab was built by hand — clicking through the Proxmox
GUI, running `pct` commands, and keeping a couple of shell scripts on the host.
It worked, but the knowledge of how it was built lived in my head and in
scattered notes. Phase 2 was about moving that knowledge into code: Terraform to
provision the machines, Ansible to configure what runs inside them, all versioned
in Git with CI checking it on every push.

The split is worth stating plainly. Terraform builds the box — it declares that a
container or VM exists, with its CPU, memory, disk and network. Ansible furnishes
it — packages, services and configuration inside the OS. Two layers, two tools.

## Keeping secrets out of a public repo

This repo is public, so the first thing I did was close the gate before anything
sensitive existed. I extended `.gitignore` to exclude Terraform state and variable
files and the Ansible vault, and only then created the provider files and the API
token. The order matters: it removes any window where a private value could be
committed — a token, or the Terraform state file, which stores values in clear
text. With the net in place first, no secret file is ever both present and
trackable. I checked it before the first commit:

    git status -uall

which listed only the safe files and never the real `terraform.tfvars`. Internal
RFC1918 addresses aren't secrets — they're already in my phase 1 write-up — so a
private repo was never the point. What matters is that tokens and state stay out,
and that is handled by `.gitignore` plus `.example` templates, whether the repo is
public or not.

## A token scoped to the job, not root

Terraform talks to the Proxmox API, and it authenticates with its own token rather
than root. I created a dedicated `terraform@pve` user with a custom role holding
only the privileges it needs:

    pveum role add Terraform -privs "VM.Allocate VM.Audit VM.Config.CPU \
      VM.Config.Disk VM.Config.Memory VM.Config.Network VM.Config.Options \
      VM.PowerMgmt Datastore.AllocateSpace Datastore.Audit Sys.Audit SDN.Use"
    pveum user add terraform@pve
    pveum aclmod / -user terraform@pve -role Terraform
    pveum user token add terraform@pve terraform -privsep 0

The reasoning is blast radius. The token lives in a gitignored `terraform.tfvars`
on my laptop; if it leaks, a narrow role means it can only touch what Terraform
manages, and it can't lock me out of my own server. Because it's a separate
identity I can revoke just that token without touching root, and its actions show
up in the logs as the terraform user rather than as me.

## Finding the role's privileges the hard way

I didn't get the role right on the first try, and that turned out to be the point.
The first `terraform apply` stopped with:

    Error: received an HTTP 403 response - Reason: Permission check failed
    (/sdn/zones/localnetwork/vmbr1, SDN.Use)

On Proxmox 9 even a plain Linux bridge sits under the SDN permission tree, so
attaching a NIC to `vmbr1` needs `SDN.Use`. I added exactly that one privilege and
nothing else, and the apply went through. Least privilege isn't something you
design perfectly up front — you grant what the system proves it needs, and let the
failures tell you the rest.

## CT 201 as code

The first machine I put under Terraform was CT 201, a disposable Debian test
container, rather than one of the services the household actually uses. The same
blast-radius thinking applies to the choice of target: `apply` destroys and
rebuilds, and the first time you run it for real against the hypervisor you want a
mistake to land on something you can throw away, not on Pi-hole or the reverse
proxy.

The resource mirrors the old container's `pct config` exactly — one core, 512 MB,
a 4 GB rootfs on local-lvm, a NIC on `vmbr1` with DHCP, nesting enabled,
unprivileged. One deliberate omission: `cpu.architecture`, which can only be set by
root, so I left it out and let it default to amd64.

What this replaces is a shell script. The script was a one-shot sequence — do this,
then this — that built the container once but described no end state and wasn't
safe to run twice. The Terraform file describes the desired state instead; the tool
works out what to change, it can be run again without harm, and it lives in Git
where it can be reviewed. The source of truth moved out of my head and into code.

## Why Terraform runs on the workstation

Terraform runs on my laptop and talks to Proxmox over the network, not on the host
itself. It's an agentless client — it doesn't need to live on the thing it manages.
That keeps the hypervisor clean, keeps the token on my workstation rather than
scattered on the server, and mirrors how this is done in practice: infrastructure
code runs from a workstation or a CI pipeline, not from inside the infrastructure.
If the host died, the ability to rebuild it shouldn't have lived on that same host.
The host created the identity; the client uses it.

## Proving it converged

After the container was built I ran `terraform plan` again:

    No changes. Your infrastructure matches the configuration.

Terraform compared my code against the container it had just created and found them
identical, so there was nothing to do. Running it again changes nothing — that's
idempotency. The same mechanism works in reverse: if the container were deleted or
drifted from the code, the next plan would show it needed rebuilding.

## Giving Ansible a way in

Ansible is the configuration layer, and it reaches the containers over SSH. I gave
it a dedicated identity on the Docker host — an `ansible` user with its own SSH key
and passwordless sudo — rather than logging in as root. Being honest about it: sudo
for a config-management user ends up being full, because it has to install packages
and edit system files. The least privilege here is at the identity level — a
dedicated, key-only, revocable, logged account — not in a narrow sudo scope. I
tested the login by hand before wiring anything up, which also meant the host key
was already trusted, so I could leave host key checking on.

## The ping that isn't a ping

The first Ansible check was:

    ansible all -m ping

which returned `pong`. This isn't an ICMP ping. It connects over SSH, finds a
Python interpreter on the target, and runs a small module that answers back. A
successful `pong` therefore proves the whole management path — authentication, a
working interpreter, module execution — not just that the host is reachable on the
network.

## Roles, and a run that changes nothing

I wrote two roles. A `base` role for things every machine should have — automatic
security updates, a timezone, a handful of baseline packages — and a `docker_host`
role for what's specific to the Docker host.

That machine already runs Docker, so before writing the role I checked what was
actually installed and codified exactly that: Docker CE from the official
repository, with the Compose v2 plugin. Running the role against the live machine
reported no changes — every task found the state it wanted already in place.

    ct100 : ok=11 changed=0 unreachable=0 failed=0

A role that changes nothing is still worth running. It verifies: a `changed=0` run
proves the live machine matches the code, and if something had drifted it would
show up and be corrected. And it reproduces: the same role against a fresh machine
would install everything and make it a working Docker host, without ever disturbing
the one that's running. It's the same lesson as Terraform's "No changes" — the code
is the source of truth, and a no-op run is the proof.

One detail worth keeping: the state-aware modules (`apt`, `copy`, `service`,
`timezone`) report `ok` or `changed` honestly, because they check first. A raw
`shell` or `command` always reports `changed`, because Ansible can't know whether an
arbitrary command changed anything. That's the reason to prefer real modules over
shell wherever possible.

## Linting and CI

The code is checked automatically on every push. Terraform is format-checked and
validated; the Ansible is linted with `ansible-lint`; and `gitleaks` scans for
secrets. None of it deploys anything — the runner can't reach the private network
and deliberately holds no credentials. CI reviews the code, it doesn't apply it.

`ansible-lint` found two things worth fixing rather than silencing. A role named
`docker-host` with a hyphen, which the convention doesn't allow — renamed to
`docker_host`. And an undeclared dependency on the `community.general` collection,
which I declared in a `requirements.yml` so it's reproducible and CI can install it.
Cleaned up, the roles pass ansible-lint's strictest `production` profile.

One warning I left in place on purpose: `apt_repository` is deprecated in favour of
`deb822_repository` and will be removed in a future ansible-core. Switching now
would write a second repository file alongside the existing one, and the removal is
still some way off, so it's noted in the code and deferred. Reading deprecation
warnings and deciding which to act on is part of the work; not every one is worth
thrashing working code for.
