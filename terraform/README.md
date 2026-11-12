# Terraform — Proxmox

Infrastructure for the homelab's Proxmox node, managed with the `bpg/proxmox` provider.

## Bootstrap (one-time, on the Proxmox host)

Terraform authenticates with a dedicated, least-privilege API token rather than root. These steps create the identity once; after that Terraform runs from a workstation.

    pveum role add Terraform -privs "VM.Allocate VM.Audit VM.Config.CPU VM.Config.Disk VM.Config.Memory VM.Config.Network VM.Config.Options VM.PowerMgmt Datastore.AllocateSpace Datastore.Audit Sys.Audit SDN.Use"

    pveum user add terraform@pve

    pveum aclmod / -user terraform@pve -role Terraform

    pveum user token add terraform@pve terraform -privsep 0

The token secret is shown once. Copy it into `terraform.tfvars` — it never goes into Git. `SDN.Use` is required because on Proxmox 9 even plain Linux bridges sit under the SDN permission tree, so attaching a NIC to a bridge such as `vmbr1` needs it.

## Configuration

    cp terraform.tfvars.example terraform.tfvars

Then fill in the endpoint and token in `terraform.tfvars` (gitignored).

## Usage

    terraform init
    terraform plan
    terraform apply

## Resources

- `ct-201-labtest.tf` — disposable Debian test container (`labtest`, VM 201).
