################################################################################
# Karpenter - self-managed node autoscaling
#
# Replaces EKS Auto Mode's built-in Karpenter. The submodule provisions the
# supporting AWS resources (node IAM role + instance profile, controller IAM
# role, Pod Identity association); the Helm release runs the controller on the
# system managed node group; a general-purpose NodePool provides on-demand
# capacity for the agents and the support stack; and a dedicated kata-fc pool
# provides Firecracker microVM isolation for sandboxed workloads (see
# manifests/). Native spot-termination handling (the SQS interruption queue +
# EventBridge rules) is DISABLED — the pools are on-demand only (see
# enable_spot_termination below).
################################################################################

# Public ECR auth token for pulling the Karpenter OCI chart.
data "aws_ecrpublic_authorization_token" "token" {
  region = "us-east-1"
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.24.0"

  cluster_name = module.eks.cluster_name

  # Node IAM role name must match the role referenced by the EC2NodeClass below.
  node_iam_role_use_name_prefix   = false
  node_iam_role_name              = "${local.name}-karpenter-node"
  create_pod_identity_association = true

  # Create the controller policy as an INLINE role policy (10,240 char limit)
  # instead of a standalone managed policy (6,144 char limit). The cluster name
  # is interpolated into many scoped EC2 ARN conditions, which pushes the
  # rendered policy past 6,144 and fails with
  # "LimitExceeded: Cannot exceed quota for PolicySize: 6144".
  enable_inline_policy = true

  # SSM access so nodes can be managed / debugged via Session Manager.
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  # Disable native spot-termination handling (the SQS interruption queue + its
  # EventBridge rules/targets). Both NodePools below are ON-DEMAND ONLY, so there
  # are no spot interruptions to handle and the queue provides no value.
  #
  # This also removes a transient provisioning failure: the AWS provider's
  # aws_cloudwatch_event_target does not retry the post-create read against
  # EventBridge's eventually-consistent ListTargetsByRule API, so the target's
  # read-after-create intermittently fails with "reading EventBridge Target
  # (...): empty result" even though the target was created (upstream bug
  # hashicorp/terraform-provider-aws#47687, unfixed as of provider 6.52.0).
  # Not creating the targets removes the race entirely.
  enable_spot_termination = false

  tags = local.tags
}

################################################################################
# Karpenter controller (Helm)
#
# Pinned to the system managed node group via nodeSelector so the controller is
# never scheduled onto a node it is itself responsible for provisioning.
################################################################################

resource "helm_release" "karpenter" {
  namespace           = "kube-system"
  name                = "karpenter"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter"
  version             = "1.13.0"

  # wait=true so the release only completes once the bundled CRDs
  # (nodepools/ec2nodeclasses.karpenter.*) are Established AND the controller
  # is Ready. The null_resources below immediately `kubectl apply` NodePool /
  # EC2NodeClass CRs; without this they can race the CRD registration and fail
  # with "no matches for kind NodePool". The controller runs on the system MNG
  # (already up), so this settles in ~1 min.
  wait    = true
  timeout = 600

  values = [
    <<-EOT
    nodeSelector:
      workshop.io/node-role: system
    dnsPolicy: Default
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      # No interruptionQueue: native spot-termination handling is disabled on the
      # module (enable_spot_termination = false) because both NodePools are
      # on-demand only. With the queue gone, module.karpenter.queue_name is null;
      # leaving Karpenter's interruptionQueue unset disables interruption polling
      # (correct for an all-on-demand cluster).
    webhook:
      enabled: false
    EOT
  ]

  depends_on = [
    module.eks,
    module.karpenter,
  ]
}

################################################################################
# General-purpose NodePool + EC2NodeClass
#
# On-demand only (reliability for a time-boxed workshop), amd64, AL2023, c/m/r
# families generation > 4. Subnets and the node security group are discovered
# by the karpenter.sh/discovery tag set in vpc.tf / base.tf.
#
# Applied with kubectl (not kubernetes_manifest) to avoid the provider's
# plan-time CRD lookup against a cluster that does not yet have Karpenter's
# CRDs installed. The destroy-time provisioner deletes the NodePool first so
# Karpenter drains and terminates its nodes before the cluster is torn down
# (otherwise the EC2 instances are orphaned and the VPC destroy hangs).
################################################################################

