resource "azurerm_virtual_network" "vnet" {
  name                = "vNet1"
  location            = azurerm_resource_group.RG.location
  address_space       = ["10.0.0.0/16"]
  resource_group_name = azurerm_resource_group.RG.name
}

#Create subnet
resource "azurerm_subnet" "subnet" {
  name                 = "default"
  virtual_network_name = azurerm_virtual_network.vnet.name
  resource_group_name  = azurerm_resource_group.RG.name
  address_prefixes     = ["10.0.10.0/24"]
}   