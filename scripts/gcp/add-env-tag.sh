#!/usr/bin/env bash
# Bind the org-level "environment" tag to a GCP project.
# Usage: add-env-tag.sh [ENV_VALUE] [PROJECT_ID]
#   ENV_VALUE   Production, Development, Test, or Staging. Default: Development.
#   PROJECT_ID  Default: gcloud config get-value project.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage: add-env-tag.sh [ENV_VALUE] [PROJECT_ID]

  ENV_VALUE   Production, Development, Test, or Staging (default: Development)
  PROJECT_ID  GCP project id (default: gcloud config get-value project)

Creates the organization tag key "environment" and the requested value when
they are missing, then binds that value to the project. A project with no
organization ancestor cannot use org tags; the script says so and exits 0.
EOF
}

ENV_VALUE="${1:-Development}"
PROJECT_ARG="${2:-}"

case "${ENV_VALUE}" in
  -h|--help)
    usage
    exit 0
    ;;
  Production|Development|Test|Staging)
    ;;
  *)
    echo "ENV_VALUE must be one of: Production, Development, Test, Staging." >&2
    usage >&2
    exit 1
    ;;
esac

if [[ $# -gt 2 ]]; then
  echo "Too many arguments." >&2
  usage >&2
  exit 1
fi

require_gcloud

if [[ -n "${PROJECT_ARG}" ]]; then
  PROJECT_ID="${PROJECT_ARG}"
else
  PROJECT_ID="$(project_from_config)"
fi

PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
if [[ -z "${PROJECT_NUMBER}" ]]; then
  echo "Could not read the project number for ${PROJECT_ID}." >&2
  exit 1
fi

ancestors="$(gcloud projects get-ancestors "${PROJECT_ID}" --format='csv[no-heading](id,type)')"
ORG_ID=""
while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  ancestor_id="${line%%,*}"
  ancestor_type="${line#*,}"
  if [[ "${ancestor_type}" == "organization" ]]; then
    ORG_ID="${ancestor_id}"
    break
  fi
done <<< "${ancestors}"

if [[ -z "${ORG_ID}" ]]; then
  echo "Project ${PROJECT_ID} has no organization ancestor. Environment tags need an organization; this warning can be ignored."
  exit 0
fi

KEY_NS="${ORG_ID}/environment"
if ! gcloud resource-manager tags keys describe "${KEY_NS}" >/dev/null 2>&1; then
  echo "Creating tag key ${KEY_NS}"
  gcloud resource-manager tags keys create environment \
    --parent="organizations/${ORG_ID}" \
    --description="Deployment environment for this project" \
    || gcloud resource-manager tags keys describe "${KEY_NS}" >/dev/null
fi

VALUE_NS="${ORG_ID}/environment/${ENV_VALUE}"
if ! gcloud resource-manager tags values describe "${VALUE_NS}" >/dev/null 2>&1; then
  echo "Creating tag value ${VALUE_NS}"
  gcloud resource-manager tags values create "${ENV_VALUE}" \
    --parent="${KEY_NS}" \
    --description="${ENV_VALUE} environment" \
    || gcloud resource-manager tags values describe "${VALUE_NS}" >/dev/null
fi

PARENT="//cloudresourcemanager.googleapis.com/projects/${PROJECT_NUMBER}"
existing="$(gcloud resource-manager tags bindings list \
  --parent="${PARENT}" \
  --format='value(tagValueNamespacedName)')"

if printf '%s\n' "${existing}" | grep -F -x -q "${VALUE_NS}"; then
  echo "Tag ${VALUE_NS} is already bound to project ${PROJECT_ID} (${PROJECT_NUMBER})."
  exit 0
fi

other="$(printf '%s\n' "${existing}" | grep -F "${ORG_ID}/environment/" || true)"
if [[ -n "${other}" ]]; then
  echo "Project ${PROJECT_ID} already has a different environment tag. Remove that binding before attaching ${VALUE_NS}:" >&2
  printf '%s\n' "${other}" >&2
  exit 1
fi

echo "Binding ${VALUE_NS} to ${PARENT}"
gcloud resource-manager tags bindings create \
  --tag-value="${VALUE_NS}" \
  --parent="${PARENT}"

echo "Bound ${VALUE_NS} to project ${PROJECT_ID} (${PROJECT_NUMBER})."