resource "null_resource" "karpenter_general_nodepool" {
  triggers = {
    cluster_name  = module.eks.cluster_name
    region        = local.region
    node_iam_role = module.karpenter.node_iam_role_name
    discovery_tag = local.name
  }

  provisioner "local-exec" {
    command = <<-EOT
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG"
      kubectl apply -f - <<'YAML'
      apiVersion: karpenter.k8s.aws/v1
      kind: EC2NodeClass
      metadata:
        name: default
      spec:
        amiFamily: AL2023
        amiSelectorTerms:
          - alias: al2023@latest
        role: ${self.triggers.node_iam_role}
        subnetSelectorTerms:
          - tags:
              karpenter.sh/discovery: ${self.triggers.discovery_tag}
        securityGroupSelectorTerms:
          - tags:
              karpenter.sh/discovery: ${self.triggers.discovery_tag}
        tags:
          karpenter.sh/discovery: ${self.triggers.discovery_tag}
      ---
      apiVersion: karpenter.sh/v1
      kind: NodePool
      metadata:
        name: general-purpose
      spec:
        template:
          spec:
            requirements:
              - key: karpenter.sh/capacity-type
                operator: In
                values: ["on-demand"]
              - key: kubernetes.io/arch
                operator: In
                values: ["amd64"]
              - key: kubernetes.io/os
                operator: In
                values: ["linux"]
              - key: karpenter.k8s.aws/instance-category
                operator: In
                values: ["c", "m", "r"]
              - key: karpenter.k8s.aws/instance-generation
                operator: Gt
                values: ["4"]
            nodeClassRef:
              group: karpenter.k8s.aws
              kind: EC2NodeClass
              name: default
            expireAfter: 720h
        limits:
          cpu: 1000
        disruption:
          consolidationPolicy: WhenEmptyOrUnderutilized
          consolidateAfter: 30s
      YAML
    EOT
  }

  # Drain Karpenter-managed capacity before the cluster is destroyed.
  #
  # Every delete is BOUNDED. Karpenter clears the karpenter.sh/termination finalizer
  # on a NodeClaim only after it terminates the backing EC2 instance, which requires
  # the EC2 API. An unbounded `kubectl delete --wait=true` therefore hangs the entire
  # destroy if Karpenter has lost that access — which is exactly what happens when the
  # NAT gateway is destroyed first (the depends_on below prevents that ordering, and
  # these timeouts stop it from being fatal if anything else stalls the drain).
  #
  # Karpenter's instances are NOT Terraform-managed, so a stalled drain would leak
  # running EC2 instances. The safety net terminates any that survive, from the
  # Terraform host, which has its own route to the AWS API.
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT

      # A kubeconfig failure must NOT skip the EC2 safety net below: an unreachable
      # or already-deleted cluster is precisely the case where Karpenter never got
      # to drain, so the net matters most. Only the in-cluster drain is conditional.
      if aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG"; then
        kubectl delete nodepool general-purpose --ignore-not-found --wait=true --timeout=300s || true
        kubectl delete ec2nodeclass default --ignore-not-found --wait=true --timeout=120s || true
      else
        echo "WARNING: cluster unreachable; skipping in-cluster drain, running EC2 safety net."
      fi

      # Safety net, always runs. Karpenter's instances are not Terraform-managed, so
      # anything it failed to terminate leaks. Failures here are FATAL rather than
      # ignored: a silent leak bills indefinitely, and leftover instances keep ENIs
      # attached, which makes the later subnet/VPC deletion fail with a far more
      # confusing error.
      LEAKED=""
      for attempt in 1 2 3; do
        if LEAKED=$(aws ec2 describe-instances --region ${self.triggers.region} \
          --filters "Name=tag:eks:eks-cluster-name,Values=${self.triggers.cluster_name}" \
                    "Name=tag-key,Values=karpenter.sh/nodepool" \
                    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
          --query 'Reservations[].Instances[].InstanceId' --output text); then
          break
        fi
        if [ "$attempt" = 3 ]; then
          echo "ERROR: could not query Karpenter instances after 3 attempts; check for leaks manually." >&2
          exit 1
        fi
        sleep 10
      done

      if [ -n "$LEAKED" ]; then
        echo "WARNING: Karpenter did not terminate its instances; terminating: $LEAKED"
        for attempt in 1 2 3; do
          if aws ec2 terminate-instances --region ${self.triggers.region} --instance-ids $LEAKED >/dev/null; then
            break
          fi
          if [ "$attempt" = 3 ]; then
            echo "ERROR: failed to terminate $LEAKED after 3 attempts." >&2
            exit 1
          fi
          sleep 10
        done
        # Termination is asynchronous; block until the ENIs are actually released so
        # VPC teardown does not race them.
        echo "Waiting for termination to complete..."
        aws ec2 wait instance-terminated --region ${self.triggers.region} --instance-ids $LEAKED || {
          echo "ERROR: $LEAKED did not reach terminated state; VPC teardown may fail on attached ENIs." >&2
          exit 1
        }
      fi
    EOT
  }

  depends_on = [
    helm_release.karpenter,
    # Destroy-order guard: this provisioner's kubectl deletes need Karpenter to reach
    # the EC2 API from inside the cluster, which goes out through the VPC's NAT
    # gateway. Without this edge the NAT gateway has no relationship to this resource
    # and Terraform is free to destroy it first, deadlocking the drain.
    module.vpc,
  ]
}

