# ENGINE-RENDERED by devops-agent from catalog data — do not edit; regenerate instead.
terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = { source = "hashicorp/aws", version = "6.67.0" }
  }
}

provider "aws" {
  region              = "ap-south-1"
  allowed_account_ids = ["407493720885"]
  default_tags {
    tags = { app_id = "notes-app-f308", managed-by = "devops-agent", stack = "bootstrap", repo = "shubhamc01/notes-app" }
  }
}
