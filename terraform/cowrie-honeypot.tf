# cowrie-honeypot.tf — Cowrie SSH/Telnet-honeypot i labbnätet (vmbr1).
# Disponibel + isolerad: kapas den är skadan instängd i labbet.
# Emulerat skal (sandlåda), unprivileged container.

resource "proxmox_virtual_environment_container" "cowrie" {
  node_name     = "homelab"
  vm_id         = 202
  description   = "Managed by Terraform"
  tags          = ["terraform", "fas3", "honeypot"]
  unprivileged  = true
  started       = true
  start_on_boot = true

  features {
    nesting = true # Debian 13/systemd 257 vill ha det
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 1024
    swap      = 0
  }

  disk {
    datastore_id = "local-lvm"
    size         = 8
  }

  operating_system {
    template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
    type             = "debian"
  }

  network_interface {
    name     = "eth0"
    bridge   = "vmbr1"
    firewall = false
  }

  initialization {
    hostname = "cowrie"

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
