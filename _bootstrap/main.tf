locals {
  project = "taskflow"
  common_tags = {
    Project   = local.project
    ManagedBy = "terraform"
  }
}

data "aws_caller_identity" "current" {}

# S3 State Bucket

resource "aws_s3_bucket" "state" {
  bucket = "${local.project}-state"
  tags   = local.common_tags

  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
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
    Statement = [{
      Sid       = "DenyNonHTTPS"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = ["${aws_s3_bucket.state.arn}", "${aws_s3_bucket.state.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# GitHub OIDC

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = []

  tags = local.common_tags
}

# Infra deploy role

data "aws_iam_policy_document" "infra_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [
        "repo:jhermesn/taskflow-infra:environment:dev",
        "repo:jhermesn/taskflow-infra:environment:prod",
      ]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "infra_deploy" {
  name               = "${local.project}-deploy"
  assume_role_policy = data.aws_iam_policy_document.infra_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy" "infra_deploy" {
  name = "${local.project}-deploy-policy"
  role = aws_iam_role.infra_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:*"]
        Resource = ["arn:aws:s3:::${local.project}*", "arn:aws:s3:::${local.project}*/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:*"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["ecs:*"]
        Resource = [
          "arn:aws:ecs:*:*:cluster/${local.project}-*",
          "arn:aws:ecs:*:*:service/${local.project}-*/*",
          "arn:aws:ecs:*:*:task-definition/${local.project}-*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeClusters", "ecs:ListClusters",
          "ecs:CreateCluster", "ecs:DeleteCluster", "ecs:PutClusterCapacityProviders",
          "ecs:TagResource", "ecs:UntagResource", "ecs:ListTagsForResource",
          "ecs:DescribeCapacityProviders",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:*"]
        Resource = "arn:aws:ecr:*:*:repository/${local.project}-*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken", "ecr:DescribeRepositories"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["elasticloadbalancing:*"]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/${local.project}-*/*",
          "arn:aws:elasticloadbalancing:*:*:listener/app/${local.project}-*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener-rule/app/${local.project}-*/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:targetgroup/${local.project}-*/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:DescribeLoadBalancers", "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeListeners", "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeTags", "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeTargetGroupAttributes", "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeListenerAttributes",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup", "logs:DeleteLogGroup",
          "logs:PutRetentionPolicy", "logs:TagLogGroup",
          "logs:TagResource", "logs:UntagResource",
          "logs:ListTagsForResource", "logs:ListTagsLogGroup",
        ]
        Resource = "arn:aws:logs:*:*:log-group:/ecs/${local.project}-*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
          "iam:PassRole", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:TagRole", "iam:UntagRole",
          "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider", "iam:TagOpenIDConnectProvider",
        ]
        Resource = [
          "arn:aws:iam::*:role/${local.project}-*",
          "arn:aws:iam::*:oidc-provider/token.actions.githubusercontent.com",
        ]
      },
    ]
  })
}

# App deploy role

data "aws_iam_policy_document" "app_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [
        "repo:jhermesn/taskflow-app:environment:dev",
        "repo:jhermesn/taskflow-app:environment:prod",
      ]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app_deploy" {
  name               = "${local.project}-app-deploy"
  assume_role_policy = data.aws_iam_policy_document.app_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy" "app_deploy" {
  name = "${local.project}-app-deploy-policy"
  role = aws_iam_role.app_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload", "ecr:PutImage",
        ]
        Resource = [
          "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${local.project}-dev-backend",
          "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${local.project}-prod-backend",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition",
          "ecs:UpdateService", "ecs:DescribeServices",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.project}-*-ecs-*"
      },
    ]
  })
}
