# Calculate subnet CIDRs based on VNet address space
locals {
  # Split the address space
  vnet_ip_base        = split("/", var.vnet_address_space)[0]
  octets              = split(".", local.vnet_ip_base)
  base_ip             = "${local.octets[0]}.${local.octets[1]}.${local.octets[2]}"
  bastion_subnet_cidr = "${local.base_ip}.64/26"
  jumpbox_subnet_cidr = "${local.base_ip}.128/28"
}
