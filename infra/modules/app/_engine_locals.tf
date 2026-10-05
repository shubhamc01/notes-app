# ENGINE-RENDERED by devops-agent from catalog data — do not edit; regenerate instead.
locals {
  host_user_data = templatefile("${path.module}/_engine_host_bootstrap.sh.tftpl", {
    compose_version = "v5.6.0"
    compose_arch    = var.instance_arch == "arm64" ? "aarch64" : "x86_64"
  })
  vpc_id      = var.vpc_id
  subnet_ids  = var.subnet_ids
  secret_arns = var.secret_arns
}
