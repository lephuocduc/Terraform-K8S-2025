resource "azurerm_resource_group" "RG" {
  name = var.RG_name
  location = "East US"
}