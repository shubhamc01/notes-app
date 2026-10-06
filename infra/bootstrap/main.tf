# ENGINE-RENDERED by devops-agent from catalog data — do not edit; regenerate instead.

# Terraform state bucket for this ACCOUNT (shared by every app in it; adopted, never re-created,
# when it exists — infra-arch §6.3). Applied once with local state, then state is migrated into it.
resource "aws_s3_bucket" "state" {
  bucket = "tfstate-407493720885-ap-south-1"
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "DenyBucketDeletion"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:DeleteBucket"
        Resource  = aws_s3_bucket.state.arn
      },
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.state]
}

data "aws_iam_openid_connect_provider" "ci" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_ecr_repository" "app" {
  name                 = "notes-app-f308"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false
  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep the last 50 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 50 }
      action       = { type = "expire" }
    }]
  })
}

resource "aws_iam_policy" "boundary_dev" {
  name   = "notes-app-f308-dev-boundary"
  policy = <<-POLICY
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "NotAction": [
            "iam:*",
            "organizations:*",
            "account:*"
          ],
          "Resource": [
            "*"
          ]
        }
      ]
    }
  POLICY
}

resource "aws_iam_role" "deploy_dev" {
  name               = "notes-app-f308-dev-deploy"
  assume_role_policy = <<-TRUST
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": {
            "Federated": "${data.aws_iam_openid_connect_provider.ci.arn}"
          },
          "Action": "sts:AssumeRoleWithWebIdentity",
          "Condition": {
            "StringEquals": {
              "token.actions.githubusercontent.com:sub": [
                "repo:shubhamc01@327102562/notes-app@1404437167:environment:dev"
              ]
            }
          }
        }
      ]
    }
  TRUST
}

resource "aws_iam_role_policy" "deploy_dev" {
  name   = "permissions"
  role   = aws_iam_role.deploy_dev.id
  policy = <<-POLICY
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Action": [
            "ecr:GetAuthorizationToken"
          ],
          "Resource": [
            "*"
          ]
        },
        {
          "Effect": "Allow",
          "Action": [
            "ecr:BatchCheckLayerAvailability",
            "ecr:InitiateLayerUpload",
            "ecr:UploadLayerPart",
            "ecr:CompleteLayerUpload",
            "ecr:PutImage",
            "ecr:BatchGetImage",
            "ecr:GetDownloadUrlForLayer",
            "ecr:DescribeImages"
          ],
          "Resource": [
            "arn:aws:ecr:ap-south-1:407493720885:repository/notes-app-f308"
          ]
        },
        {
          "Effect": "Allow",
          "Action": [
            "ssm:SendCommand"
          ],
          "Resource": [
            "arn:aws:ssm:ap-south-1::document/AWS-RunShellScript"
          ]
        },
        {
          "Effect": "Allow",
          "Action": [
            "ssm:SendCommand"
          ],
          "Resource": [
            "arn:aws:ec2:ap-south-1:407493720885:instance/*"
          ],
          "Condition": {
            "StringEquals": {
              "ssm:resourceTag/app_id": "notes-app-f308",
              "ssm:resourceTag/env": "dev"
            }
          }
        },
        {
          "Effect": "Allow",
          "Action": [
            "ssm:GetCommandInvocation",
            "ssm:ListCommandInvocations"
          ],
          "Resource": [
            "*"
          ]
        }
      ]
    }
  POLICY
}

resource "aws_iam_role" "infra_apply_dev" {
  name               = "notes-app-f308-dev-infra-apply"
  assume_role_policy = <<-TRUST
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": {
            "Federated": "${data.aws_iam_openid_connect_provider.ci.arn}"
          },
          "Action": "sts:AssumeRoleWithWebIdentity",
          "Condition": {
            "StringEquals": {
              "token.actions.githubusercontent.com:sub": [
                "repo:shubhamc01@327102562/notes-app@1404437167:environment:dev-infra"
              ]
            }
          }
        }
      ]
    }
  TRUST
}

