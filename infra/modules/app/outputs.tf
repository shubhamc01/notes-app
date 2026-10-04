# ENGINE-RENDERED by devops-agent from catalog data — do not edit; regenerate instead.
output "host_instance_id" {
  value = aws_instance.host.id
}

output "host_ip" {
  value = aws_eip.host.public_ip
}

output "host_url" {
  value = length(var.domain_names) > 0 ? "https://${var.domain_names[0]}" : "http://${aws_eip.host.public_dns}"
}

output "site_domains" {
  value = join(",", var.domain_names)
}
