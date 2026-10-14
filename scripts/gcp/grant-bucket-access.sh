#!/usr/bin/env bash
# Grant or revoke Cloud Storage object access for a service account.
# Usage: grant-bucket-access.sh BUCKET SA_EMAIL_or_NAME (--readonly|--readwrite) [--revoke] [--project PROJECT_ID]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage: grant-bucket-access.sh BUCKET SA_EMAIL_or_NAME (--readonly|--readwrite) [--revoke] [--project PROJECT_ID]

  BUCKET             Bucket name, with or without gs://
  SA_EMAIL_or_NAME   Account id (finagent-gcs) or full service account email
  --readonly         roles/storage.objectViewer
  --readwrite        roles/storage.objectAdmin
  --revoke           Remove that role instead of granting it
  --project ID       Project used to expand a short account name.
                     Default: gcloud config get-value project.
                     Not required when SA_EMAIL_or_NAME is already an email.

Pass exactly one of --readonly or --readwrite. Granting a role that is already
present, or revoking one that is absent, is a no-op.
EOF
}

MODE=""
REVOKE=0
PROJECT_ID=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --readonly)
      if [[ -n "${MODE}" ]]; then
        echo "Pass exactly one of --readonly or --readwrite." >&2
        exit 1
      fi
      MODE="readonly"
      shift
      ;;
    --readwrite)
      if [[ -n "${MODE}" ]]; then
        echo "Pass exactly one of --readonly or --readwrite." >&2
        exit 1
      fi
      MODE="readwrite"
      shift
      ;;
    --revoke)
      REVOKE=1
      shift
      ;;
    --project)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "--project requires a project id." >&2
        exit 1
      fi
      PROJECT_ID="$2"
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

if [[ ${#POSITIONAL[@]} -ne 2 ]]; then
  echo "Expected BUCKET and SA_EMAIL_or_NAME." >&2
  usage >&2
  exit 1
fi

case "${MODE}" in
  readonly) ROLE="roles/storage.objectViewer" ;;
  readwrite) ROLE="roles/storage.objectAdmin" ;;
  *)
    echo "Pass exactly one of --readonly or --readwrite." >&2
    usage >&2
    exit 1
    ;;
esac

BUCKET="$(normalize_bucket_name "${POSITIONAL[0]}")"
SA_REF="${POSITIONAL[1]}"
require_gcloud

if [[ "${SA_REF}" == *"@"* ]]; then
  SA_EMAIL="${SA_REF}"
elif [[ -z "${SA_REF}" || "${SA_REF}" == *"/"* ]]; then
  echo "Service account must be an account id or an email." >&2
  exit 1
else
  if [[ -z "${PROJECT_ID}" ]]; then
    PROJECT_ID="$(project_from_config)"
  fi
  SA_EMAIL="${SA_REF}@${PROJECT_ID}.iam.gserviceaccount.com"
fi

MEMBER="serviceAccount:${SA_EMAIL}"
BUCKET_URL="gs://${BUCKET}"

project_args=()
if [[ -n "${PROJECT_ID}" ]]; then
  project_args=(--project="${PROJECT_ID}")
fi

rows="$(gcloud storage buckets get-iam-policy "${BUCKET_URL}" \
  "${project_args[@]}" \
  --flatten="bindings[].members" \
  --format="csv[no-heading](bindings.role,bindings.members)")"

already=0
if printf '%s\n' "${rows}" | grep -F -x -q "${ROLE},${MEMBER}"; then
  already=1
fi

if [[ "${REVOKE}" -eq 1 ]]; then
  if [[ "${already}" -eq 0 ]]; then
    echo "${ROLE} is not bound for ${SA_EMAIL} on ${BUCKET_URL}; nothing to revoke."
    exit 0
  fi
  echo "Removing ${ROLE} from ${SA_EMAIL} on ${BUCKET_URL}"
  gcloud storage buckets remove-iam-policy-binding "${BUCKET_URL}" \
    "${project_args[@]}" \
    --member="${MEMBER}" \
    --role="${ROLE}"
  echo "Revoked ${ROLE} on ${BUCKET_URL}."
  exit 0
fi

if [[ "${already}" -eq 1 ]]; then
  echo "${ROLE} is already bound for ${SA_EMAIL} on ${BUCKET_URL}."
  exit 0
fi

echo "Granting ${ROLE} to ${SA_EMAIL} on ${BUCKET_URL}"
gcloud storage buckets add-iam-policy-binding "${BUCKET_URL}" \
  "${project_args[@]}" \
  --member="${MEMBER}" \
  --role="${ROLE}"
echo "Granted ${ROLE} on ${BUCKET_URL}."
