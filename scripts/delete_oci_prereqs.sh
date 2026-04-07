#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${ROOT_DIR}/scripts/.state"
MANIFEST_PATH="${STATE_DIR}/oci_prereqs_manifest.env"
DEFAULT_BOOTSTRAP_FILE="${ROOT_DIR}/bootstrap.tfvars"
DEFAULT_TERRAFORM_FILE="${ROOT_DIR}/terraform.tfvars"
PROJECT_PREFIX="orable-vps"
DEFAULT_VAULT_NAME="${PROJECT_PREFIX}-vault"
DEFAULT_KEY_NAME="${PROJECT_PREFIX}-bootstrap-key"
TAG_MANAGED_BY="${PROJECT_PREFIX}"
EXECUTE=0
CUSTOM_MANIFEST=""

declare -A SECRET_NAME_BY_KEY=(
  ["duckdns-token"]="${PROJECT_PREFIX}-duckdns-token"
  ["wg-admin-password-hash-base64"]="${PROJECT_PREFIX}-wg-admin-password-hash-base64"
  ["ssh-host-private-key"]="${PROJECT_PREFIX}-ssh-host-private-key"
  ["ssh-host-public-key"]="${PROJECT_PREFIX}-ssh-host-public-key"
)

declare -A SECRET_ID_BY_KEY=()

usage() {
  cat <<EOF
Usage:
  ./scripts/delete_oci_prereqs.sh [options]

Options:
  --dry-run           Preview OCI deletions and safety checks. This is the default.
  --execute           Schedule OCI deletions.
  --manifest PATH     Read the prereq manifest from a custom path.
  -h, --help          Show this help text.

Examples:
  ./scripts/delete_oci_prereqs.sh
  ./scripts/delete_oci_prereqs.sh --dry-run
  ./scripts/delete_oci_prereqs.sh --execute
  ./scripts/delete_oci_prereqs.sh --manifest ./scripts/.state/oci_prereqs_manifest.env --execute
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

read_tfvar_from_file() {
  local file_path="$1"
  local key="$2"
  local value

  if [ ! -f "$file_path" ]; then
    return 0
  fi

  value="$(awk -F= -v key="$key" '
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      sub(/^[^=]*=[[:space:]]*/, "", $0)
      print $0
      exit
    }
  ' "$file_path" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

  value="${value%\"}"
  value="${value#\"}"
  printf '%s' "$value"
}

is_real_ocid() {
  case "$1" in
    ocid1.*) return 0 ;;
    *) return 1 ;;
  esac
}

schedule_deletion_time() {
  date -u -d '+7 days' '+%Y-%m-%dT%H:%M:%SZ'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      EXECUTE=0
      shift
      ;;
    --execute)
      EXECUTE=1
      shift
      ;;
    --manifest)
      if [ "$#" -lt 2 ]; then
        echo "--manifest requires a path." >&2
        usage >&2
        exit 1
      fi
      CUSTOM_MANIFEST="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd date
require_cmd awk
require_cmd oci
require_cmd sed

if [ -n "$CUSTOM_MANIFEST" ]; then
  MANIFEST_PATH="$CUSTOM_MANIFEST"
fi

if [ -f "$MANIFEST_PATH" ]; then
  # shellcheck disable=SC1090
  source "$MANIFEST_PATH"
fi

if [ -z "${COMPARTMENT_ID:-}" ]; then
  COMPARTMENT_ID="$(read_tfvar_from_file "$DEFAULT_TERRAFORM_FILE" compartment_id)"
fi

if [ -z "${COMPARTMENT_ID:-}" ]; then
  COMPARTMENT_ID="$(read_tfvar_from_file "$DEFAULT_BOOTSTRAP_FILE" compartment_id)"
fi

if [ -z "${OCI_REGION:-}" ]; then
  OCI_REGION="$(read_tfvar_from_file "$DEFAULT_TERRAFORM_FILE" region)"
fi

if [ -z "${OCI_REGION:-}" ]; then
  OCI_REGION="$(read_tfvar_from_file "$DEFAULT_BOOTSTRAP_FILE" region)"
fi

if [ -n "${OCI_REGION:-}" ]; then
  export OCI_CLI_REGION="$OCI_REGION"
fi

vault_name="${VAULT_NAME:-$DEFAULT_VAULT_NAME}"
key_name="${KEY_NAME:-$DEFAULT_KEY_NAME}"
vault_id="${VAULT_ID:-}"
key_id="${KEY_ID:-}"

