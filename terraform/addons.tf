
################################################################################
# EKS Blueprints Addons
#
# Split into TWO module instances so the AWS Load Balancer Controller is fully
# rolled out before cert-manager installs. A single instance installs both charts
# concurrently (sibling resources, no dependency edge between them), and the LB
# controller registers a cluster-wide mutating webhook on Services with
# failurePolicy=Fail. cert-manager creates Services, so it raced that webhook and
# failed the provision with:
#
#   Internal error occurred: failed calling webhook "mservice.elbv2.k8s.aws":
#   no endpoints available for service "aws-load-balancer-webhook-service"
#
# Ordering cannot be expressed inside one instance — hence the split. `wait = true`
# on the controller is what makes the ordering meaningful: without it the first
# instance completes as soon as the manifests are applied, which is exactly when
# the webhook goes live but has no ready endpoints.
################################################################################

# Instance 1/2 — AWS Load Balancer Controller only.
module "eks_blueprints_addons" {
  depends_on = [time_sleep.wait_60_seconds]
  source     = "aws-ia/eks-blueprints-addons/aws"
  version    = "1.23.0"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  # AWS Load Balancer Controller — provisions the ALBs the workshop ingresses
  # (chat UI, Langfuse) depend on. EKS Auto Mode provided ALB natively;
  # a standard cluster needs this controller.
  #
  # Pinned to the system MNG: it's a cluster-critical controller and must not
  # depend on Karpenter (which it is unrelated to) for a node to run on. The
  # system MNG is the only node group with this label.
  #
  # vpcId + region are passed EXPLICITLY. Without them the controller tries to
  # introspect the VPC ID from EC2 instance metadata (IMDS) and crash-loops with
  # "failed to fetch VPC ID from instance metadata: EC2MetadataError ... status
  # code: 401" — the pod can't reach IMDSv2 through the extra network hop. Giving
  # it vpcId/region directly skips IMDS introspection entirely.
  #
  # The chart's cluster-wide mutating webhook on Services (mservice.elbv2.k8s.aws,
  # failurePolicy=Fail) is left at its default (enabled). It intercepts EVERY
  # Service CREATE in the cluster and fails closed, so anything creating a Service
  # while this controller is still rolling out gets:
  #
  #   Internal error occurred: failed calling webhook "mservice.elbv2.k8s.aws":
  #   no endpoints available for service "aws-load-balancer-webhook-service"
  #
  # cert-manager is protected by the module split (instance 2/2 below). The other
  # Service-creating charts — langfuse, milvus, gitea, the chat UI Service —
  # depend on Karpenter/EKS rather than on this module, so they are NOT ordered
  # against this controller and remain exposed to that window. Measured, they land
  # before the controller installs, so this has not fired in practice. If it starts
  # failing, the options are enableServiceMutatorWebhook=false (the webhook only
  # injects spec.loadBalancerClass into `type: LoadBalancer` Services, and this
  # cluster creates none — every ALB is built in Terraform via aws_lb +
  # TargetGroupBinding and the agentgateway data plane is pinned to ClusterIP), or
  # depends_on wiring per chart, which costs ~2 min of wall clock by pushing the
  # langfuse chain later.
  #
  # wait/wait_for_jobs: the module defaults `wait` to false (overriding the helm
  # provider's own default of true), so without this the release reports complete
  # before the controller is Ready.
  enable_aws_load_balancer_controller = true
  aws_load_balancer_controller = {
    values = [yamlencode({
      nodeSelector = { "workshop.io/node-role" = "system" }
      vpcId        = module.vpc.vpc_id
      region       = local.region
    })]
    wait          = true
    wait_for_jobs = true
  }

  tags = local.tags
}

