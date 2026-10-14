#!/usr/bin/env bash
# Create a bucket, a service account, bucket IAM, and the org environment tag.
# Usage: setup-all.sh [--versioning] [--readonly] [--key FILE] [--sa-name NAME] [--display-name TEXT] [--env VALUE] BUCKET [LOCATION] [PROJECT_ID]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage: setup-all.sh [options] BUCKET [LOCATION] [PROJECT_ID]

Chains create-bucket.sh, create-service-account.sh, grant-bucket-access.sh,
and add-env-tag.sh.

  BUCKET       Bucket name
  LOCATION     Default: us-central1
  PROJECT_ID   Default: gcloud config get-value project
  --sa-name NAME         Default: finagent-gcs
  --display-name TEXT    Passed through to create-service-account.sh
  --env VALUE            Production, Development, Test, or Staging.
                         Default: Development
  --key FILE             Write a JSON key, chmod 600, and print the delete reminder
  --readonly             Grant roles/storage.objectViewer (default is readwrite)
  --versioning           Enable object versioning on the bucket

Read-write grants roles/storage.objectAdmin, which FinAgent needs to upload
day files. Use --readonly for a viewer account instead.
EOF
}

VERSIONING=0
READONLY=0
KEY_OUT=""
SA_NAME="finagent-gcs"
DISPLAY_NAME=""
ENV_VALUE="Development"
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --versioning)
      VERSIONING=1
      shift
      ;;
    --readonly)
      READONLY=1
      shift
      ;;
    --key)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "--key requires an output path." >&2
        exit 1
      fi
      KEY_OUT="$2"
      shift 2
      ;;
    --sa-name)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "--sa-name requires an account id." >&2
        exit 1
      fi
      SA_NAME="$2"
      shift 2
      ;;
    --display-name)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo "--display-name requires text." >&2
        exit 1
      fi
      DISPLAY_NAME="$2"
      shift 2
      ;;
    --env)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "--env requires Production, Development, Test, or Staging." >&2
        exit 1
      fi
      ENV_VALUE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      POSITIONAL+=("$@")
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [[ ${#POSITIONAL[@]} -lt 1 || ${#POSITIONAL[@]} -gt 3 ]]; then
  echo "Expected BUCKET [LOCATION] [PROJECT_ID]." >&2
  usage >&2
  exit 1
fi

case "${ENV_VALUE}" in
  Production|Development|Test|Staging) ;;
  *)
    echo "ENV_VALUE must be one of: Production, Development, Test, Staging." >&2
    exit 1
    ;;
esac

BUCKET="${POSITIONAL[0]}"
LOCATION="us-central1"
if [[ ${#POSITIONAL[@]} -ge 2 ]]; then
  LOCATION="${POSITIONAL[1]}"
fi
PROJECT_ID=""
if [[ ${#POSITIONAL[@]} -ge 3 ]]; then
  PROJECT_ID="${POSITIONAL[2]}"
fi

require_gcloud
if [[ -z "${PROJECT_ID}" ]]; then
  PROJECT_ID="$(project_from_config)"
fi

bucket_cmd=("${SCRIPT_DIR}/create-bucket.sh")
if [[ "${VERSIONING}" -eq 1 ]]; then
  bucket_cmd+=(--versioning)
fi
bucket_cmd+=("${BUCKET}" "${LOCATION}" "${PROJECT_ID}")
"${bucket_cmd[@]}"

sa_cmd=("${SCRIPT_DIR}/create-service-account.sh")
if [[ -n "${KEY_OUT}" ]]; then
  sa_cmd+=(--key "${KEY_OUT}")
fi
if [[ -n "${DISPLAY_NAME}" ]]; then
  sa_cmd+=(--display-name "${DISPLAY_NAME}")
fi
sa_cmd+=("${SA_NAME}" "${PROJECT_ID}")
"${sa_cmd[@]}"

access_flag="--readwrite"
if [[ "${READONLY}" -eq 1 ]]; then
  access_flag="--readonly"
fi
"${SCRIPT_DIR}/grant-bucket-access.sh" \
  "${BUCKET}" \
  "${SA_NAME}" \
  "${access_flag}" \
  --project "${PROJECT_ID}"

"${SCRIPT_DIR}/add-env-tag.sh" "${ENV_VALUE}" "${PROJECT_ID}"

echo "Setup finished for project ${PROJECT_ID}, bucket ${BUCKET}, service account ${SA_NAME}."