if is_real_ocid "${SECRET_DUCKDNS_TOKEN_ID:-}"; then
  SECRET_ID_BY_KEY["duckdns-token"]="$SECRET_DUCKDNS_TOKEN_ID"
fi
if is_real_ocid "${SECRET_WG_ADMIN_PASSWORD_HASH_BASE64_ID:-}"; then
  SECRET_ID_BY_KEY["wg-admin-password-hash-base64"]="$SECRET_WG_ADMIN_PASSWORD_HASH_BASE64_ID"
fi
if is_real_ocid "${SECRET_SSH_HOST_PRIVATE_KEY_ID:-}"; then
  SECRET_ID_BY_KEY["ssh-host-private-key"]="$SECRET_SSH_HOST_PRIVATE_KEY_ID"
fi
if is_real_ocid "${SECRET_SSH_HOST_PUBLIC_KEY_ID:-}"; then
  SECRET_ID_BY_KEY["ssh-host-public-key"]="$SECRET_SSH_HOST_PUBLIC_KEY_ID"
fi

find_active_vault_id() {
  oci kms management vault list \
    --compartment-id "${COMPARTMENT_ID:?Manifest or environment must provide COMPARTMENT_ID/compartment context for fallback discovery.}" \
    --all \
    --query "data[?\"display-name\"=='${vault_name}' && \"lifecycle-state\"=='ACTIVE'].id | [0]" \
    --raw-output
}

get_vault_management_endpoint() {
  oci kms management vault get \
    --vault-id "$1" \
    --query 'data."management-endpoint"' \
    --raw-output
}

find_enabled_key_id() {
  local endpoint="$1"
  oci kms management key list \
    --endpoint "$endpoint" \
    --compartment-id "${COMPARTMENT_ID:?Manifest or environment must provide COMPARTMENT_ID/compartment context for fallback discovery.}" \
    --all \
    --query "data[?\"display-name\"=='${key_name}' && \"lifecycle-state\"=='ENABLED'].id | [0]" \
    --raw-output
}

find_secret_id() {
  local secret_name="$1"
  oci vault secret list \
    --compartment-id "${COMPARTMENT_ID:?Manifest or environment must provide COMPARTMENT_ID/compartment context for fallback discovery.}" \
    --vault-id "$vault_id" \
    --all \
    --query "data[?\"secret-name\"=='${secret_name}' && \"lifecycle-state\"=='ACTIVE'].id | [0]" \
    --raw-output
}

get_resource_tag() {
  local resource_type="$1"
  local resource_id="$2"
  local query

  case "$resource_type" in
    vault)
      query='data."freeform-tags"."managed-by"'
      oci kms management vault get --vault-id "$resource_id" --query "$query" --raw-output
      ;;
    secret)
      query='data."freeform-tags"."managed-by"'
      oci vault secret get --secret-id "$resource_id" --query "$query" --raw-output
      ;;
    *)
      echo "Unsupported resource type: $resource_type" >&2
      exit 1
      ;;
  esac
}

get_secret_name() {
  oci vault secret get \
    --secret-id "$1" \
    --query 'data."secret-name"' \
    --raw-output
}

get_secret_state() {
  oci vault secret get \
    --secret-id "$1" \
    --query 'data."lifecycle-state"' \
    --raw-output
}

list_active_secret_ids() {
  oci vault secret list \
    --compartment-id "${COMPARTMENT_ID:?Manifest or environment must provide COMPARTMENT_ID/compartment context for fallback discovery.}" \
    --vault-id "$vault_id" \
    --all \
    --query "data[?\"lifecycle-state\"=='ACTIVE'].id | join(' ', @)" \
    --raw-output
}

schedule_secret_deletion() {
  local secret_id="$1"
  local deletion_time="$2"
  oci vault secret schedule-secret-deletion \
    --secret-id "$secret_id" \
    --time-of-deletion "$deletion_time" >/dev/null
}

schedule_vault_deletion() {
  local deletion_time="$1"
  oci kms management vault schedule-deletion \
    --vault-id "$vault_id" \
    --time-of-deletion "$deletion_time" >/dev/null
}

if ! is_real_ocid "$vault_id"; then
  vault_id="$(find_active_vault_id || true)"
fi

if [ -n "$vault_id" ] && [ "$vault_id" != "null" ] && is_real_ocid "$vault_id"; then
  management_endpoint="$(get_vault_management_endpoint "$vault_id")"
