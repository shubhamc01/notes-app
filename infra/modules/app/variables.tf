# ENGINE-RENDERED by devops-agent from catalog data — do not edit; regenerate instead.
variable "app_id" { type = string }

variable "name" { type = string }

variable "env" { type = string }

variable "region" { type = string }

variable "account_id" { type = string }

variable "iam_path" { type = string }

variable "permissions_boundary" { type = string }

variable "secret_arns" {
  type    = list(string)
  default = []
}

variable "instance_type" { type = string }

variable "instance_arch" { type = string }

variable "public_ports" {
  type    = list(number)
  default = [80]
}

variable "domain_names" {
  type    = list(string)
  default = []
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "vpc_id" { type = string }

variable "subnet_ids" { type = list(string) }
