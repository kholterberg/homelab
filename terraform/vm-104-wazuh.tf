

resource "proxmox_virtual_environment_vm" "wazuh" {
  name      = "wazuh"
  node_name = "homelab"
  vm_id     = 104
  tags      = ["terraform", "fas3", "siem"]

  cpu {
    cores = 4
    type  = "host"
  }

  memory {
    dedicated = 6144
  }

  disk {
    datastore_id = "media"
    import_from  = "local:import/jammy-server-cloudimg-amd64.qcow2"
    interface    = "scsi0"
    size         = 50
  }

  network_device {
    bridge = "vmbr0"   # hemnäts-bryggan — bekräfta att dina CT:er sitter på vmbr0
  }

  agent {
    enabled = false    # guest-agent finns inte i cloud-image; lägger till senare
  }

  initialization {
    datastore_id = "media"

    ip_config {
      ipv4 {
        address = "192.168.1.106/24"
        gateway = "192.168.1.1"
      }
    }

    dns {
      servers = ["192.168.1.104", "1.1.1.1"]
    }

    user_account {
      username = "kalle"
      keys     = [trimspace(file("~/.ssh/id_ed25519.pub"))]
    }
  }

  operating_system {
    type = "l26"
  }
}
