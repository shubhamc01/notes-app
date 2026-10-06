# ENGINE-RENDERED by devops-agent from catalog data — do not edit; regenerate instead.
# ENGINE-RENDERED (devops-agent): network exposure and instance permissions for the compute host.
# Ingress: only the public web ports; no SSH (administration goes through SSM).
resource "aws_security_group" "host" {
  name_prefix = "${var.name}-${var.env}-host-"
  description = "${var.name} ${var.env} compute host"
  vpc_id      = local.vpc_id

  dynamic "ingress" {
    for_each = var.public_ports
    content {
      description = "public web"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    description = "outbound (registry, package mirrors, AWS APIs)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role" "host" {
  name                 = "${var.name}-${var.env}-host"
  path                 = var.iam_path
  permissions_boundary = var.permissions_boundary
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "host_ssm" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "host_ecr_read" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy" "host_runtime" {
  name = "runtime"
  role = aws_iam_role.host.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
          Resource = "arn:aws:logs:${var.region}:${var.account_id}:log-group:/${var.name}/${var.env}:*"
        },
        {
          Effect   = "Allow"
          Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
          Resource = "arn:aws:ssm:${var.region}:${var.account_id}:parameter/${var.name}/${var.env}/*"
        },
      ],
      length(local.secret_arns) > 0 ? [{
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = local.secret_arns
      }] : [],
      length(local.artifact_read_arns) > 0 ? [{
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = local.artifact_read_arns
      }] : []
    )
  })
}

resource "aws_iam_instance_profile" "host" {
  name = "${var.name}-${var.env}-host"
  path = var.iam_path
  role = aws_iam_role.host.name
}

# A stable public address (survives stop/start and instance replacement) for DNS and clients.
resource "aws_eip" "host" {
  domain   = "vpc"
  instance = aws_instance.host.id
}
