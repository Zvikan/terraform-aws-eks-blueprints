provider "aws" {
  region = local.region
}

provider "kubernetes" {
  host                   = module.eks_blueprints.eks_cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_blueprints.eks_cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks_blueprints.eks_cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_blueprints.eks_cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks_blueprints.eks_cluster_id
}

data "aws_availability_zones" "available" {}

locals {
  name   = basename(path.cwd)
  region = "us-west-2"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/aws-ia/terraform-aws-eks-blueprints"
  }
}

#---------------------------------------------------------------
# EKS Blueprints
#---------------------------------------------------------------

module "eks_blueprints" {
  source = "../.."

  cluster_name    = local.name
  cluster_version = "1.22"

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnets

  #----------------------------------------------------------------------------------------------------------#
  # Security groups used in this module created by the upstream modules terraform-aws-eks (https://github.com/terraform-aws-modules/terraform-aws-eks).
  #   Upstream module implemented Security groups based on the best practices doc https://docs.aws.amazon.com/eks/latest/userguide/sec-group-reqs.html.
  #   So, by default the security groups are restrictive. Users needs to enable rules for specific ports required for App requirement or Add-ons
  #   See the notes below for each rule used in these examples
  #----------------------------------------------------------------------------------------------------------#
  node_security_group_additional_rules = {
    # Extend node-to-node security group rules. Recommended and required for the Add-ons
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    # Recommended outbound traffic for Node groups
    egress_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
    # Allows Control Plane Nodes to talk to Worker nodes on all ports. Added this to simplify the example and further avoid issues with Add-ons communication with Control plane.
    # This can be restricted further to specific port based on the requirement for each Add-on e.g., metrics-server 4443, spark-operator 8080, karpenter 8443 etc.
    # Change this according to your security requirements if needed
    ingress_cluster_to_node_all_traffic = {
      description                   = "Cluster API to Nodegroup all traffic"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  eks_managed_node_groups = {
    mg_5 = {
      name = "managed-ondemand"

      instance_types       = ["m5.large"]
      force_update_version = true
    }
  }

  tags = local.tags
}

data "aws_eks_addon_version" "latest" {
  for_each = toset(["vpc-cni", "coredns"])

  addon_name         = each.value
  kubernetes_version = module.eks_blueprints.eks_cluster_version
  most_recent        = true
}

data "aws_eks_addon_version" "default" {
  for_each = toset(["kube-proxy"])

  addon_name         = each.value
  kubernetes_version = module.eks_blueprints.eks_cluster_version
  most_recent        = false
}

module "eks_blueprints_kubernetes_addons" {
  source = "../../modules/kubernetes-addons"

  eks_cluster_id               = module.eks_blueprints.eks_cluster_id
  eks_cluster_endpoint         = module.eks_blueprints.eks_cluster_endpoint
  eks_oidc_provider            = module.eks_blueprints.oidc_provider
  eks_cluster_version          = module.eks_blueprints.eks_cluster_version
  eks_worker_security_group_id = module.eks_blueprints.worker_node_security_group_id
  auto_scaling_group_names     = module.eks_blueprints.self_managed_node_group_autoscaling_groups

  # EKS Addons
  enable_amazon_eks_vpc_cni = true
  amazon_eks_vpc_cni_config = {
    addon_version     = data.aws_eks_addon_version.latest["vpc-cni"].version
    resolve_conflicts = "OVERWRITE"
  }

  enable_amazon_eks_coredns = true
  amazon_eks_coredns_config = {
    addon_version     = data.aws_eks_addon_version.latest["coredns"].version
    resolve_conflicts = "OVERWRITE"
  }

  enable_amazon_eks_kube_proxy = true
  amazon_eks_kube_proxy_config = {
    addon_version     = data.aws_eks_addon_version.default["kube-proxy"].version
    resolve_conflicts = "OVERWRITE"
  }

  enable_amazon_eks_aws_ebs_csi_driver = true

  enable_prometheus                    = true
  enable_amazon_prometheus             = true
  amazon_prometheus_workspace_endpoint = module.managed_prometheus.workspace_prometheus_endpoint

  enable_aws_for_fluentbit = true
  aws_for_fluentbit_helm_config = {
    name                                      = "aws-for-fluent-bit"
    chart                                     = "aws-for-fluent-bit"
    repository                                = "https://aws.github.io/eks-charts"
    version                                   = "0.1.16"
    namespace                                 = "logging"
    aws_for_fluent_bit_cw_log_group           = "/${module.eks_blueprints.eks_cluster_id}/worker-fluentbit-logs" # Optional
    aws_for_fluentbit_cwlog_retention_in_days = 90
    create_namespace                          = true
    values = [templatefile("${path.module}/helm_values/aws-for-fluentbit-values.yaml", {
      region                          = local.region
      aws_for_fluent_bit_cw_log_group = "/${module.eks_blueprints.eks_cluster_id}/worker-fluentbit-logs"
    })]
    set = [
      {
        name  = "nodeSelector.kubernetes\\.io/os"
        value = "linux"
      }
    ]
  }

  enable_fargate_fluentbit = true
  fargate_fluentbit_addon_config = {
    output_conf = <<-EOF
    [OUTPUT]
      Name cloudwatch_logs
      Match *
      region ${local.region}
      log_group_name /${module.eks_blueprints.eks_cluster_id}/fargate-fluentbit-logs
      log_stream_prefix "fargate-logs-"
      auto_create_group true
    EOF

    filters_conf = <<-EOF
    [FILTER]
      Name parser
      Match *
      Key_Name log
      Parser regex
      Preserve_Key True
      Reserve_Data True
    EOF

    parsers_conf = <<-EOF
    [PARSER]
      Name regex
      Format regex
      Regex ^(?<time>[^ ]+) (?<stream>[^ ]+) (?<logtag>[^ ]+) (?<message>.+)$
      Time_Key time
      Time_Format %Y-%m-%dT%H:%M:%S.%L%z
      Time_Keep On
      Decode_Field_As json message
    EOF
  }

  tags = local.tags
}

#---------------------------------------------------------------
# Supporting Resources
#---------------------------------------------------------------

module "managed_prometheus" {
  source  = "terraform-aws-modules/managed-service-prometheus/aws"
  version = "~> 2.1"

  workspace_alias = local.name

  tags = local.tags
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 10)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # Manage so we can name
  manage_default_network_acl    = true
  default_network_acl_tags      = { Name = "${local.name}-default" }
  manage_default_route_table    = true
  default_route_table_tags      = { Name = "${local.name}-default" }
  manage_default_security_group = true
  default_security_group_tags   = { Name = "${local.name}-default" }

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.name}" = "shared"
    "kubernetes.io/role/elb"              = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.name}" = "shared"
    "kubernetes.io/role/internal-elb"     = 1
  }

  tags = local.tags
}
