# Copyright (c) 2022, 2024 Oracle Corporation and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl

locals {
  operator_helm_values_path = coalesce(var.operator_helm_values_path, "/home/${var.operator_user}/tf-helm-values")
  operator_helm_charts_path = coalesce(var.operator_helm_charts_path, "/home/${var.operator_user}/tf-helm-charts")
  operator_helm_chart_path  = "${local.operator_helm_charts_path}/${var.namespace}-${var.deployment_name}-${basename(var.helm_chart_path)}"

  helm_values_override_user_file     = "${var.namespace}-${var.deployment_name}-user-values-override.yaml"
  helm_values_override_template_file = "${var.namespace}-${var.deployment_name}-template-values-override.yaml"

  operator_helm_values_override_user_file_path     = join("/", [local.operator_helm_values_path, local.helm_values_override_user_file])
  operator_helm_values_override_template_file_path = join("/", [local.operator_helm_values_path, local.helm_values_override_template_file])

  local_helm_values_override_user_file_path     = join("/", [path.root, "generated", local.helm_values_override_user_file])
  local_helm_values_override_template_file_path = join("/", [path.root, "generated", local.helm_values_override_template_file])

  local_kubeconfig_path = "${path.root}/generated/kubeconfig-${var.namespace}-${var.deployment_name}"
}

resource "null_resource" "copy_chart_top_operator" {
  count = var.deploy_from_operator && var.helm_chart_path != "" ? 1 : 0

  triggers = {
    helm_chart_path = var.helm_chart_path
  }

  connection {
    bastion_host        = var.bastion_host
    bastion_user        = var.bastion_user
    bastion_private_key = var.ssh_private_key
    host                = var.operator_host
    user                = var.operator_user
    private_key         = var.ssh_private_key
    timeout             = "40m"
    type                = "ssh"
  }

  provisioner "remote-exec" {
    inline = [
      "rm -rf ${local.operator_helm_chart_path}",
      "mkdir -p ${local.operator_helm_charts_path}"
    ]
  }

  provisioner "file" {
    source      = var.helm_chart_path
    destination = local.operator_helm_chart_path
  }
}

resource "null_resource" "helm_deployment_via_operator" {
  count = var.deploy_from_operator ? 1 : 0

  triggers = {
    manifest_md5    = try(md5("${var.helm_template_values_override}-${var.helm_user_values_override}"), null)
    deployment_name = var.deployment_name
    namespace       = var.namespace
    bastion_host    = var.bastion_host
    bastion_user    = var.bastion_user
    ssh_private_key = var.ssh_private_key
    operator_host   = var.operator_host
    operator_user   = var.operator_user
  }

  connection {
    bastion_host        = self.triggers.bastion_host
    bastion_user        = self.triggers.bastion_user
    bastion_private_key = self.triggers.ssh_private_key
    host                = self.triggers.operator_host
    user                = self.triggers.operator_user
    private_key         = self.triggers.ssh_private_key
    timeout             = "40m"
    type                = "ssh"
  }

  provisioner "remote-exec" {
    inline = ["mkdir -p ${local.operator_helm_values_path}"]
  }

  provisioner "file" {
    content     = var.helm_template_values_override
    destination = local.operator_helm_values_override_template_file_path
  }

  provisioner "file" {
    content     = var.helm_user_values_override
    destination = local.operator_helm_values_override_user_file_path
  }

  provisioner "remote-exec" {
    inline = concat(
      var.pre_deployment_commands,
      [
        "if [ -s \"${local.operator_helm_values_override_user_file_path}\" ]; then",
        join(" ", concat([
          "helm upgrade --install ${var.deployment_name}",
          "%{if var.helm_chart_path != ""}${local.operator_helm_chart_path}%{else}${var.helm_chart_name} --repo ${var.helm_repository_url}%{endif}",
          "--namespace ${var.namespace} --create-namespace",
          "-f ${local.operator_helm_values_override_template_file_path}",
          "-f ${local.operator_helm_values_override_user_file_path}"
        ], var.deployment_extra_args)),
        "else",
        join(" ", concat([
          "helm upgrade --install ${var.deployment_name}",
          "%{if var.helm_chart_path != ""}${local.operator_helm_chart_path}%{else}${var.helm_chart_name} --repo ${var.helm_repository_url}%{endif}",
          "--namespace ${var.namespace} --create-namespace",
          "-f ${local.operator_helm_values_override_template_file_path}"
        ], var.deployment_extra_args)),
        "fi"
      ],
      var.post_deployment_commands
    )
  }

  provisioner "remote-exec" {
    when       = destroy
    inline     = ["helm uninstall ${self.triggers.deployment_name} --namespace ${self.triggers.namespace} --wait"]
    on_failure = continue
  }

  lifecycle {
    ignore_changes = [
      triggers["bastion_host"],
      triggers["bastion_user"],
      triggers["ssh_private_key"],
      triggers["operator_host"],
      triggers["operator_user"]
    ]
  }

  depends_on = [null_resource.copy_chart_top_operator]
}


resource "local_file" "helm_template_file" {
  count = var.deploy_from_local ? 1 : 0

  content  = var.helm_template_values_override
  filename = local.local_helm_values_override_template_file_path
}


