terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    bucket       = "taskflow-state"
    key          = "prod/us-east-1/backend/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" { region = "us-east-1" }

variable "enabled" {
  type        = bool
  default     = true
  description = "When false, ALB and ECS service are destroyed to save costs."
}

variable "container_image" {
  type    = string
  default = "public.ecr.aws/amazonlinux/amazonlinux:latest"
}

locals {
  name = "taskflow-prod"
  port = 8000
  tags = { Project = "taskflow", Environment = "prod", ManagedBy = "terraform" }
}

data "aws_region" "current" {}

data "terraform_remote_state" "networking" {
  backend = "s3"
  config = {
    bucket = "taskflow-state"
    key    = "prod/us-east-1/networking/terraform.tfstate"
    region = "us-east-1"
  }
}

resource "aws_ecr_repository" "app" {
  name                 = "${local.name}-backend"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration { scan_on_push = true }

  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions    = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${local.name}-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "execution_base" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name               = "${local.name}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name}-backend"
  retention_in_days = 30
  tags              = local.tags
}

resource "aws_security_group" "ecs" {
  name        = "${local.name}-ecs-sg"
  description = "ECS tasks"
  vpc_id      = data.terraform_remote_state.networking.outputs.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.name}-ecs-sg" })
}

resource "aws_security_group_rule" "ecs_from_alb" {
  count                    = var.enabled ? 1 : 0
  type                     = "ingress"
  description              = "From ALB"
  from_port                = local.port
  to_port                  = local.port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs.id
  source_security_group_id = try(module.alb[0].security_group_id, null)
}

module "alb" {
  count   = var.enabled ? 1 : 0
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 9.0"

  name    = "${local.name}-alb"
  vpc_id  = data.terraform_remote_state.networking.outputs.vpc_id
  subnets = data.terraform_remote_state.networking.outputs.public_subnet_ids

  security_group_ingress_rules = {
    http = { from_port = 80, to_port = 80, ip_protocol = "tcp", cidr_ipv4 = "0.0.0.0/0" }
  }
  security_group_egress_rules = {
    all = { ip_protocol = "-1", cidr_ipv4 = "0.0.0.0/0" }
  }

  listeners = {
    http = {
      port     = 80
      protocol = "HTTP"
      forward  = { target_group_key = "app" }
    }
  }

  target_groups = {
    app = {
      name              = "${local.name}-app-tg"
      protocol          = "HTTP"
      port              = local.port
      target_type       = "ip"
      create_attachment = false
      health_check = {
        path                = "/health"
        interval            = 30
        timeout             = 5
        healthy_threshold   = 2
        unhealthy_threshold = 3
      }
    }
  }

  tags = local.tags
}

module "ecs" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "~> 5.0"

  cluster_name = "${local.name}-cluster"
  tags         = local.tags
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${local.name}-backend"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "backend"
    image     = var.container_image
    essential = true
    portMappings = [{ containerPort = local.port, protocol = "tcp" }]
    environment  = [{ name = "ENV", value = "prod" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  tags = local.tags
}

resource "aws_ecs_service" "app" {
  count           = var.enabled ? 1 : 0
  name            = "${local.name}-backend"
  cluster         = module.ecs.cluster_id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.terraform_remote_state.networking.outputs.public_subnet_ids
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = try(module.alb[0].target_groups["app"].arn, "")
    container_name   = "backend"
    container_port   = local.port
  }

  depends_on = [module.alb]
  tags       = local.tags
}

output "ecr_repository_url" { value = aws_ecr_repository.app.repository_url }
output "ecs_cluster_name"   { value = module.ecs.cluster_name }
output "ecs_service_name"   { value = try(aws_ecs_service.app[0].name, "") }
output "alb_dns_name"       { value = try(module.alb[0].dns_name, "") }
