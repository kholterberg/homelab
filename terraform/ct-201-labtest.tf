# ct-201-labtest.tf — disponibel Debian-testcontainer, hanterad av Terraform.
# Ersätter det gamla ct-201-labtest.sh-skriptet.

resource "proxmox_virtual_environment_container" "labtest" {
  node_name     = "homelab"
  vm_id         = 201
  description   = "Managed by Terraform"
  unprivileged  = true
  started       = false # speglar att den normalt är stoppad
  start_on_boot = false

  features {
    nesting = true
  }

  cpu {
    cores = 1
    # architecture utelämnas med flit: den kan bara sättas av root,
    # och default blir ändå amd64 — så vi slipper ge tokenen mer makt.
  }

  memory {
    dedicated = 512
    swap      = 0
  }

  disk {
    datastore_id = "local-lvm"
    size         = 4
  }

  operating_system {
    template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
    type             = "debian"
  }

  network_interface {
    name     = "eth0"
    bridge   = "vmbr1"
    firewall = false
    # ingen mac_address = Proxmox delar ut en ny, containern får en ny DHCP-lease
  }

  initialization {
    hostname = "labtest"

    dns {
      domain  = "lab.internal"
      servers = ["10.10.10.1"]
    }

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }
}
