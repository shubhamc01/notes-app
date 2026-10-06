data "aws_ssm_parameter" "host_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${var.instance_arch}"
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.name}/${var.env}"
  retention_in_days = var.log_retention_days
}

resource "aws_instance" "host" {
  ami                         = data.aws_ssm_parameter.host_ami.value
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.host.id]
  iam_instance_profile        = aws_iam_instance_profile.host.name
  associate_public_ip_address = true
  user_data                   = local.host_user_data
  user_data_replace_on_change = true

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required"
  }
}
