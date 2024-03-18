data "aws_key_pair" "ssh_key" {
  key_name = "tentek"
}

data "aws_ami" "ami" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-kernel-5.10-hvm*x86_64-gp2"]
  }
}

data "aws_route53_zone" "zone" {
  name         = "apahomov.com"
  private_zone = false
}

data "aws_secretsmanager_secret_version" "credentials" {
  secret_id = "rds-creds"
}