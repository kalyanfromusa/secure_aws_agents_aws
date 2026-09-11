#!/usr/bin/env bash
#
# Starts the image pre-build CodeBuild project and waits for completion.
# Used by terraform/codebuild-images.tf via a null_resource local-exec.
#
# Usage: run-codebuild.sh <project-name> <region>
#
# Requires only the AWS CLI (already a hard dependency of this Terraform
# config, see base.tf which shells out to `aws eks get-token`). No local
# Docker daemon is needed because the build runs inside CodeBuild.

set -eu

PROJECT="${1:?project name required}"
REGION="${2:?region required}"
POLL_SECONDS="${POLL_SECONDS:-15}"

echo "Starting CodeBuild project: ${PROJECT} (region ${REGION})"

BUILD_ID="$(aws codebuild start-build \
  --project-name "${PROJECT}" \
  --region "${REGION}" \
  --query 'build.id' \
  --output text)"

echo "CodeBuild started: ${BUILD_ID}"
echo "Logs: https://${REGION}.console.aws.amazon.com/codesuite/codebuild/projects/${PROJECT}/build/${BUILD_ID}"

while true; do
  STATUS="$(aws codebuild batch-get-builds \
    --ids "${BUILD_ID}" \
    --region "${REGION}" \
    --query 'builds[0].buildStatus' \
    --output text)"

  case "${STATUS}" in
    SUCCEEDED)
      echo "Image pre-build SUCCEEDED."
      exit 0
      ;;
    FAILED | FAULT | STOPPED | TIMED_OUT)
      echo "Image pre-build ${STATUS}. See CodeBuild logs above." >&2
      exit 1
      ;;
    *)
      echo "  build status: ${STATUS} (polling every ${POLL_SECONDS}s)..."
      sleep "${POLL_SECONDS}"
      ;;
  esac
done
