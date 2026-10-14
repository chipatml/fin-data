#!/usr/bin/env bash
# Create a GCP service account, and optionally a JSON key for FinAgent.
# Usage: create-service-account.sh [--key OUTFILE] [--display-name TEXT] SA_NAME [PROJECT_ID]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage: create-service-account.sh [--key OUTFILE] [--display-name TEXT] SA_NAME [PROJECT_ID]

  SA_NAME      Service account id (not the email). Example: finagent-gcs
  PROJECT_ID   Default: gcloud config get-value project
  --key FILE   Write a JSON key to FILE (mode 600). Import it into FinAgent,
               then delete the file. A new key is created on every run.
  --display-name TEXT
               Default: SA_NAME. Applied on create. On an existing account it
               is updated only when this flag is passed.

Creating the account is idempotent. Writing a key is not: each --key run mints
a new key, and the script refuses to overwrite an existing outfile.
EOF
}

KEY_OUT=""
DISPLAY_NAME=""
DISPLAY_NAME_SET=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "--key requires an output path." >&2
        exit 1
      fi
      KEY_OUT="$2"
      shift 2
      ;;
    --display-name)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo "--display-name requires text." >&2
        exit 1
      fi
      DISPLAY_NAME="$2"
      DISPLAY_NAME_SET=1
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

if [[ ${#POSITIONAL[@]} -lt 1 || ${#POSITIONAL[@]} -gt 2 ]]; then
  echo "Expected SA_NAME [PROJECT_ID]." >&2
  usage >&2
  exit 1
fi

SA_NAME="${POSITIONAL[0]}"
PROJECT_ID=""
if [[ ${#POSITIONAL[@]} -ge 2 ]]; then
  PROJECT_ID="${POSITIONAL[1]}"
fi

if [[ "${SA_NAME}" == *"@"* || "${SA_NAME}" == *"/"* || -z "${SA_NAME}" ]]; then
  echo "SA_NAME must be the account id, not an email or path: ${SA_NAME}" >&2
  exit 1
fi

if [[ "${DISPLAY_NAME_SET}" -eq 0 ]]; then
  DISPLAY_NAME="${SA_NAME}"
fi

if [[ -n "${KEY_OUT}" ]]; then
  if [[ -e "${KEY_OUT}" ]]; then
    echo "Refusing to overwrite existing key file: ${KEY_OUT}" >&2
    exit 1
  fi
  key_dir="$(dirname "${KEY_OUT}")"
  if [[ ! -d "${key_dir}" ]]; then
    echo "Key output directory does not exist: ${key_dir}" >&2
    exit 1
  fi
fi

require_gcloud
if [[ -z "${PROJECT_ID}" ]]; then
  PROJECT_ID="$(project_from_config)"
fi

SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Service account ${SA_EMAIL} already exists; skipping create."
  if [[ "${DISPLAY_NAME_SET}" -eq 1 ]]; then
    gcloud iam service-accounts update "${SA_EMAIL}" \
      --project="${PROJECT_ID}" \
      --display-name="${DISPLAY_NAME}"
  fi
else
  echo "Creating service account ${SA_EMAIL}"
  gcloud iam service-accounts create "${SA_NAME}" \
    --project="${PROJECT_ID}" \
    --display-name="${DISPLAY_NAME}"
fi

if [[ -n "${KEY_OUT}" ]]; then
  echo "Writing a new JSON key to ${KEY_OUT}"
  umask 077
  gcloud iam service-accounts keys create "${KEY_OUT}" \
    --iam-account="${SA_EMAIL}" \
    --project="${PROJECT_ID}"
  chmod 600 "${KEY_OUT}"
  cat <<EOF

Import this JSON key into FinAgent (Cloud Storage panel). The app stores it in the Keychain, not in git.
Then delete the file:
  rm -f '${KEY_OUT}'
EOF
fi

echo "Service account: ${SA_EMAIL}"
