# Terraform — Proxmox

Infrastructure for the homelab's Proxmox node, managed with the `bpg/proxmox` provider.

## Bootstrap (one-time, on the Proxmox host)

Terraform authenticates with a dedicated, least-privilege API token rather than root. These steps create the identity once; after that Terraform runs from a workstation.

    pveum role add Terraform -privs "VM.Allocate VM.Audit VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.PowerMgmt Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit Sys.Audit SDN.Use"

    pveum user add terraform@pve

    pveum aclmod / -user terraform@pve -role Terraform

    pveum user token add terraform@pve terraform -privsep 0

The token secret is shown once. Copy it into `terraform.tfvars` — it never goes into Git. `SDN.Use` is required because on Proxmox 9 even plain Linux bridges sit under the SDN permission tree, so attaching a NIC to a bridge such as `vmbr1` needs it. `Datastore.AllocateTemplate` lets Terraform write downloaded images and templates to a datastore (distinct from `Datastore.AllocateSpace`, which covers VM and container disks), and `VM.Config.HWType` is required to set hardware options such as the SCSI controller type. Both were added empirically — each surfaced as an HTTP 403 naming the exact missing privilege during the first VM apply.

## Cloud images (manual pre-stage)

VMs built from a cloud image (such as the Wazuh VM) import their disk from a base image that must already exist on the Proxmox node. Terraform does not download it: the API token receives an unresolved HTTP 403 on the `download-url` endpoint even with `Datastore.AllocateTemplate`, so the image is staged once as root instead.

    pvesh create /nodes/homelab/storage/local/download-url \
      --content iso \
      --filename jammy-server-cloudimg-amd64.img \
      --url https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img

Proxmox will not import a disk from the `iso` content type, and its import scanner ignores the `.img` extension. Move the file into the `import` content directory and rename it to `.qcow2` (its real format) so it is recognised:

    mkdir -p /var/lib/vz/import
    mv /var/lib/vz/template/iso/jammy-server-cloudimg-amd64.img \
       /var/lib/vz/import/jammy-server-cloudimg-amd64.qcow2

Verify it is listed, then reference the resulting volume ID in the VM's `import_from`:

    pvesm list local --content import
    # local:import/jammy-server-cloudimg-amd64.qcow2

## Configuration

    cp terraform.tfvars.example terraform.tfvars

Then fill in the endpoint and token in `terraform.tfvars` (gitignored).

## Usage

    terraform init
    terraform plan
    terraform apply

## Resources

- `ct-201-labtest.tf` — disposable Debian test container (`labtest`, VM 201).
- `vm-104-wazuh.tf` — Wazuh SIEM VM (`wazuh`, VM 104), built from an Ubuntu 22.04 cloud image via cloud-init.
