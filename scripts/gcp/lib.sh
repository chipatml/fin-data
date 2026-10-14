# Shared helpers for the scripts in this directory.
# Source this file from another script. Do not execute it directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "Source scripts/gcp/lib.sh from another script; do not run it directly." >&2
  exit 1
fi

# Fail closed if gcloud would otherwise wait for an interactive prompt.
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

require_gcloud() {
  if ! command -v gcloud >/dev/null 2>&1; then
    echo "gcloud is not installed or not on PATH." >&2
    exit 1
  fi
}

# Active project from gcloud config. Empty and "(unset)" are errors.
project_from_config() {
  local project
  project="$(gcloud config get-value project 2>/dev/null || true)"
  if [[ -z "${project}" || "${project}" == "(unset)" ]]; then
    echo "No project id. Pass one as an argument, or run: gcloud config set project PROJECT_ID" >&2
    exit 1
  fi
  printf '%s\n' "${project}"
}

# gs://name or name/ -> name
normalize_bucket_name() {
  local bucket="$1"
  bucket="${bucket#gs://}"
  bucket="${bucket%/}"
  if [[ ! "${bucket}" =~ ^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$ ]]; then
    echo "Bucket name must be 3-63 characters and use only lowercase letters, digits, dots, underscores, or hyphens: ${1}" >&2
    exit 1
  fi
  printf '%s\n' "${bucket}"
}
