terraform {
  required_version = ">= 0.12"
}

provider "azurerm" {
  version = ">= 2.26"
  features {}
}

provider "azuread" {
  version = ">= 1.0.0"
}

data "azuread_group" "aks" {
  display_name = "dev"
}

data "azurerm_subscription" "current" {}

# Create cluster resource group
resource "azurerm_resource_group" "demo" {
  name     = "demo-rg"
  location = "eastus"
}

resource "azurerm_virtual_network" "demo" {
  name                = "dev-network"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  address_space       = ["10.1.0.0/16"]
}

resource "azurerm_subnet" "demo" {
  name                 = "dev-akssubnet"
  virtual_network_name = azurerm_virtual_network.demo.name
  resource_group_name  = azurerm_resource_group.demo.name
  address_prefixes     = ["10.1.0.0/22"]
}

resource "azurerm_kubernetes_cluster" "aks" {
  lifecycle {
    ignore_changes = [
      default_node_pool[0].node_count
    ]
  }

  name                            = "dev-aks"
  location                        = azurerm_resource_group.demo.location
  resource_group_name             = azurerm_resource_group.demo.name
  dns_prefix                      = "devaks"
  kubernetes_version              = "1.18.14"
  node_resource_group             = "dev-aks-worker"
  # private_cluster_enabled         = var.private_cluster
  # sku_tier                        = var.sla_sku
  # api_server_authorized_ip_ranges = var.api_auth_ips

  default_node_pool {
    name                  = "system"
    orchestrator_version  = "1.18.14"
    node_count            = 2
    vm_size               = "Standard_D2_v2"
    type                  = "VirtualMachineScaleSets"
    availability_zones    = ["1", "2", "3"]
    max_pods              = 250
    os_disk_size_gb       = 128
    vnet_subnet_id        = azurerm_subnet.demo.id
    # node_labels           = var.default_node_pool.labels
    # node_taints           = var.default_node_pool.taints
    enable_auto_scaling   = true
    min_count             = 1
    max_count             = 3
    enable_node_public_ip = false
  }

  identity {
    type = "SystemAssigned"
  }

  role_based_access_control {
    enabled = true

    azure_active_directory {
      managed = true
      admin_group_object_ids = [
        data.azuread_group.aks.object_id
      ]
    }
  }

  addon_profile {
    oms_agent {
      enabled                    = true
      log_analytics_workspace_id = azurerm_log_analytics_workspace.analytics_workspace.id
    }
    kube_dashboard {
      enabled = true
    }
    azure_policy {
      enabled = false
    }
  }

  network_profile {
    load_balancer_sku  = "standard"
    outbound_type      = "loadBalancer"
    network_plugin     = "azure"
    network_policy     = "calico"
    # dns_service_ip     = "10.1.0.10"
    # docker_bridge_cidr = "172.17.0.1/16"
    # service_cidr       = "10.1.0.0/22"
  }
}

resource "azurerm_log_analytics_workspace" "analytics_workspace" {
  name                = "demo-analytics"
  location            = "eastus"
  resource_group_name = azurerm_resource_group.demo.name
  sku                 = "PerGB2018"
}

# resource "azurerm_kubernetes_cluster_node_pool" "aks" {
#   lifecycle {
#     ignore_changes = [
#       node_count
#     ]
#   }

#   for_each = var.additional_node_pools

#   kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
#   name                  = each.value.node_os == "Windows" ? substr(each.key, 0, 6) : substr(each.key, 0, 12)
#   orchestrator_version  = var.kubernetes_version
#   node_count            = each.value.node_count
#   vm_size               = each.value.vm_size
#   availability_zones    = each.value.zones
#   max_pods              = 250
#   os_disk_size_gb       = 128
#   os_type               = each.value.node_os
#   vnet_subnet_id        = var.vnet_subnet_id
#   node_labels           = each.value.labels
#   node_taints           = each.value.taints
#   enable_auto_scaling   = each.value.cluster_auto_scaling
#   min_count             = each.value.cluster_auto_scaling_min_count
#   max_count             = each.value.cluster_auto_scaling_max_count
#   enable_node_public_ip = false
# }

resource "azurerm_role_assignment" "aks" {
  scope                = azurerm_kubernetes_cluster.aks.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_kubernetes_cluster.aks.addon_profile[0].oms_agent[0].oms_agent_identity[0].object_id
}

resource "azurerm_role_assignment" "aks_subnet" {
  scope                = azurerm_subnet.demo.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks.identity[0].principal_id
}

# resource "azurerm_role_assignment" "aks_acr" {
#   scope                = var.container_registry_id
#   role_definition_name = "AcrPull"
#   principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
# }

provider "kubernetes" {
  load_config_file       = false
  host                   = format("https://%s:443", azurerm_kubernetes_cluster.aks.private_fqdn)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_admin_config[0].cluster_ca_certificate)
  client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_admin_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_admin_config[0].client_key)
}

provider "helm" {
  kubernetes {
    host                   = "${azurerm_kubernetes_cluster.aks.kube_admin_config.0.host}"
    username               = "${azurerm_kubernetes_cluster.aks.kube_admin_config.0.username}"
    password               = "${azurerm_kubernetes_cluster.aks.kube_admin_config.0.password}"
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_admin_config[0].cluster_ca_certificate)
    client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_admin_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_admin_config[0].client_key)
  }
}

resource "helm_release" "example" {
  # kube_config = azurerm_kubernetes_cluster.aks.kube_config_raw
  name  = "redis"
  chart = "https://charts.bitnami.com/bitnami/redis-10.7.16.tgz"
}


# resource "helm_release" "ingress" {
#     name      = "ingress"
#     chart     = "stable/nginx-ingress"
#     repository = "https://charts.helm.sh/stable"
#     set {
#         name  = "rbac.create"
#         value = "true"
#     }
# }
