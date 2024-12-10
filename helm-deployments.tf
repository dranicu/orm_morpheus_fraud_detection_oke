# Copyright (c) 2022, 2024 Oracle Corporation and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl

locals {
  deploy_from_operator = var.create_operator_and_bastion
  deploy_from_local    = alltrue([!local.deploy_from_operator, var.control_plane_is_public])
}

data "oci_containerengine_cluster_kube_config" "kube_config" {
  count = local.deploy_from_local ? 1 : 0

  cluster_id = module.oke.cluster_id
  endpoint   = "PUBLIC_ENDPOINT"
}

module "fraud-detection-app" {
  source = "./helm-module"

  bastion_host    = module.oke.bastion_public_ip
  bastion_user    = var.bastion_user
  operator_host   = module.oke.operator_private_ip
  operator_user   = var.bastion_user
  ssh_private_key = tls_private_key.stack_key.private_key_openssh

  deploy_from_operator = local.deploy_from_operator
  deploy_from_local    = local.deploy_from_local

  deployment_name     = "fraud-detection-app"
  helm_chart_name     = "fraud-detection-app"
  namespace           = "default"
  helm_repository_url = ""
  helm_chart_path     = "./oci"

  pre_deployment_commands  = []
  post_deployment_commands = []

  # this override the values.yaml file from chart
  # this is a file present in helm-values-templates folder
  helm_template_values_override = templatefile(
    "${path.root}/helm-values-templates/value_triton.yaml", {
    }
  )

  # this is a file user uploads from ORM 
  #helm_user_values_override = try(base64decode(var.nginx_user_values_override), var.nginx_user_values_override)
  # helm_user_values_override = try(base64decode(var.dcgm_user_values_override), var.dcgm_user_values_override)

helm_user_values_override     = ""

  kube_config = one(data.oci_containerengine_cluster_kube_config.kube_config.*.content)
  depends_on  = [module.oke]
}
