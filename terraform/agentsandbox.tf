################################################################################
# agent-sandbox platform — vends kata-fc Firecracker microVMs for code execution
#
# Installs (vendored, pinned v0.5.0) the controller + CRDs, the sandbox-router,
# and a kata-fc-backed SandboxTemplate + WarmPool. Sits ON TOP of the existing
# kata-fc RuntimeClass (karpenter.tf) — every vended sandbox is a Firecracker
# microVM on the nested-virt pool. The module-900 broker (code-executor MCP)
# creates SandboxClaims against this platform.
#
# Install method + ordering mirror gateways.tf / observability.tf: null_resource
# + kubectl, wait for CRDs Established and the controller/router Available before
# applying dependent CRs, ordered destroy. Images come from our ECR mirror
# (codebuild-images.tf), so __ECR__ is sed'd in and nothing pulls from
# registry.k8s.io / GCP at runtime.
################################################################################

locals {
  agentsandbox_manifest_dir = "${path.module}/manifests/agentsandbox"
  ecr_registry_base         = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com"
  sandbox_router_image      = "${local.ecr_registry_base}/sandbox-router:v0.5.0"
}

resource "null_resource" "agent_sandbox" {
  triggers = {
    cluster_name  = module.eks.cluster_name
    region        = local.region
    ecr           = local.ecr_registry_base
    router_image  = local.sandbox_router_image
    manifest_dir  = local.agentsandbox_manifest_dir
    manifest_hash = "${filemd5("${local.agentsandbox_manifest_dir}/manifest.yaml")}-${filemd5("${local.agentsandbox_manifest_dir}/extensions.yaml")}-${filemd5("${local.agentsandbox_manifest_dir}/sandbox_router.yaml")}-${filemd5("${local.agentsandbox_manifest_dir}/router-ingress-networkpolicy.yaml")}-${filemd5("${local.agentsandbox_manifest_dir}/sandboxtemplate-kata-fc.yaml")}-${filemd5("${local.agentsandbox_manifest_dir}/sandboxwarmpool-kata-fc.yaml")}-${filemd5("${local.agentsandbox_manifest_dir}/sandbox-airgap-networkpolicy.yaml")}-${filemd5("${local.agentsandbox_manifest_dir}/sandboxtemplate-kata-fc-coding.yaml")}-${filemd5("${local.agentsandbox_manifest_dir}/sandboxwarmpool-kata-fc-coding.yaml")}-${filemd5("${local.agentsandbox_manifest_dir}/sandbox-coding-egress-networkpolicy.yaml")}"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG"
      MANIFESTS="${self.triggers.manifest_dir}"
      ECR="${self.triggers.ecr}"

      # 1. Controller + core CRDs (image repointed to our ECR mirror).
      sed "s|__ECR__|$ECR|g" "$MANIFESTS/manifest.yaml" | kubectl apply --server-side -f -
      # 2. Extensions (SandboxTemplate/WarmPool/Claim CRDs + controller).
      sed "s|__ECR__|$ECR|g" "$MANIFESTS/extensions.yaml" | kubectl apply --server-side -f -

      # 3. Wait for the CRDs to be Established before applying any CR.
      kubectl wait --for=condition=Established --timeout=120s \
        crd/sandboxes.agents.x-k8s.io \
        crd/sandboxtemplates.extensions.agents.x-k8s.io \
        crd/sandboxwarmpools.extensions.agents.x-k8s.io \
        crd/sandboxclaims.extensions.agents.x-k8s.io

      # 4. Wait for the controller Deployment(s) to be Available.
      kubectl rollout status -n agent-sandbox-system deploy --timeout=180s || true
      kubectl wait --for=condition=Available --timeout=180s \
        -n agent-sandbox-system deploy --all

      # 5. Sandbox namespace (Template/WarmPool/Claims live here).
      kubectl create namespace agent-sandbox --dry-run=client -o yaml | kubectl apply -f -
      # Ensure the metadata.name label exists (some clusters don't auto-add it)
      # so the sandbox NetworkPolicy namespaceSelector matches.
      kubectl label namespace agent-sandbox kubernetes.io/metadata.name=agent-sandbox --overwrite

      # 6. Router (image sed'd in) + ingress lock, in agent-sandbox-system.
      sed "s|\$${ROUTER_IMAGE}|${self.triggers.router_image}|g" "$MANIFESTS/sandbox_router.yaml" \
        | kubectl apply -n agent-sandbox-system -f -
      kubectl apply -f "$MANIFESTS/router-ingress-networkpolicy.yaml"
      kubectl wait --for=condition=Available --timeout=180s \
        -n agent-sandbox-system deploy/sandbox-router-deployment

      # 7. SandboxTemplate + WarmPool (image sed'd) — warms microVMs.
      sed "s|__ECR__|$ECR|g" "$MANIFESTS/sandboxtemplate-kata-fc.yaml" | kubectl apply -f -
      kubectl apply -f "$MANIFESTS/sandboxwarmpool-kata-fc.yaml"

      # 7b. Coding template + warmpool + egress lock (module 1000).
      sed "s|__ECR__|$ECR|g" "$MANIFESTS/sandboxtemplate-kata-fc-coding.yaml" | kubectl apply -f -
      kubectl apply -f "$MANIFESTS/sandboxwarmpool-kata-fc-coding.yaml"
      kubectl apply -f "$MANIFESTS/sandbox-coding-egress-networkpolicy.yaml"

      # 8. Supplemental air-gap NetworkPolicy. The controller's generated policy
      #    selects a label warm-pool pods don't carry (v0.5.0), so it enforces
      #    nothing; this one selects agents.x-k8s.io/warm-pool-sandbox and applies
      #    the real egress:[] air-gap. See the manifest header for detail.
      kubectl apply -f "$MANIFESTS/sandbox-airgap-networkpolicy.yaml"
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG" || exit 0
      kubectl delete networkpolicy kata-fc-coding-egress -n agent-sandbox --ignore-not-found --timeout=60s || true
      kubectl delete sandboxwarmpool kata-fc-coding-pool -n agent-sandbox --ignore-not-found --timeout=60s || true
      kubectl delete sandboxtemplate kata-fc-coding -n agent-sandbox --ignore-not-found --timeout=60s || true
      kubectl delete sandboxwarmpool kata-fc-python-pool -n agent-sandbox --ignore-not-found --timeout=60s || true
      kubectl delete sandboxtemplate kata-fc-python -n agent-sandbox --ignore-not-found --timeout=60s || true
      kubectl delete sandboxclaim --all -n agent-sandbox --ignore-not-found --timeout=60s || true
      kubectl delete networkpolicy kata-fc-python-airgap -n agent-sandbox --ignore-not-found --timeout=60s || true
      kubectl delete networkpolicy sandbox-router-ingress -n agent-sandbox-system --ignore-not-found --timeout=60s || true
      kubectl delete deploy sandbox-router-deployment -n agent-sandbox-system --ignore-not-found --timeout=60s || true
      # kubectl delete waits by default. Bound it: a Sandbox/warm-pool object whose
      # controller is already gone keeps its finalizer forever, and an unbounded
      # namespace delete would then hang the whole destroy.
      kubectl delete namespace agent-sandbox --ignore-not-found --timeout=120s || true
    EOT
  }

  depends_on = [
    # RuntimeClass kata-fc must exist (the Template references it).
    null_resource.karpenter_kata_fc,
    # Images must be in ECR before the controller/router/sandboxes pull them.
    null_resource.build_images,
    module.eks,
  ]
}