# Instance 2/2 — cert-manager only, ordered after the LB controller is Ready.
#
# cert-manager is required by the ADOT operator addon (its admission webhooks need
# cert-manager-issued certs). Pinned to the system MNG (all three deployments:
# controller, webhook, cainjector) for the same reason as the LB controller.
#
# wait_for_jobs matters here specifically: the cert-manager chart runs a
# `startupapicheck` post-install hook Job, and without this the release reports
# complete while that check is still in flight.
module "eks_blueprints_addons_cert_manager" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "1.23.0"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  # The module creates an aws_cloudformation_stack for usage telemetry whenever
  # observability_tag is non-null (its default). With two instances of the module
  # that would be two stacks per cluster, named "<cluster>-<random hex>". Instance
  # 1/2 keeps the default; this one opts out so the telemetry stack is not
  # duplicated.
  observability_tag = null

  enable_cert_manager = true
  cert_manager = {
    values = [yamlencode({
      nodeSelector = { "workshop.io/node-role" = "system" }
      webhook      = { nodeSelector = { "workshop.io/node-role" = "system" } }
      cainjector   = { nodeSelector = { "workshop.io/node-role" = "system" } }
    })]
    wait          = true
    wait_for_jobs = true
  }

  tags = local.tags

  depends_on = [module.eks_blueprints_addons]
}

################################################################################
# ADOT - AWS Distro for OpenTelemetry operator (EKS managed addon)
#
# Installs the operator only; it does not collect telemetry until an
# OpenTelemetryCollector CR is created (workshop content). Two ordering
# prerequisites, both enforced by null_resource.wait_for_lb_controller below:
#
#   1. cert-manager must be running — the ADOT operator's admission webhooks
#      need cert-manager-issued certs.
#   2. The AWS Load Balancer Controller must be READY. It registers a
#      cluster-wide mutating webhook on Services (mservice.elbv2.k8s.aws) with
#      failurePolicy=Fail; until the controller has ready endpoints, ANY Service
#      creation — including the ADOT operator's — is rejected with
#      "no endpoints available for service aws-load-balancer-webhook-service".
#      The controller also has to be up for the TargetGroupBinding webhooks that the
#      chat UI, gitea and langfuse target groups depend on.
#
# We wait on actual readiness (condition-based) instead of a blind sleep, which
# previously raced the controller rollout and failed the addon create. This is now
# belt-and-braces: both module instances use wait = true, so each chart is already
# Ready when its instance completes. The explicit gate is retained so the ordering
# guarantee does not depend solely on a module-internal default.
################################################################################

resource "null_resource" "wait_for_lb_controller" {
  triggers = {
    cluster_name = module.eks.cluster_name
    region       = local.region
  }

  provisioner "local-exec" {
    # The CodeBuild Terraform Runner's default shell is /bin/sh (dash), which
    # rejects `set -o pipefail`. Force bash, matching langfuse.tf.
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG"
      echo "Waiting for AWS Load Balancer Controller to be Available..."
      kubectl rollout status deploy/aws-load-balancer-controller -n kube-system --timeout=10m
      echo "Waiting for cert-manager webhook to be Available..."
      kubectl rollout status deploy/cert-manager-webhook -n cert-manager --timeout=10m
    EOT
  }

  depends_on = [
    module.eks_blueprints_addons,
    module.eks_blueprints_addons_cert_manager,
  ]
}

resource "aws_eks_addon" "adot" {
  cluster_name  = module.eks.cluster_name
  addon_name    = "adot"
  addon_version = var.adot_addon_version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    null_resource.wait_for_lb_controller,
  ]

  tags = local.tags
}

# NOTE: the "alb" IngressClass is NOT defined here. The AWS Load Balancer
# Controller Helm chart creates it automatically (createIngressClassResource +
# ingressClass=alb are chart defaults), so a separate kubernetes_ingress_class_v1
# resource collides with "ingressclasses ... alb already exists". The chat UI /
# langfuse ingresses reference ingressClassName "alb"; they depend on
# module.eks_blueprints_addons (which installs the controller) to order against
# the controller-created class.

################################################################################
# EBS CSI driver - IAM role + Pod Identity association
#
# The aws-ebs-csi-driver managed addon (base.tf) needs IAM permissions to
# create/attach EBS volumes. Pod Identity binds this role to the driver's
# controller service account.
################################################################################

data "aws_iam_policy_document" "ebs_csi_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${local.name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_trust.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
}

################################################################################
# EKS - StorageClass
################################################################################

