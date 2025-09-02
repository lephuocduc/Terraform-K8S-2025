#Create public ip for MasterNode
resource "azurerm_public_ip" "MasterNode_public_ip" {
  name                = "MasterNode_Public_ip"
  resource_group_name = azurerm_resource_group.RG.name
  location            = azurerm_resource_group.RG.location
  allocation_method   = "Dynamic"
  sku = "Basic"
}

#Create NIC for MasterNode
resource "azurerm_network_interface" "master-nic-master" {
  name                = "Ubuntu-nic-master"
  location            = azurerm_resource_group.RG.location
  resource_group_name = azurerm_resource_group.RG.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id = azurerm_public_ip.MasterNode_public_ip.id

  }
}



# Connect the security group to the network interface
resource "azurerm_network_interface_security_group_association" "Master-NSG-NIC-Master" {
  network_interface_id      = azurerm_network_interface.master-nic-master.id
  network_security_group_id = azurerm_network_security_group.NetworkNSG.id
}

#Create Linux VM
resource "azurerm_linux_virtual_machine" "linux_VM_master_node" {
  name                = "MasterNode"
  resource_group_name = azurerm_resource_group.RG.name
  location            = azurerm_resource_group.RG.location
  size                = "Standard_B2s"
  admin_username      = "adminuser"
  admin_password = "Adminuser111"
  disable_password_authentication = false

  network_interface_ids = [
    azurerm_network_interface.master-nic-master.id
  ]

  os_disk {
    name                 = "Ubuntu-OsDisk-master"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

connection {
    type     = "ssh"
    host = self.public_ip_address
    user = self.admin_username
    password = self.admin_password
  }

#Configure the MasterNode
provisioner "remote-exec" {
  inline = [
    "sudo apt update && sudo apt -y full-upgrade",

    "sudo apt -y install apt-transport-https ca-certificates curl gpg software-properties-common vim git wget",

    # Kubernetes repo setup (modern, for v1.34)
    "sudo mkdir -p -m 755 /etc/apt/keyrings",
    "curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg",
    "echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list",

    "sudo apt update && sudo apt -y install kubelet=1.33.3-1.1 kubeadm=1.33.3-1.1 kubectl=1.33.3-1.1",
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
    # Enable systemd cgroup driver (common sed for containerd 1.x/2.x; adjust if exact version known)
    "sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml",

    "sudo systemctl restart containerd",
    "sudo systemctl enable containerd",

    # Initialize Kubernetes (with CRI socket and pod CIDR for Calico)
    "sudo kubeadm init --cri-socket=/var/run/containerd/containerd.sock --pod-network-cidr=192.168.0.0/16",

    # Set up kubeconfig for the user
    "mkdir -p $HOME/.kube",
    "sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config",
    "sudo chown $(id -u):$(id -g) $HOME/.kube/config",

    # Apply Calico networking
    "kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml",

    "alias k=kubectl",
  ]
}

depends_on = [
  azurerm_network_interface.master-nic-master,
  azurerm_network_interface_security_group_association.Master-NSG-NIC-Master,
]
}