resource "aws_iam_role_policy" "infra_apply_dev" {
  name   = "permissions"
  role   = aws_iam_role.infra_apply_dev.id
  policy = <<-POLICY
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Action": [
            "ec2:*"
          ],
          "Resource": [
            "*"
          ]
        },
        {
          "Effect": "Allow",
          "Action": [
            "ec2:*",
            "ssm:GetParameter",
            "ssm:GetParameters"
          ],
          "Resource": [
            "*"
          ]
        },
        {
          "Effect": "Allow",
          "Action": [
            "logs:DescribeLogGroups"
          ],
          "Resource": [
            "*"
          ]
        },
        {
          "Effect": "Allow",
          "Action": [
            "logs:*"
          ],
          "Resource": [
            "arn:aws:logs:ap-south-1:407493720885:log-group:/notes-app-f308/dev",
            "arn:aws:logs:ap-south-1:407493720885:log-group:/notes-app-f308/dev:*"
          ]
        },
        {
          "Effect": "Allow",
          "Action": [
            "iam:CreateRole",
            "iam:PutRolePolicy",
            "iam:DeleteRolePolicy",
            "iam:AttachRolePolicy",
            "iam:DetachRolePolicy",
            "iam:PutRolePermissionsBoundary"
          ],
          "Resource": [
            "arn:aws:iam::407493720885:role/notes-app-f308/dev/*"
          ],
          "Condition": {
            "StringEquals": {
              "iam:PermissionsBoundary": "arn:aws:iam::407493720885:policy/notes-app-f308-dev-boundary"
            }
          }
        },
        {
          "Effect": "Allow",
          "Action": [
            "iam:DeleteRole",
            "iam:GetRole",
            "iam:TagRole",
            "iam:UntagRole",
            "iam:GetRolePolicy",
            "iam:ListRolePolicies",
            "iam:ListAttachedRolePolicies",
            "iam:ListInstanceProfilesForRole",
            "iam:PassRole"
          ],
          "Resource": [
            "arn:aws:iam::407493720885:role/notes-app-f308/dev/*"
          ]
        },
        {
          "Effect": "Allow",
          "Action": [
            "iam:CreateInstanceProfile",
            "iam:DeleteInstanceProfile",
            "iam:GetInstanceProfile",
            "iam:AddRoleToInstanceProfile",
            "iam:RemoveRoleFromInstanceProfile",
            "iam:TagInstanceProfile"
          ],
          "Resource": [
            "arn:aws:iam::407493720885:instance-profile/notes-app-f308/dev/*"
          ]
        },
        {
          "Effect": "Deny",
          "Action": [
            "iam:DeleteRolePermissionsBoundary",
            "iam:CreatePolicyVersion",
            "iam:SetDefaultPolicyVersion",
            "iam:UpdateAssumeRolePolicy"
          ],
          "Resource": [
            "*"
          ]
        },
        {
          "Effect": "Allow",
          "Action": [
            "s3:ListBucket"
          ],
          "Resource": [
            "arn:aws:s3:::tfstate-407493720885-ap-south-1"
          ]
        },
        {
          "Effect": "Allow",
          "Action": [
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject"
          ],
          "Resource": [
            "arn:aws:s3:::tfstate-407493720885-ap-south-1/notes-app-f308/dev/*"
          ]
        }
      ]
    }
  POLICY
}

resource "aws_iam_role" "infra_plan" {
  name               = "notes-app-f308-infra-plan"
  assume_role_policy = <<-TRUST
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": {
            "Federated": "${data.aws_iam_openid_connect_provider.ci.arn}"
          },
          "Action": "sts:AssumeRoleWithWebIdentity",
          "Condition": {
            "StringEquals": {
              "token.actions.githubusercontent.com:sub": [
                "repo:shubhamc01@327102562/notes-app@1404437167:pull_request"
              ]
            }
          }
        }
      ]
    }
  TRUST
}

resource "aws_iam_role_policy" "infra_plan" {
  name   = "permissions"
  role   = aws_iam_role.infra_plan.id
  policy = <<-POLICY
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Action": [
            "s3:ListBucket"
          ],
          "Resource": [
            "arn:aws:s3:::tfstate-407493720885-ap-south-1"
          ]
        },
        {
          "Effect": "Allow",
          "Action": [
            "s3:GetObject"
          ],
          "Resource": [
            "arn:aws:s3:::tfstate-407493720885-ap-south-1/notes-app-f308/*"
          ]
        },
        {
          "Effect": "Deny",
          "Action": [
            "ssm:GetParameter*"
          ],
          "NotResource": [
            "arn:aws:ssm:*::parameter/aws/service/*"
          ]
        },
        {
          "Effect": "Deny",
          "Action": [
            "secretsmanager:GetSecretValue",
            "kms:Decrypt",
            "dynamodb:GetItem",
            "dynamodb:BatchGetItem",
            "dynamodb:Scan",
            "dynamodb:Query",
            "dynamodb:PartiQLSelect",
            "dynamodb:GetRecords",
            "rds-data:*",
            "lambda:GetFunction*",
            "logs:GetLogEvents",
            "logs:FilterLogEvents",
            "logs:StartQuery",
            "logs:GetQueryResults",
            "logs:StartLiveTail",
            "ec2:GetPasswordData",
            "ec2:GetConsoleOutput",
            "ec2:GetConsoleScreenshot",
            "ecr:BatchGetImage",
            "ecr:GetDownloadUrlForLayer",
            "kinesis:GetRecords",
            "sqs:ReceiveMessage",
            "athena:GetQueryResults",
            "codecommit:GetFile",
            "codecommit:GetBlob",
            "glue:GetConnection*",
            "cloudformation:GetTemplate",
            "ssm:GetDocument"
          ],
          "Resource": [
            "*"
          ]
        },
        {
          "Effect": "Deny",
          "Action": [
            "s3:GetObject*"
          ],
          "NotResource": [
            "arn:aws:s3:::tfstate-407493720885-ap-south-1/notes-app-f308/*"
          ]
        }
      ]
    }
  POLICY
}

resource "aws_iam_role_policy_attachment" "infra_plan_0" {
  role       = aws_iam_role.infra_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}
