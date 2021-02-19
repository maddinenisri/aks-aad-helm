# aks-aad-helm

- Provision infrastrcture
```sh
  az login
  terraform init
  terraform plan
  terraform apply
```

- Browse kube dashboard
```sh
az aks browse --name dev-aks -g demo-rg
```

- Get token
```sh
  kubectl config view
  # Copy token related clusterUser_demo-rg_dev-aks > user > auth-provider > config > access-token of this cluster
```
