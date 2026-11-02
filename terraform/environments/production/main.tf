terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

locals {
  tags = {
    Project     = "payments-api"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

module "vpc" {
  source = "../../modules/vpc"

  name       = "${var.environment}-payments-api"
  cidr_block = var.vpc_cidr_block
  tags       = local.tags
}

module "alb" {
  source = "../../modules/alb"

  name              = "${var.environment}-payments-api"
  vpc_id            = module.vpc.vpc_id
  vpc_cidr_block    = var.vpc_cidr_block
  public_subnet_ids = module.vpc.public_subnet_ids
  target_port       = var.container_port
  tags              = local.tags
}

module "ecs" {
  source = "../../modules/ecs"

  name                  = "${var.environment}-payments-api"
  region                = var.region
  vpc_id                = module.vpc.vpc_id
  private_subnet_ids    = module.vpc.private_subnet_ids
  alb_security_group_id = module.alb.alb_security_group_id
  target_group_arn      = module.alb.target_group_arn
  image                 = var.image
  app_env               = var.environment
  container_port        = var.container_port
  task_cpu              = var.task_cpu
  task_memory           = var.task_memory
  desired_count         = var.desired_count
  max_count             = var.max_count
  log_retention_days    = var.log_retention_days
  tags                  = local.tags
}
