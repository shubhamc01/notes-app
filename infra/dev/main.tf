# ENGINE-RENDERED by devops-agent from catalog data — do not edit; regenerate instead.
module "app" {
  source               = "../modules/app"
  app_id               = "notes-app-f308"
  env                  = "dev"
  region               = "ap-south-1"
  account_id           = "407493720885"
  name                 = "notes-app-f308"
  iam_path             = "/notes-app-f308/dev/"
  permissions_boundary = "arn:aws:iam::407493720885:policy/notes-app-f308-dev-boundary"
  instance_type        = "t3.small"
  instance_arch        = "x86_64"
  vpc_id               = "vpc-0173de1f48d796dbc"
  subnet_ids           = ["subnet-0d7907eadedf25e63", "subnet-0d90277dcac5d3e72", "subnet-0fbe32e157fa9669b"]
}