resource "kubernetes_storage_class_v1" "ebs_sc" {
  metadata {
    name = "ebs-sc"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  # ebs.csi.aws.com is the standard EBS CSI driver addon provisioner. (Auto Mode
  # used ebs.csi.eks.amazonaws.com, which does not exist on a regular cluster.)
  storage_provisioner = "ebs.csi.aws.com"
  volume_binding_mode = "WaitForFirstConsumer"

  # Stated explicitly, though "Delete" is already Kubernetes' default when the
  # field is omitted. It is the ONLY reclaim knob that exists, and it decides just
  # one thing: what happens to the PV and its EBS volume WHEN THE PVC IS DELETED.
  # It cannot cause a PVC to be deleted, so it does nothing about the volumes this
  # cluster used to leak — those leaked because nothing deleted their PVCs (charts
  # shipping helm.sh/resource-policy: keep, and StatefulSet volumeClaimTemplates
  # that Helm never owned). Those are fixed at each release; see the
  # persistentVolumeClaimRetentionPolicy / resource-policy values in the milvus
  # release below, langfuse.tf and gitea.tf.
  #
  # Note this value is copied onto each PV at provision time — editing it later
  # does not change PVs that already exist.
  reclaim_policy = "Delete"

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  # depends_on module.eks (not just the EBS-CSI pod-identity assoc) so this
  # StorageClass is created only AFTER the cluster-creator access-entry
  # association (from enable_cluster_creator_admin_permissions) is in effect.
  # Otherwise, on a first apply, the kubernetes provider can race that
  # association and hit "storageclasses.storage.k8s.io is forbidden" — which
  # leaves the cluster with no default StorageClass, so every PVC (langfuse
  # ClickHouse/Postgres/Redis, milvus, gitea) stays Pending and Karpenter never
  # provisions nodes for them.
  #
  # aws_iam_role_policy_attachment.ebs_csi is ALSO listed here, not just the
  # association: the association only binds the CSI controller's service
  # account to the role (role_arn), it grants no permissions itself — the
  # attachment is what actually lets the controller call ec2:DeleteVolume. The
  # association depends on the ROLE (role_arn), never on the ATTACHMENT, so
  # without this edge the attachment has no relationship to anything workload-
  # related and Terraform is free to detach it at any point in the destroy —
  # including before milvus/langfuse/gitea (every helm_release/kubernetes_*
  # resource that depends on this StorageClass, directly or transitively) have
  # released their PVCs, which would make every EBS DeleteVolume call fail
  # AccessDenied for the rest of the destroy.
  depends_on = [
    aws_eks_pod_identity_association.ebs_csi,
    aws_iam_role_policy_attachment.ebs_csi,
    module.eks,
  ]
}

################################################################################
# Storage reclamation barrier (destroy-time only)
#
# `helm_release`'s own `wait` (now true for milvus/langfuse) only confirms a
# release's OWN manifest resources — Deployments, StatefulSets, chart-rendered
# PVCs — return NotFound. It does NOT confirm that a StatefulSet's
# volumeClaimTemplate PVCs (postgresql, redis, clickhouse, zookeeper, milvus's
# etcd) have been garbage-collected, or that the PV — and, through the EBS CSI
# controller's DeleteVolume call, the underlying EBS volume — behind ANY of
# these PVCs has actually been reclaimed. That chain (StatefulSet gone -> PVC
# GC'd via ownerReference -> PV deleted via the ebs-sc StorageClass's Delete
# reclaimPolicy -> CSI DeleteVolume) is asynchronous and untracked by
# Terraform's graph.
#
# Without this resource, kubernetes_storage_class_v1.ebs_sc — and, through ITS
# depends_on, the EBS CSI controller's IAM role/policy-attachment/pod-identity-
# association — would be destroyed as soon as milvus/langfuse/gitea's
# helm_release resources report destroyed, which can race ahead of that
# asynchronous reclamation. If the IAM permission is pulled first, every
# DeleteVolume call for the rest of the destroy starts failing AccessDenied,
# and the PV's deletion finalizer never clears — leaking the volume
# permanently, not just delaying its cleanup.
#
# This is a pure Kubernetes-side wait: no AWS API calls, nothing deleted here.
# It blocks until no PersistentVolume remains claimed from the milvus/langfuse/
# gitea namespaces, so the graph only lets IAM be torn down once reclamation
# has actually finished.
#
# ORDERING: this resource depends_on ebs_sc (created after it, so destroyed
# BEFORE it — IAM stays intact through this wait), and each of
# helm_release.milvus/langfuse/gitea depends_on THIS resource (created after
# it, so destroyed BEFORE it — this wait only runs once all three releases are
# already gone).
################################################################################

resource "null_resource" "storage_reclaim_barrier" {
  triggers = {
    cluster_name = module.eks.cluster_name
    region       = local.region
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT

      if ! aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG" >/dev/null 2>&1 \
        || ! kubectl get --raw /readyz >/dev/null 2>&1; then
        echo "[storage-reclaim] cluster unreachable; nothing to wait for."
        exit 0
      fi

      DEADLINE=$(( $(date +%s) + 600 ))
      while :; do
        LEFT=$(kubectl get pv -o jsonpath='{range .items[*]}{.spec.claimRef.namespace}{"\n"}{end}' 2>/dev/null \
          | grep -Ex 'milvus|langfuse|gitea' | wc -l)
        [ "$LEFT" -eq 0 ] && break
        if [ "$(date +%s)" -ge "$DEADLINE" ]; then
          echo "[storage-reclaim] ERROR: gave up after 10 min: $LEFT PV(s) still claimed from milvus/langfuse/gitea." >&2
          echo "[storage-reclaim]        Re-run the destroy to retry, or inspect with: kubectl get pv" >&2
          exit 1
        fi
        echo "[storage-reclaim] $LEFT PV(s) remaining; waiting..."
        sleep 10
      done
      echo "[storage-reclaim] no PVs remain for milvus/langfuse/gitea; safe to release IAM."
    EOT
  }

  depends_on = [
    kubernetes_storage_class_v1.ebs_sc,
  ]
}

################################################################################
# Milvus - Vector Database
#
# The two plain object-storage PVCs (milvus standalone data + milvus-minio) are
# created HERE as Terraform-owned resources and handed to the chart via
# existingClaim, instead of letting the chart render them. Why: the milvus chart
# and its bundled minio subchart both default persistence.annotations to
# helm.sh/resource-policy: keep, so `helm uninstall` skips those PVCs and their
# EBS volumes leak. That annotation cannot be removed through the terraform-helm
# provider (v2.17): it drops null map values before Helm sees them, so neither a
# set{} block nor a raw-YAML null can delete a subchart's default key (verified on
# a live kind cluster — set/null leaves milvus-minio at "keep"; only helm CLI or
# provider v3 can null a subchart). Owning the PVCs sidesteps the annotation
# entirely: existingClaim makes the chart skip its own PVC and mount ours, Helm
# never manages them, and `terraform destroy` deletes them directly (ebs-sc's
# Delete reclaim then drops the volume). The etcd PVC stays chart-managed and is
# handled by its persistentVolumeClaimRetentionPolicy below.
################################################################################

resource "kubernetes_namespace_v1" "milvus" {
  metadata {
    name = "milvus"
    labels = {
      "kubernetes.io/metadata.name" = "milvus"
    }
  }
  depends_on = [module.eks]
}

# Terraform-owned PVCs for milvus standalone + minio. No resource-policy annotation,
# so nothing blocks deletion. wait_until_bound = false because ebs-sc is
# WaitForFirstConsumer: these stay Pending until the milvus pods (created by the
# helm_release that depends on them) mount them, so waiting here would deadlock.
resource "kubernetes_persistent_volume_claim_v1" "milvus_data" {
  metadata {
    name      = "milvus-data"
    namespace = kubernetes_namespace_v1.milvus.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "ebs-sc"
    resources {
      requests = { storage = "10Gi" }
    }
  }
  wait_until_bound = false
  depends_on       = [kubernetes_storage_class_v1.ebs_sc]
}

resource "kubernetes_persistent_volume_claim_v1" "milvus_minio" {
  metadata {
    name      = "milvus-minio"
    namespace = kubernetes_namespace_v1.milvus.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "ebs-sc"
    resources {
      requests = { storage = "10Gi" }
    }
  }
  wait_until_bound = false
  depends_on       = [kubernetes_storage_class_v1.ebs_sc]
}

resource "helm_release" "milvus" {
  name = "milvus"
  # Pinned: an unpinned chart resolves to whatever is latest at apply time, so a
  # values path this config relies on (e.g. the persistence/annotations blocks
  # below) can silently move or a chart default can change (see the
  # helm.sh/resource-policy history in this file) without this diff showing it.
  # Bump deliberately; `helm repo add milvus https://zilliztech.github.io/
  # milvus-helm && helm search repo milvus/milvus --versions` lists newer ones.
  version          = "5.0.25"
  repository       = "https://zilliztech.github.io/milvus-helm"
  chart            = "milvus"
  namespace        = kubernetes_namespace_v1.milvus.metadata[0].name
  create_namespace = false
  # wait: true so apply fails fast (bounded by `timeout` below) if
  # standalone/etcd/minio don't reach Ready, rather than deferring that
  # failure to whatever consumes milvus later. Same flag governs uninstall,
  # so destroy also blocks here until this release's own manifest resources
  # (including the chart-rendered PVCs milvus/milvus-minio) return NotFound —
  # though the AUTHORITATIVE destroy-time guarantee is now
  # null_resource.storage_reclaim_barrier below, which additionally waits for
  # the volumeClaimTemplate PVCs (etcd) and actual PV disappearance. Unlike
  # langfuse (langfuse.tf), there is no known stuck-pod scenario here that a
  # passive wait would get in the way of recovering from — if one turns up,
  # drop this to `wait = false` the same way, for the same reason.
  wait    = true
  timeout = 600

  values = [yamlencode({
    cluster = { enabled = false }

    standalone = {
      resources = {
        requests = { cpu = "500m", memory = "2Gi" }
        limits   = { memory = "4Gi" }
      }
      persistence = {
        enabled = true
        # Mount the Terraform-owned PVC (see header) instead of letting the chart
        # render its own keep-annotated one. existingClaim makes the chart skip PVC
        # creation entirely.
        persistentVolumeClaim = {
          existingClaim = kubernetes_persistent_volume_claim_v1.milvus_data.metadata[0].name
        }
      }
    }

    etcd = {
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/etcd"
        tag        = "3.5.21-debian-12-r0"
      }
      replicaCount = 1
      resources = {
        requests = { cpu = "250m", memory = "512Mi" }
        limits   = { memory = "1Gi" }
      }
      persistence = {
        enabled      = true
        storageClass = "ebs-sc"
        size         = "10Gi"
      }
      # data-milvus-etcd-0 is a StatefulSet volumeClaimTemplate, so HELM NEVER
      # CREATED IT and `helm uninstall` cannot delete it — no annotation helps.
      # This asks the StatefulSet controller to own the PVC (ownerReference), so
      # deleting the StatefulSet garbage-collects the PVC, which then triggers the
      # StorageClass's Delete reclaim. GA since Kubernetes 1.32 (cluster runs
      # var.cluster_version). whenScaled stays Retain: only teardown should drop
      # data, not an operational scale-down.
      persistentVolumeClaimRetentionPolicy = {
        enabled     = true
        whenScaled  = "Retain"
        whenDeleted = "Delete"
      }
    }

    minio = {
      enabled = true
      mode    = "standalone"
      resources = {
        requests = { cpu = "250m", memory = "512Mi" }
        limits   = { memory = "1Gi" }
      }
      persistence = {
        enabled = true
        # Terraform-owned PVC via existingClaim — the minio subchart's own
        # resource-policy: keep default can't be nulled through the provider, so we
        # bypass it. See the header.
        existingClaim = kubernetes_persistent_volume_claim_v1.milvus_minio.metadata[0].name
      }
    }

    pulsarv3 = { enabled = false }
    pulsar   = { enabled = false }
    kafka    = { enabled = false }
  })]

  depends_on = [
    kubernetes_storage_class_v1.ebs_sc,
    # The Terraform-owned PVCs must exist before the release mounts them, and on
    # destroy the release must be uninstalled BEFORE the PVCs are deleted (helm
    # leaves them alone; Terraform then deletes them and ebs-sc reclaims the EBS).
    kubernetes_persistent_volume_claim_v1.milvus_data,
    kubernetes_persistent_volume_claim_v1.milvus_minio,
    time_sleep.wait_60_seconds,
    # Karpenter must be ready to provision general-purpose nodes — this stack
    # does not fit on the system MNG.
    null_resource.karpenter_general_nodepool,
    # Destroy-order guard: this release must be destroyed BEFORE the storage
    # reclaim barrier's wait runs, so the barrier's own destroy always sees
    # milvus already torn down.
    null_resource.storage_reclaim_barrier,
  ]
}
