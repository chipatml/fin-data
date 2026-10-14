#!/usr/bin/env bash
# Create a Cloud Storage bucket with uniform access and public access prevention.
# Usage: create-bucket.sh [--versioning] BUCKET [LOCATION] [PROJECT_ID]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage: create-bucket.sh [--versioning] BUCKET [LOCATION] [PROJECT_ID]

  BUCKET      Bucket name, with or without the gs:// prefix
  LOCATION    Default: us-central1
  PROJECT_ID  Default: gcloud config get-value project
  --versioning  Turn on object versioning after the bucket exists

If the bucket already exists, create is skipped. Uniform bucket-level access
and public access prevention (enforced) are still applied. Versioning is
changed only when --versioning is passed; an existing bucket is not turned
back off when the flag is omitted.
EOF
}

VERSIONING=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --versioning)
      VERSIONING=1
      shift
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

BUCKET="$(normalize_bucket_name "${POSITIONAL[0]}")"
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

BUCKET_URL="gs://${BUCKET}"
if gcloud storage buckets describe "${BUCKET_URL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Bucket ${BUCKET_URL} already exists; skipping create."
  echo "Enforcing uniform bucket-level access and public access prevention on ${BUCKET_URL}."
  gcloud storage buckets update "${BUCKET_URL}" \
    --project="${PROJECT_ID}" \
    --uniform-bucket-level-access \
    --public-access-prevention
else
  echo "Creating ${BUCKET_URL} in ${LOCATION} (project ${PROJECT_ID})."
  gcloud storage buckets create "${BUCKET_URL}" \
    --project="${PROJECT_ID}" \
    --location="${LOCATION}" \
    --uniform-bucket-level-access \
    --public-access-prevention
fi

if [[ "${VERSIONING}" -eq 1 ]]; then
  echo "Enabling object versioning on ${BUCKET_URL}."
  gcloud storage buckets update "${BUCKET_URL}" \
    --project="${PROJECT_ID}" \
    --versioning
fi

echo "Bucket ${BUCKET_URL} is ready."
