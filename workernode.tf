#Create public ip for WorkerNode
resource "azurerm_public_ip" "WorkerNode_public_ip" {
  count = var.number_VM
  name                = "WorkerNode-Public_ip-${format("%02d", count.index)}"
  resource_group_name = azurerm_resource_group.RG.name
  location            = azurerm_resource_group.RG.location
  allocation_method   = "Static"
  sku = "Basic"
}

#Create Network Security Group and rule
resource "azurerm_network_security_group" "NetworkNSG" {
  name                = "Ubuntu-NSG"
  location            = azurerm_resource_group.RG.location
  resource_group_name = azurerm_resource_group.RG.name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

#Create NIC for WorkerNode
resource "azurerm_network_interface" "nic" {
  count = var.number_VM
  name                = "Ubuntu-nic-${format("%02d", count.index)}"
  location            = azurerm_resource_group.RG.location
  resource_group_name = azurerm_resource_group.RG.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id = element(azurerm_public_ip.WorkerNode_public_ip.*.id, count.index)
  }
}

# Connect the security group to the network interface
resource "azurerm_network_interface_security_group_association" "NSG-NIC" {
  count = var.number_VM
  network_interface_id      = element(azurerm_network_interface.nic.*.id, count.index)
  network_security_group_id = azurerm_network_security_group.NetworkNSG.id

  depends_on = [
    azurerm_network_interface.nic
  ]
}

#Create Linux VM (Worker Node) and auto join to cluster
resource "azurerm_linux_virtual_machine" "VM-WorkerNode" {
  count = var.number_VM
  name                = "WorkerNode-${format("%02d", count.index)}"
  resource_group_name = azurerm_resource_group.RG.name
  location            = azurerm_resource_group.RG.location
  size                = "Standard_D2s_v3"
  admin_username      = "adminuser"
  admin_password = "Adminuser111"
  disable_password_authentication = false

  network_interface_ids = [
    element(azurerm_network_interface.nic.*.id, count.index)
  ]

  os_disk {
    name                 = "Ubuntu-OsDisk-${format("%02d", count.index)}"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

provisioner "remote-exec" {
  connection {
    type     = "ssh"
    host = azurerm_linux_virtual_machine.linux_VM_master_node.public_ip_address
    user = azurerm_linux_virtual_machine.linux_VM_master_node.admin_username
    password = azurerm_linux_virtual_machine.linux_VM_master_node.admin_password
  }

  inline = [
    "kubeadm token create --print-join-command > /tmp/output.sh",

    "kubectl config view --raw > /tmp/configview",
  ]
}

#Configure WorkerNode and join the cluster
provisioner "remote-exec" {
  connection {
    type     = "ssh"
    host = self.public_ip_address
    user = self.admin_username
    password = self.admin_password
  }

  inline = [
  "sudo apt update && sudo apt -y full-upgrade",

  "sudo apt -y install apt-transport-https ca-certificates curl gpg software-properties-common vim git wget sshpass",

  # Kubernetes repo setup (modern, for v1.34)
  "sudo mkdir -p -m 755 /etc/apt/keyrings",
  "curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg",
  "echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list",

  "sudo apt update && sudo apt -y install kubelet kubeadm kubectl",
  "sudo apt-mark hold kubelet kubeadm kubectl",
  "sudo systemctl enable --now kubelet",

  # Disable swap
  "sudo sed -i '/ swap / s/^\\(.*\\)$/#\\1/g' /etc/fstab",
  "sudo swapoff -a",

  # Load kernel modules
  "sudo modprobe overlay",
  "sudo modprobe br_netfilter",
  "cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf",
  "overlay",
  "br_netfilter",
  "EOF",

  # Sysctl settings for Kubernetes
  "cat <<EOF | sudo tee /etc/sysctl.d/kubernetes.conf",
  "net.bridge.bridge-nf-call-iptables = 1",
  "net.bridge.bridge-nf-call-ip6tables = 1",
  "net.ipv4.ip_forward = 1",
  "EOF",
  "sudo sysctl --system",

  # Containerd installation (from Docker repo, modern key management)
  "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg",
  "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable\" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null",
  "sudo apt update && sudo apt install containerd.io -y",

  # Configure containerd
  "sudo mkdir -p /etc/containerd",
  "sudo containerd config default | sudo tee /etc/containerd/config.toml",
  # Enable systemd cgroup driver
  "sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml",

  "sudo systemctl restart containerd",
  "sudo systemctl enable containerd",

  # Join the cluster (scp and run the join script from master)
  "sshpass -p '${self.admin_password}' scp -o StrictHostKeyChecking=no adminuser@MasterNode:/tmp/output.sh /tmp/output.sh",
  "sudo sh /tmp/output.sh",
]
}

provisioner "remote-exec" {
  connection {
    type     = "ssh"
    host = azurerm_linux_virtual_machine.linux_VM_master_node.public_ip_address
    user = azurerm_linux_virtual_machine.linux_VM_master_node.admin_username
    password = azurerm_linux_virtual_machine.linux_VM_master_node.admin_password
  }

  inline = [
    "kubectl label node workernode-${format("%02d", count.index)} node-role.kubernetes.io/worker=worker"
  ]
}

depends_on = [
  azurerm_linux_virtual_machine.linux_VM_master_node,
  azurerm_network_interface_security_group_association.NSG-NIC,
  azurerm_network_interface.nic,
]

}