terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    bucket       = "taskflow-state"
    key          = "dev/us-east-1/networking/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" { region = "us-east-1" }

locals {
  name = "taskflow-dev"
  tags = { Project = "taskflow", Environment = "dev", ManagedBy = "terraform" }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.name}-vpc"
  cidr = "10.16.0.0/16"

  azs            = ["us-east-1a", "us-east-1b"]
  public_subnets = ["10.16.1.0/24", "10.16.2.0/24"]

  enable_nat_gateway   = false
  enable_dns_hostnames = true

  tags = local.tags
}

output "vpc_id"            { value = module.vpc.vpc_id }
output "public_subnet_ids" { value = module.vpc.public_subnets }
