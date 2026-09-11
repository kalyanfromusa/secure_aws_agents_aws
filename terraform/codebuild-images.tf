################################################################################
# Pre-build module container images via CodeBuild
#
# Motivation: every lab has participants run essentially the same
# `docker build --push` against the customer-agent / mcp-server / *-agent ECR
# repos, just with a different module tag. From lab 2 onward that build step is
# repetitive friction, and a fresh event has NO images in ECR until someone
# builds them (the kubectl-apply manifests reference tags like
# customer-agent:mcp / mcp-server:v1 that would not exist yet). This builds all
# module images up front so the labs are turnkey (kubectl apply just pulls),
# while the lab content keeps the build step as an optional exercise.
#
# Why CodeBuild (not local docker / null_resource): the Terraform host (the CDK
# Terraform Runner / browser IDE) may not have a usable Docker daemon. CodeBuild
# runs the builds in AWS with a privileged Docker environment, so provisioning
# only needs the AWS CLI, which is already a hard dependency.
#
# The matrix below MUST stay in sync with the `image:` refs in the module
# k8s manifests (modules/**/k8s*.yaml).
################################################################################

variable "prebuild_images" {
  description = "Build and push all module container images into ECR at provision time via CodeBuild."
  type        = bool
  default     = true
}

variable "modules_zip_s3_uri" {
  description = <<-EOT
    S3 URI (s3://bucket/key) of the published modules.zip. In the real workshop
    this is injected by the CDK Terraform Runner (TF_VAR_modules_zip_s3_uri) and
    points at the assets bucket. When empty (e.g. local `terraform apply`),
    Terraform zips ../modules and uploads it to a bucket it creates instead.
  EOT
  type        = string
  default     = ""
}

locals {
  # The directory containing all module source (Dockerfiles + app code).
  modules_dir = "${path.module}/../modules"

  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com"

  # When a modules.zip S3 URI is supplied (workshop runner), the CodeBuild job
  # pulls it from S3. Otherwise (local dev) we zip ../modules and upload it.
  use_s3_source = var.modules_zip_s3_uri != ""

  # Final S3 URI the buildspec downloads module source from.
  modules_zip_uri = local.use_s3_source ? var.modules_zip_s3_uri : try("s3://${aws_s3_bucket.image_build_source[0].bucket}/${aws_s3_object.modules_src[0].key}", "")

  # Bucket name + ARN parsed from the URI, used to scope the CodeBuild read
  # permission for either source mode.
  modules_src_bucket     = local.use_s3_source ? split("/", replace(var.modules_zip_s3_uri, "s3://", ""))[0] : try(aws_s3_bucket.image_build_source[0].bucket, "")
  modules_src_bucket_arn = "arn:${data.aws_partition.current.partition}:s3:::${local.modules_src_bucket}"

  # Image build matrix: one entry per `docker build --push` in the lab content.
  # context    = path under modules/ holding the Dockerfile + sources
  # repo       = ECR repository (must exist in ecr.tf)
  # tag        = module-specific image tag
  # dockerfile = filename when not the default "Dockerfile"
  #
  # Every tag here MUST match the `image:` refs in the module k8s manifests.
  image_builds = {
    "customer-agent:strands" = {
      context = "200-strands-agents/customer-agent"
      repo    = "customer-agent"
      tag     = "strands"
    }
    "customer-agent:langfuse" = {
      context = "300-observability-langfuse/customer-agent"
      repo    = "customer-agent"
      tag     = "langfuse"
    }
    "mcp-server:v1" = {
      context = "500-agent-tools-mcp/mcp-server"
      repo    = "mcp-server"
      tag     = "v1"
    }
    "customer-agent:mcp" = {
      context = "500-agent-tools-mcp/customer-agent"
      repo    = "customer-agent"
      tag     = "mcp"
    }
    "order-agent:v1" = {
      context    = "600-multi-agent-a2a/a2a-agents"
      repo       = "order-agent"
      tag        = "v1"
      dockerfile = "Dockerfile.order"
    }
    "product-agent:v1" = {
      context    = "600-multi-agent-a2a/a2a-agents"
      repo       = "product-agent"
      tag        = "v1"
      dockerfile = "Dockerfile.product"
    }
    "orchestrator-agent:v1" = {
      context    = "600-multi-agent-a2a/a2a-agents"
      repo       = "orchestrator-agent"
      tag        = "v1"
      dockerfile = "Dockerfile.orchestrator"
    }
    "code-executor-mcp:v1" = {
      context = "900-sandboxed-code-exec/code-executor-mcp"
      repo    = "code-executor-mcp"
      tag     = "v1"
    }
    # v0.5.3: sets MPLCONFIGDIR so matplotlib stops warning about the
    # unwritable /.config on every import. v0.5.2 added matplotlib (+ its
    # subtree) so LLM-written analysis code can render charts to
    # /app/chart.png, read back and shown inline in the UI. v0.5.1 added
    # tabulate (pandas' to_markdown dep). Bump the tag on runtime changes:
    # sandbox pods pull IfNotPresent, so an overwritten tag never reaches nodes
    # that have the old image cached.
    "python-runtime-sandbox:v0.5.3" = {
      context = "900-sandboxed-code-exec/python-runtime-sandbox"
      repo    = "python-runtime-sandbox"
      tag     = "v0.5.3"
    }
    "customer-agent:code-exec" = {
      context = "500-agent-tools-mcp/customer-agent"
      repo    = "customer-agent"
      tag     = "code-exec"
    }
    # module 1000: coding runtime (SDK server + Claude Code) + the dispatcher.
    # runtime v2: pre-bakes pytest+httpx. dispatcher v4: run.sh gained the global
    # gitignore guard, pytest-summary-in-PR, the </dev/null stdin fix for headless
    # Claude Code, and a push gate that works whether Claude commits its own work
    # or the wrapper commits. The two images version independently.
    "coding-runtime-sandbox:v2" = {
      context = "1000-autonomous-coding-agent/coding-runtime-sandbox"
      repo    = "coding-runtime-sandbox"
      tag     = "v2"
    }
    "coding-agent-dispatcher:v4" = {
      context = "1000-autonomous-coding-agent/coding-agent-dispatcher"
      repo    = "coding-agent-dispatcher"
      tag     = "v4"
    }
  }
}

################################################################################
# Source bundle (local-dev fallback only): zip modules/ and upload to S3.
# Skipped when modules_zip_s3_uri is provided (the workshop runner path), since
# the runner has no ../modules directory next to the Terraform code.
################################################################################

resource "aws_s3_bucket" "image_build_source" {
  count = var.prebuild_images && !local.use_s3_source ? 1 : 0

  bucket        = "${local.name}-image-build-src-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "image_build_source" {
  count = var.prebuild_images && !local.use_s3_source ? 1 : 0

  bucket                  = aws_s3_bucket.image_build_source[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Zip the modules directory. archive_file recomputes the hash on every plan,
# so edits to module source produce a new object and re-trigger the build.
data "archive_file" "modules" {
  count = var.prebuild_images && !local.use_s3_source ? 1 : 0

  type        = "zip"
  source_dir  = local.modules_dir
  output_path = "${path.module}/.terraform/tmp/modules-src.zip"
}

resource "aws_s3_object" "modules_src" {
  count = var.prebuild_images && !local.use_s3_source ? 1 : 0

  bucket = aws_s3_bucket.image_build_source[0].id
  key    = "modules-src-${data.archive_file.modules[0].output_md5}.zip"
  source = data.archive_file.modules[0].output_path
  etag   = data.archive_file.modules[0].output_md5
  tags   = local.tags
}

################################################################################
# IAM role for CodeBuild: ECR push + CloudWatch Logs + read source bucket
################################################################################

data "aws_iam_policy_document" "codebuild_assume" {
  count = var.prebuild_images ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild_images" {
  count = var.prebuild_images ? 1 : 0

  name               = "${local.name}-image-prebuild"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume[0].json
  tags               = local.tags
}

data "aws_iam_policy_document" "codebuild_images" {
  count = var.prebuild_images ? 1 : 0

  # ECR auth token is account-wide (no resource scoping possible).
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Push/pull scoped to the workshop repos created in ecr.tf.
  statement {
    sid    = "EcrPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [for r in aws_ecr_repository.this : r.arn]
  }

  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:logs:${local.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${local.name}-image-prebuild*"]
  }

  statement {
    sid       = "SourceBucket"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${local.modules_src_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "codebuild_images" {
  count = var.prebuild_images ? 1 : 0

  name   = "image-prebuild"
  role   = aws_iam_role.codebuild_images[0].id
  policy = data.aws_iam_policy_document.codebuild_images[0].json
}

################################################################################
# CodeBuild project: builds + pushes every image in local.image_builds
################################################################################

resource "aws_codebuild_project" "images" {
  count = var.prebuild_images ? 1 : 0

  name         = "${local.name}-image-prebuild"
  description  = "Pre-builds all workshop module container images and pushes them to ECR."
  service_role = aws_iam_role.codebuild_images[0].arn

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_MEDIUM"
    image           = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # required for Docker builds

    environment_variable {
      name  = "ECR_REGISTRY"
      value = local.ecr_registry
    }
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = local.region
    }
    environment_variable {
      name  = "MODULES_ZIP_URI"
      value = local.modules_zip_uri
    }
  }

  source {
    type      = "NO_SOURCE"
    buildspec = local.image_buildspec
  }

  tags = local.tags
}

# Buildspec generated from the image matrix. The module source is pulled from
# S3 (aws s3 cp works cross-region, unlike a native CodeBuild S3 source) and
# unzipped to /tmp/modules. Each image is then built + pushed from there.
locals {
  # Every build and mirror is RETRIED. These commands pull from public networks
  # (PyPI, npm, Debian, Docker Hub, registry.k8s.io), and a single transient
  # upstream hiccup otherwise fails the whole provision: an observed run died on
  # "Could not install packages due to an OSError ... too many 502 error responses"
  # from files.pythonhosted.org, which took down the entire apply because
  # agent_sandbox and gitea both depend on this resource. pip's own --retries did
  # not help (PyPI kept 502ing), so the retry has to wrap the whole build.
  image_retry_prefix = "for attempt in 1 2 3; do "
  image_retry_suffix = " && break; if [ \"$attempt\" = 3 ]; then echo 'FAILED after 3 attempts'; exit 1; fi; echo \"attempt $attempt failed, retrying in 20s...\"; sleep 20; done"

  image_build_lines = [
    for name, b in local.image_builds :
    "${local.image_retry_prefix}docker build --push -t $ECR_REGISTRY/${b.repo}:${b.tag} -f /tmp/modules/${b.context}/${lookup(b, "dockerfile", "Dockerfile")} /tmp/modules/${b.context}${local.image_retry_suffix}"
  ]

  # Upstream agent-sandbox images to mirror into ECR (pinned tags), so runtime
  # pulls never hit registry.k8s.io / GCP. crane copies without a local daemon.
  image_mirror_commands = [
    "crane copy registry.k8s.io/agent-sandbox/agent-sandbox-controller:v0.5.0 $ECR_REGISTRY/agent-sandbox-controller:v0.5.0",
    "crane copy us-central1-docker.pkg.dev/k8s-staging-images/agent-sandbox/sandbox-router:latest-main $ECR_REGISTRY/sandbox-router:v0.5.0",
    # module 1000: mirror the Gitea image so the Helm release pulls from ECR.
    # Both tags: the chart default (rootless=true) pulls the "-rootless" variant;
    # the plain tag is kept for rootless=false setups.
    "crane copy docker.io/gitea/gitea:1.24.3 $ECR_REGISTRY/gitea:1.24.3",
    "crane copy docker.io/gitea/gitea:1.24.3-rootless $ECR_REGISTRY/gitea:1.24.3-rootless",
  ]

  image_mirror_lines = [
    for c in local.image_mirror_commands :
    "${local.image_retry_prefix}${c}${local.image_retry_suffix}"
  ]

  image_buildspec = yamlencode({
    version = "0.2"
    phases = {
      pre_build = {
        commands = [
          "echo Logging in to ECR...",
          "aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY",
          # crane comes from a GitHub release, so it is exposed to the same
          # per-IP 429 that broke the CRD fetches (this runs from CodeBuild's
          # shared NAT egress). --retry-all-errors covers 429/5xx, not just
          # connection failures.
          "curl -sSL --fail --retry 5 --retry-delay 3 --retry-all-errors https://github.com/google/go-containerregistry/releases/download/v0.20.2/go-containerregistry_Linux_x86_64.tar.gz | tar -xz -C /usr/local/bin crane",
          "docker buildx create --use --name workshop-builder || docker buildx use workshop-builder",
          "echo \"Fetching module source from $MODULES_ZIP_URI\"",
          "aws s3 cp \"$MODULES_ZIP_URI\" /tmp/modules.zip",
          "rm -rf /tmp/modules && mkdir -p /tmp/modules",
          "unzip -q /tmp/modules.zip -d /tmp/modules",
        ]
      }
      build = {
        commands = concat(
          ["echo Mirroring ${length(local.image_mirror_lines)} upstream images..."],
          local.image_mirror_lines,
          ["echo Building ${length(local.image_build_lines)} images..."],
          local.image_build_lines,
        )
      }
      post_build = {
        commands = ["echo All images built and pushed."]
      }
    }
  })
}

################################################################################
# Trigger the build during apply and wait for it to finish.
#
# Re-runs whenever the module source bundle changes (the S3 key embeds the
# content hash). Depends on the ECR repos so push targets exist.
################################################################################

resource "null_resource" "build_images" {
  count = var.prebuild_images ? 1 : 0

  triggers = {
    # In S3-source mode the URI changes when a new modules.zip is published;
    # in local mode the archive hash changes when ../modules changes.
    source_ref     = local.use_s3_source ? var.modules_zip_s3_uri : data.archive_file.modules[0].output_md5
    project        = aws_codebuild_project.images[0].name
    buildspec_hash = sha1(local.image_buildspec)
  }

  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "-c"]
    command     = "bash ${path.module}/scripts/run-codebuild.sh ${aws_codebuild_project.images[0].name} ${local.region}"
  }

  depends_on = [
    aws_ecr_repository.this,
    aws_codebuild_project.images,
    aws_iam_role_policy.codebuild_images,
  ]
}
