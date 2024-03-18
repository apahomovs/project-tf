#create vpc

module "vpc" {
  source            = "github.com/apahomovs/tf-modules//vpc_module"
  cidr_block        = "10.0.0.0/24"
  vpc_tag           = "project-tf"
  create_attach_igw = true
}

#create public subnets

module "subnets" {
  source                  = "github.com/apahomovs/tf-modules//subnet_module"
  vpc_id                  = module.vpc.id
  cidr_block              = each.value[0]
  availability_zone       = each.value[1]
  map_public_ip_on_launch = each.value[2]
  subnet_tag              = each.value[3]

  for_each = {
    public_1a  = ["10.0.0.0/26", "us-east-1a", true, "public_1a"]
    private_1a = ["10.0.0.64/26", "us-east-1a", false, "private_1a"]
    public_1b  = ["10.0.0.128/26", "us-east-1b", true, "public_1b"]
    private_1b = ["10.0.0.192/26", "us-east-1b", false, "private_1b"]
  }
}

#create natgw and eip

module "natgw" {
  source    = "github.com/apahomovs/tf-modules//natgw_module"
  subnet_id = module.subnets["public_1a"].id
  natgw_tag = "project-tf"
}

#create public rt

module "public_rt" {
  source         = "github.com/apahomovs/tf-modules//rt_module"
  vpc_id         = module.vpc.id
  gateway_id     = module.vpc.igw_id
  subnets        = [module.subnets["public_1a"].id, module.subnets["public_1b"].id]
  nat_gateway_id = null
}

module "private_rt" {
  source         = "github.com/apahomovs/tf-modules//rt_module"
  vpc_id         = module.vpc.id
  gateway_id     = null
  subnets        = [module.subnets["private_1a"].id, module.subnets["private_1b"].id]
  nat_gateway_id = module.natgw.id
}

#create sg

module "ec2_sgrp" {
  source = "github.com/apahomovs/tf-modules//sg_module"

  vpc_id      = module.vpc.id
  name        = "ec2-sgrp"
  description = "ec2_sgrp"
  sg_tag      = "ec2_sgrp"

  sg_rules = {
    "ssh_rule"      = ["ingress", 22, 22, "TCP", "0.0.0.0/0"]
    "http_rule"     = ["ingress", 80, 80, "TCP", module.alb_sgrp.id]
    "outbound_rule" = ["egress", 0, 0, "-1", "0.0.0.0/0"]
  }
}

#create ec2

module "instances" {
  source = "github.com/apahomovs/tf-modules//ec2_module"

  for_each = {
    public_1a_instance = module.subnets["public_1a"].id
    public_1b_instance = module.subnets["public_1b"].id
  }

  ami                    = data.aws_ami.ami.id
  instance_type          = "t2.micro"
  key_name               = data.aws_key_pair.ssh_key.key_name
  vpc_security_group_ids = [module.ec2_sgrp.id]
  subnet_id              = each.value
  instance_tag           = each.key
  user_data              = file("userdata.sh")
}

#create tg

module "tg" {
  source      = "github.com/apahomovs/tf-modules//tg_module"
  tg_name     = "tg"
  tg_protocol = "HTTP"
  tg_vpc_id   = module.vpc.id
  tg_port     = "80"
  tg_tag      = "alb_tgrp"
  instance_ids = [
    module.instances["public_1a_instance"].id,
    module.instances["public_1b_instance"].id
  ]
}

#create sg for alb

module "alb_sgrp" {
  source = "github.com/apahomovs/tf-modules//sg_module"

  vpc_id      = module.vpc.id
  name        = "alb-sgrp"
  description = "alb_sgrp"
  sg_tag      = "alb_sgrp"

  sg_rules = {
    "https_rule"    = ["ingress", 443, 443, "tcp", "0.0.0.0/0"]
    "http_rule"     = ["ingress", 80, 80, "tcp", "0.0.0.0/0"]
    "outbound_rule" = ["egress", 0, 0, "-1", "0.0.0.0/0"]
  }
}

#create and validate ssl/tls cert

module "ssl" {
  source                    = "github.com/russgazin/b11-modules//acm_module"
  domain_name               = "apahomov.com"
  subject_alternative_names = ["*.apahomov.com"]
  validation_method         = "DNS"
  cert_tag                  = "project-tf"
  zone_id                   = data.aws_route53_zone.zone.id
}

#create alb

module "alb" {
  source = "github.com/russgazin/b11-modules//alb_module"

  name               = "alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [module.alb_sgrp.id]
  subnets = [
    module.subnets["public_1a"].id,
    module.subnets["public_1b"].id
  ]
  alb_tag          = "alb"
  certificate_arn  = module.ssl.arn
  target_group_arn = module.tg.tg_arn
}

#create cname

module "application_entry_record" {
  source  = "github.com/russgazin/b11-modules//dns_module"
  zone_id = data.aws_route53_zone.zone.id
  name    = "project.apahomov.com"
  type    = "CNAME"
  ttl     = 60
  records = [module.alb.dns_name]
}

#create db sgrp

module "rds_sgrp" {
  source = "github.com/apahomovs/tf-modules//sg_module"

  vpc_id      = module.vpc.id
  name        = "rds-sgrp"
  description = "rds_sgrp"
  sg_tag      = "rds_sgrp"

  sg_rules = {
    "mysql_rule"    = ["ingress", 3306, 3306, "tcp", module.ec2_sgrp.id]
    "outbound_rule" = ["egress", 0, 0, "-1", "0.0.0.0/0"]
  }
}

#create db subnet group

module "db_subnet" {
  source = "github.com/russgazin/terraform-project-batch-11/modules//db_subnet_group"

  name = "db-subnet"
  subnet_ids = [
    module.subnets["private_1a"].id,
    module.subnets["private_1b"].id
  ]
  db_subnet_group_tag = "db_subnet"
}

locals {
  credentials = jsondecode(data.aws_secretsmanager_secret_version.credentials.secret_string)
}


#create db instance

module "rds" {
  source = "github.com/russgazin/terraform-project-batch-11/modules//db_instance"

  allocated_storage    = 20
  engine               = "mysql"
  engine_version       = "5.7.44"
  instance_class       = "db.t3.micro"
  db_name              = "secretData"
  username             = local.credentials.USERNAME
  password             = local.credentials.PASSWORD
  security_group_ids   = [module.rds_sgrp.id]
  db_subnet_group_name = module.db_subnet.name
}





