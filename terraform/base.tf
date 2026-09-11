provider "aws" {
  region = local.region
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

# Exclude Local Zones / Wavelength Zones (opt-in zones); EKS control plane and
# NAT gateways only support standard regional AZs. Without this filter, an
# account with Local Zones opted in (e.g. us-west-2-lax-*) can land subnets in
# an unsupported zone.
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# tflint-ignore: terraform_unused_declarations
variable "eks_cluster_id" {
  description = "EKS cluster name"
  type        = string
}
variable "aws_region" {
  description = "AWS Region"
  type        = string
}

locals {
  name   = var.eks_cluster_id
  region = var.aws_region

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/aws-ia/terraform-aws-eks-blueprints"
  }
}

################################################################################
# Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.24.0"

  name                   = local.name
  kubernetes_version     = var.cluster_version
  endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_cluster_creator_admin_permissions = true

  # EKS managed node group sized only for system / control-plane-adjacent
  # workloads: CoreDNS, the Karpenter controller, AWS Load Balancer Controller,
  # the EBS CSI controller, cert-manager, the ADOT operator, and the metrics
  # stack. Everything else (agents + the support stack) runs on Karpenter-
  # provisioned nodes from the general-purpose NodePool (see karpenter.tf).
  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["m6i.large", "m5.large", "m6a.large"]

      min_size     = 2
      max_size     = 3
      desired_size = 2

      labels = {
        # Karpenter is pinned to these nodes so it never tries to schedule its
        # own controller onto a node it is responsible for creating.
        "workshop.io/node-role" = "system"
      }
    }
  }

  # Core EKS managed addons. EKS Auto Mode used to provide these implicitly; on
  # a standard cluster they are installed explicitly. vpc-cni and the Pod
  # Identity agent come up before the nodes (before_compute) so networking and
  # pod credentials are ready when the first node joins.
  #
  # The ADOT operator addon is NOT listed here — it requires cert-manager (an
  # eks_blueprints_addons release) to exist first, so it is a standalone
  # aws_eks_addon in addons.tf with an explicit dependency.
  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
      # Enable the built-in NetworkPolicy agent so Kubernetes NetworkPolicy
      # objects are enforced. Required by the agent-sandbox air-gap (egress:[])
      # and the sandbox-router ingress lock (see terraform/agentsandbox.tf).
      # Default-allow until a policy selects a pod, so existing workshop traffic
      # is unaffected.
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
    aws-ebs-csi-driver = {
      # Bound to its IAM role via the Pod Identity association in addons.tf.
      most_recent = true
      # Pinned to the system MNG for the same reason as the LB controller and
      # cert-manager (addons.tf): a clean `terraform destroy` depends on the CSI
      # controller staying alive and reachable while langfuse/milvus/gitea are
      # uninstalled, so their PVCs (and the EBS volumes behind them) actually get
      # reclaimed. Left unpinned, the controller could land on a Karpenter node,
      # which the general-purpose NodePool's destroy provisioner drains/force-
      # terminates — possibly while a volume delete is still in flight.
      configuration_values = jsonencode({
        controller = { nodeSelector = { "workshop.io/node-role" = "system" } }
      })
    }
    # Community addons retained from the original workshop setup.
    metrics-server     = { most_recent = true }
    kube-state-metrics = { most_recent = true }
    # prometheus-node-exporter = { most_recent = true }
  }

  # Allow intra-cluster pod-to-pod traffic on port 80. The EKS-managed node
  # security group's self rule only covers TCP 1025-65535, so CROSS-NODE pod
  # traffic to a workload listening on :80 is dropped (same-node works because it
  # never traverses the node ENI/SG). The agentgateway data-plane proxy binds its
  # HTTP listener directly on :80, so without this every MCP/A2A call routed
  # through agentgateway from an agent on a different node times out. (The Envoy
  # AI Gateway avoids this only because it maps Service :80 -> container :10080,
  # a high port already inside the self rule.) Self-referencing + cluster-internal
  # only — no external exposure.
  node_security_group_additional_rules = {
    ingress_self_http = {
      description = "Intra-cluster pod-to-pod HTTP (agentgateway proxy binds :80)"
      protocol    = "tcp"
      from_port   = 80
      to_port     = 80
      type        = "ingress"
      self        = true
    }
  }

  # Tag the cluster node security group so the Karpenter EC2NodeClass can
  # discover it (securityGroupSelectorTerms). The private subnets already carry
  # the matching karpenter.sh/discovery tag (see vpc.tf).
  node_security_group_tags = merge(local.tags, {
    "karpenter.sh/discovery" = local.name
  })

  tags = local.tags
}

resource "time_sleep" "wait_60_seconds" {
  create_duration = "60s"

  depends_on = [module.eks]
}