else
  management_endpoint=""
  vault_id=""
fi

if [ -z "$key_id" ] || ! is_real_ocid "$key_id"; then
  if [ -n "$management_endpoint" ]; then
    key_id="$(find_enabled_key_id "$management_endpoint" || true)"
    if [ "$key_id" = "null" ]; then
      key_id=""
    fi
  else
    key_id=""
  fi
fi

for secret_key in "${!SECRET_NAME_BY_KEY[@]}"; do
  if [ -z "${SECRET_ID_BY_KEY[$secret_key]:-}" ] && [ -n "$vault_id" ]; then
    secret_id="$(find_secret_id "${SECRET_NAME_BY_KEY[$secret_key]}" || true)"
    if [ -n "$secret_id" ] && [ "$secret_id" != "null" ]; then
      SECRET_ID_BY_KEY["$secret_key"]="$secret_id"
    fi
  fi
done

deletion_time="$(schedule_deletion_time)"
echo "Cleanup mode: $( [ "$EXECUTE" -eq 1 ] && printf 'execute' || printf 'dry-run' )"
echo "Deletion time: ${deletion_time}"

for secret_key in "duckdns-token" "wg-admin-password-hash-base64" "ssh-host-private-key" "ssh-host-public-key"; do
  secret_name="${SECRET_NAME_BY_KEY[$secret_key]}"
  secret_id="${SECRET_ID_BY_KEY[$secret_key]:-}"

  if ! is_real_ocid "$secret_id"; then
    echo "  Secret ${secret_name}: not found"
    continue
  fi

  secret_state="$(get_secret_state "$secret_id")"
  if [ "$secret_state" != "ACTIVE" ]; then
    echo "  Secret ${secret_name}: skipped (${secret_state})"
    continue
  fi

  if [ "$EXECUTE" -eq 1 ]; then
    schedule_secret_deletion "$secret_id" "$deletion_time"
    echo "  Secret ${secret_name}: scheduled for deletion"
  else
    echo "  Secret ${secret_name}: would schedule deletion"
  fi
done

vault_cleanup_allowed=0
vault_cleanup_reason=""

if [ -z "$vault_id" ]; then
  vault_cleanup_reason="vault not found"
else
  vault_tag="$(get_resource_tag vault "$vault_id" || true)"
  if [ "$vault_tag" != "$TAG_MANAGED_BY" ]; then
    vault_cleanup_reason="vault is not tagged as project-managed"
  else
    vault_cleanup_allowed=1
  fi
fi

if [ "$vault_cleanup_allowed" -eq 1 ]; then
  active_secret_ids="$(list_active_secret_ids || true)"
  for active_secret_id in $active_secret_ids; do
    active_secret_name="$(get_secret_name "$active_secret_id")"
    active_secret_tag="$(get_resource_tag secret "$active_secret_id" || true)"
    is_known_secret=0

    for secret_key in "duckdns-token" "wg-admin-password-hash-base64" "ssh-host-private-key" "ssh-host-public-key"; do
      if [ "$active_secret_name" = "${SECRET_NAME_BY_KEY[$secret_key]}" ]; then
        is_known_secret=1
        break
      fi
    done

    if [ "$is_known_secret" -ne 1 ]; then
      vault_cleanup_allowed=0
      vault_cleanup_reason="unexpected active secret remains in vault: ${active_secret_name}"
      break
    fi

    if [ "$active_secret_tag" != "$TAG_MANAGED_BY" ]; then
      vault_cleanup_allowed=0
      vault_cleanup_reason="known secret is untagged or not project-managed: ${active_secret_name}"
      break
    fi
  done
fi

if [ "$vault_cleanup_allowed" -eq 1 ]; then
  if [ "$EXECUTE" -eq 1 ]; then
    schedule_vault_deletion "$deletion_time"
    echo "  Vault ${vault_name}: scheduled for deletion"
  else
    echo "  Vault ${vault_name}: would schedule deletion"
  fi
else
  echo "  Vault ${vault_name}: not scheduling deletion (${vault_cleanup_reason})"
fi

if [ -n "$key_id" ] && is_real_ocid "$key_id"; then
  if [ "$vault_cleanup_allowed" -eq 1 ]; then
    echo "  Key ${key_name}: vault deletion will cover the key"
  else
    echo "  Key ${key_name}: left in place because vault deletion was not approved by safety checks"
  fi
else
  echo "  Key ${key_name}: not found"
fi