resource "local_file" "helm_user_file" {
  count = var.deploy_from_local ? 1 : 0

  content  = var.helm_user_values_override
  filename = local.local_helm_values_override_user_file_path
}

resource "local_file" "cluster_kube_config_file" {
  count = var.deploy_from_local ? 1 : 0

  content  = var.kube_config
  filename = local.local_kubeconfig_path
}

resource "null_resource" "helm_deployment_from_local" {
  count = var.deploy_from_local ? 1 : 0

  triggers = {
    manifest_md5    = try(md5("${var.helm_template_values_override}-${var.helm_user_values_override}"), null)
    deployment_name = var.deployment_name
    namespace       = var.namespace
    kube_config     = var.kube_config
  }

  provisioner "local-exec" {
    working_dir = path.root
    command     = <<-EOT
      export KUBECONFIG=${local.local_kubeconfig_path}
      ${join("\n", var.pre_deployment_commands)}
      if [ -s "${local.local_helm_values_override_user_file_path}" ]; then
      echo ""
      echo "Terraform generated values:"
      cat "${local.local_helm_values_override_template_file_path}"
      echo ""
      echo "User provided values:"
      cat "${local.local_helm_values_override_user_file_path}"
      echo ""
      helm upgrade --install ${var.deployment_name} \
      %{if var.helm_chart_path != ""}${var.helm_chart_path}%{else}${var.helm_chart_name} --repo ${var.helm_repository_url}%{endif} \
      --namespace ${var.namespace} \
      --create-namespace --wait \
      -f ${local.local_helm_values_override_template_file_path} \
      -f ${local.local_helm_values_override_user_file_path} ${join(" ", var.deployment_extra_args)}
      else
      echo ""
      echo "Terraform generated values:"
      cat "${local.local_helm_values_override_template_file_path}"
      echo ""
      helm upgrade --install ${var.deployment_name} \
      %{if var.helm_chart_path != ""}${var.helm_chart_path}%{else}${var.helm_chart_name} --repo ${var.helm_repository_url}%{endif} \
      --namespace ${var.namespace} \
      --create-namespace --wait \
      -f ${local.local_helm_values_override_template_file_path} ${join(" ", var.deployment_extra_args)}
      fi
      ${join("\n", var.post_deployment_commands)}
      EOT
  }

  # This provisioner is not executed when the resource is commented out: https://github.com/hashicorp/terraform/issues/25073 
  provisioner "local-exec" {
    when = destroy
    environment = {
      kube_config = self.triggers.kube_config
    }
    working_dir = path.root
    command     = <<-EOT
      mkdir -p ./generated; \
      echo "$kube_config" > ./generated/kubeconfig-${self.triggers.namespace}-${self.triggers.deployment_name}-on-destroy; \
      export KUBECONFIG=./generated/kubeconfig-${self.triggers.namespace}-${self.triggers.deployment_name}-on-destroy; \
      helm uninstall ${self.triggers.deployment_name} --namespace ${self.triggers.namespace} --wait; \
      rm ./generated/kubeconfig-${self.triggers.namespace}-${self.triggers.deployment_name}-on-destroy
      EOT
    on_failure  = continue
  }
  lifecycle {
    ignore_changes = [
      triggers["local_kubeconfig_path"]
    ]
  }

  depends_on = [local_file.cluster_kube_config_file, local_file.helm_template_file, local_file.helm_user_file]
}

# module "nginx" {
#   count  = var.deploy_nginx ? 1 : 0
#   source = "./helm-module"

#   ## Connectivity details required for remote-exec provisioners. 
#   ## Are used only when the bastion and operator hosts are created.
#   bastion_host    = module.oke.bastion_public_ip
#   bastion_user    = var.bastion_user
#   operator_host   = module.oke.operator_private_ip
#   operator_user   = var.bastion_user
#   ssh_private_key = tls_private_key.stack_key.private_key_openssh

#   ## Local variables used to determine how the helm deployment will be executed (from operator via bastion OR from local/ORM runner).
#   deploy_from_operator = local.deploy_from_operator
#   deploy_from_local    = local.deploy_from_local

#   ## Helm Charts parameters
#   deployment_name           = "ingress-nginx"  # The name of the helm deployment
#   helm_chart_name           = "ingress-nginx"  # The name of the helm chart to be used (required only when usnig helm_repository_url)
#   namespace                 = "nginx" # The namespace to use for the deployment
#   helm_repository_url       = "https://kubernetes.github.io/ingress-nginx" # Fetch helm chart from this Helm repository URL
#   helm_chart_path           = "" # Can be used for deployments of helm charts available locally, as remote http tgz file or OCI repository. If present, and not empty, will override `helm_repository_url` 
#   operator_helm_values_path = local.operator_helm_values_path # Local variable used to determine where the required files are stored on operator
#   pre_deployment_commands   = [] # A list of bash commands that will be executed before the helm deployment
#   post_deployment_commands  = [] # A list of bash commands that will be executed after the helm deployment.

#   ## Helm values override file generated using Terraform template
#   helm_template_values_override = templatefile(
#     "${path.root}/helm-values-templates/nginx-values.yaml.tpl",
#     {
#       min_bw        = 100,
#       max_bw        = 100,
#       pub_lb_nsg_id = module.oke.pub_lb_nsg_id
#       state_id      = local.state_id
#     }
#   )
# }