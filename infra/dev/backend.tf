# ENGINE-RENDERED by devops-agent from catalog data — do not edit; regenerate instead.
terraform {
  backend "s3" {
    bucket       = "tfstate-407493720885-ap-south-1"
    key          = "notes-app-f308/dev/ap-south-1/terraform.tfstate"
    region       = "ap-south-1"
    use_lockfile = true
    encrypt      = true
  }
}
