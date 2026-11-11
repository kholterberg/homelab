variable "proxmox_endpoint" {
  type        = string
  description = "Proxmox VE API-endpoint, t.ex. https://192.168.1.150:8006/"
}

variable "proxmox_api_token" {
  type        = string
  description = "API-token på formen USER@REALM!TOKENID=SECRET"
  sensitive   = true
}