################################################################################
# kata-containers + Firecracker NodePool (sandboxed workloads)
#
# A dedicated, tainted pool for hardware-isolated (microVM) pods. It relies on
# EC2 nested virtualization (Karpenter 1.13's cpuOptions.nestedVirtualization),
# so it is restricted to the 8i families (c8i/m8i/r8i — the only ones exposing
# /dev/kvm to the guest). The EC2NodeClass userData installs kata + Firecracker
# and registers a "kata-fc" containerd runtime; the RuntimeClass lets pods opt
# in with `runtimeClassName: kata-fc` (it carries the nodeSelector + toleration
# that target this pool).
#
# The manifests live in terraform/manifests/ as static files so the shell
# ${...} inside the install script is NOT touched by Terraform interpolation.
# Only the node IAM role and discovery tag are templated, via sed placeholders
# (__NODE_IAM_ROLE__ / __DISCOVERY_TAG__).
################################################################################

resource "null_resource" "karpenter_kata_fc" {
  triggers = {
    cluster_name  = module.eks.cluster_name
    region        = local.region
    node_iam_role = module.karpenter.node_iam_role_name
    discovery_tag = local.name
    manifest_dir  = "${path.module}/manifests"
    # Re-apply when any of the manifests change.
    ec2nodeclass_hash = filemd5("${path.module}/manifests/ec2nodeclass-kata-fc.yaml")
    nodepool_hash     = filemd5("${path.module}/manifests/nodepool-kata-fc.yaml")
    runtimeclass_hash = filemd5("${path.module}/manifests/runtimeclass-kata-fc.yaml")
  }

  provisioner "local-exec" {
    # bash (not the runner's default /bin/sh) for `set -o pipefail`.
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG"
      MANIFESTS="${self.triggers.manifest_dir}"
      sed -e "s|__NODE_IAM_ROLE__|${self.triggers.node_iam_role}|g" \
          -e "s|__DISCOVERY_TAG__|${self.triggers.discovery_tag}|g" \
          "$MANIFESTS/ec2nodeclass-kata-fc.yaml" | kubectl apply -f -
      kubectl apply -f "$MANIFESTS/nodepool-kata-fc.yaml"
      kubectl apply -f "$MANIFESTS/runtimeclass-kata-fc.yaml"
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG" || exit 0
      # Bounded for the same reason as the general-purpose pool above: Karpenter needs
      # the EC2 API to clear the NodeClaim finalizer, so an unbounded wait deadlocks
      # the destroy if it cannot reach it. The general-purpose provisioner's safety net
      # terminates any Karpenter instance this cluster leaks, kata-fc pool included.
      kubectl delete runtimeclass kata-fc --ignore-not-found --wait=true --timeout=60s || true
      kubectl delete nodepool kata-fc --ignore-not-found --wait=true --timeout=300s || true
      kubectl delete ec2nodeclass kata-fc --ignore-not-found --wait=true --timeout=120s || true
    EOT
  }

  depends_on = [
    helm_release.karpenter,
    # See the general-purpose pool: keeps the NAT gateway alive until this drain runs.
    module.vpc,
  ]
}
