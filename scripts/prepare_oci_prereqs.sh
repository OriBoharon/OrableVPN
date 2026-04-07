#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYS_DIR="${ROOT_DIR}/keys"
STATE_DIR="${ROOT_DIR}/scripts/.state"
DEFAULT_INPUT_FILE="${ROOT_DIR}/bootstrap.tfvars"
DEFAULT_OUTPUT_FILE="${ROOT_DIR}/terraform.tfvars"
HOST_KEY_PATH="${KEYS_DIR}/host_key"
HOST_KEY_PUBLIC_PATH="${HOST_KEY_PATH}.pub"
MANIFEST_PATH="${STATE_DIR}/oci_prereqs_manifest.env"
PROJECT_PREFIX="orable-vpn"
TAG_MANAGED_BY="${PROJECT_PREFIX}"
TAG_CREATED_BY_SCRIPT="prepare_oci_prereqs.sh"
DRY_RUN=0
INPUT_FILE=""
OUTPUT_FILE=""
POSITIONAL_COUNT=0
OCI_WAIT_SECONDS=1800

SECRET_KEYS=(
  "duckdns-token"
  "wg-admin-password-hash-base64"
  "ssh-host-private-key"
  "ssh-host-public-key"
)

declare -A REPLACE_SECRETS=()
declare -A SECRET_NAME_BY_KEY=()
declare -A SECRET_ID_BY_KEY=()
declare -A SECRET_ACTION_BY_KEY=()

usage() {
  cat <<EOF
Usage:
  ./scripts/prepare_oci_prereqs.sh [options] [bootstrap.tfvars] [terraform.tfvars]

Options:
  --dry-run                      Preview OCI create/reuse/rotate actions without changing OCI.
  --replace-secret NAME          Rotate only the named secret if drift is detected.
                                 Allowed names: duckdns-token, wg-admin-password-hash-base64,
                                 ssh-host-private-key, ssh-host-public-key
  -h, --help                     Show this help text.

Examples:
  ./scripts/prepare_oci_prereqs.sh
  ./scripts/prepare_oci_prereqs.sh ./bootstrap.tfvars ./terraform.tfvars
  ./scripts/prepare_oci_prereqs.sh --dry-run
  ./scripts/prepare_oci_prereqs.sh --replace-secret wg-admin-password-hash-base64
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

is_valid_secret_key() {
  local candidate="$1"
  local key
  for key in "${SECRET_KEYS[@]}"; do
    if [ "$candidate" = "$key" ]; then
      return 0
    fi
  done
  return 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --replace-secret)
      if [ "$#" -lt 2 ]; then
        echo "--replace-secret requires a secret name." >&2
        usage >&2
        exit 1
      fi
      if ! is_valid_secret_key "$2"; then
        echo "Unsupported secret name for --replace-secret: $2" >&2
        usage >&2
        exit 1
      fi
      REPLACE_SECRETS["$2"]=1
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      POSITIONAL_COUNT=$((POSITIONAL_COUNT + 1))
      if [ "$POSITIONAL_COUNT" -eq 1 ]; then
        INPUT_FILE="$1"
      elif [ "$POSITIONAL_COUNT" -eq 2 ]; then
        OUTPUT_FILE="$1"
      else
        echo "Too many positional arguments." >&2
        usage >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [ -z "$INPUT_FILE" ]; then
  INPUT_FILE="$DEFAULT_INPUT_FILE"
fi

if [ -z "$OUTPUT_FILE" ]; then
  OUTPUT_FILE="$DEFAULT_OUTPUT_FILE"
fi

require_cmd awk
require_cmd base64
require_cmd oci
require_cmd sed
require_cmd ssh-keygen

if [ ! -f "$INPUT_FILE" ]; then
  echo "Input file not found: $INPUT_FILE" >&2
  echo "Copy ${ROOT_DIR}/bootstrap.tfvars.example and fill in your values first." >&2
  exit 1
fi

read_tfvar() {
  local key="$1"
  local value

  value="$(awk -F= -v key="$key" '
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      sub(/^[^=]*=[[:space:]]*/, "", $0)
      print $0
      exit
    }
  ' "$INPUT_FILE" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

  value="${value%\"}"
  value="${value#\"}"
  printf '%s' "$value"
}

require_value() {
  local key="$1"
  local value

  value="$(read_tfvar "$key")"
  if [ -z "$value" ]; then
    echo "Missing required value in ${INPUT_FILE}: ${key}" >&2
    exit 1
  fi
  printf '%s' "$value"
}

region="$(require_value region)"
tenancy_ocid="$(require_value tenancy_ocid)"
compartment_id="$(require_value compartment_id)"
user_ocid="$(require_value user_ocid)"
fingerprint="$(require_value fingerprint)"
private_key_path="$(require_value private_key_path)"
duck_domain="$(require_value duck_domain)"
duck_token="$(require_value duck_token)"
wg_admin_password_hash_base64="$(require_value wg_admin_password_hash_base64)"
ssh_authorized_keys_path="$(read_tfvar ssh_authorized_keys_path)"
vault_name="$(read_tfvar vault_display_name)"
key_name="$(read_tfvar vault_key_display_name)"

if ! printf '%s' "$wg_admin_password_hash_base64" | base64 --decode >/dev/null 2>&1; then
  echo "wg_admin_password_hash_base64 in ${INPUT_FILE} is not valid base64." >&2
  exit 1
fi

if [ -z "$ssh_authorized_keys_path" ]; then
  if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
    ssh_authorized_keys_path="~/.ssh/id_ed25519.pub"
  elif [ -f "$HOME/.ssh/id_rsa.pub" ]; then
    ssh_authorized_keys_path="~/.ssh/id_rsa.pub"
  else
    echo "No SSH public key found. Set ssh_authorized_keys_path in ${INPUT_FILE}." >&2
    exit 1
  fi
fi

expanded_ssh_key_path="${ssh_authorized_keys_path/#\~/$HOME}"
if [ ! -f "$expanded_ssh_key_path" ]; then
  echo "SSH authorized key path does not exist: $ssh_authorized_keys_path" >&2
  exit 1
fi

if [ -z "$vault_name" ]; then
  vault_name="${PROJECT_PREFIX}-vault"
fi

if [ -z "$key_name" ]; then
  key_name="${PROJECT_PREFIX}-bootstrap-key"
fi

mkdir -p "$KEYS_DIR" "$STATE_DIR"
if [ ! -f "$HOST_KEY_PATH" ] || [ ! -f "$HOST_KEY_PUBLIC_PATH" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] Would generate ${HOST_KEY_PATH} and ${HOST_KEY_PUBLIC_PATH}"
  else
    ssh-keygen -t ed25519 -f "$HOST_KEY_PATH" -N "" >/dev/null
    chmod 600 "$HOST_KEY_PATH"
    chmod 644 "$HOST_KEY_PUBLIC_PATH"
  fi
fi

if [ ! -f "$HOST_KEY_PATH" ] || [ ! -f "$HOST_KEY_PUBLIC_PATH" ]; then
  echo "Host SSH key material is required before continuing. Run without --dry-run once to generate it." >&2
  exit 1
fi

export OCI_CLI_REGION="$region"
FREEFORM_TAGS="{\"managed-by\":\"${TAG_MANAGED_BY}\",\"project\":\"${PROJECT_PREFIX}\",\"created-by-script\":\"${TAG_CREATED_BY_SCRIPT}\"}"

find_active_vault_id() {
  oci kms management vault list \
    --compartment-id "$compartment_id" \
    --all \
    --query "data[?\"display-name\"=='${vault_name}' && \"lifecycle-state\"=='ACTIVE'].id | [0]" \
    --raw-output
}

find_enabled_key_id() {
  oci kms management key list \
    --endpoint "$management_endpoint" \
    --compartment-id "$compartment_id" \
    --all \
    --query "data[?\"display-name\"=='${key_name}' && \"lifecycle-state\"=='ENABLED'].id | [0]" \
    --raw-output
}

fetch_secret_plaintext() {
  local secret_id="$1"
  oci secrets secret-bundle get \
    --secret-id "$secret_id" \
    --stage CURRENT \
    --query 'data."secret-bundle-content".content' \
    --raw-output | base64 --decode
}

find_secret_id() {
  local secret_name="$1"
  oci vault secret list \
    --compartment-id "$compartment_id" \
    --vault-id "$vault_id" \
    --all \
    --query "data[?\"secret-name\"=='${secret_name}' && \"lifecycle-state\"=='ACTIVE'].id | [0]" \
    --raw-output
}

create_vault() {
  oci kms management vault create \
    --compartment-id "$compartment_id" \
    --display-name "$vault_name" \
    --vault-type DEFAULT \
    --freeform-tags "$FREEFORM_TAGS" \
    --wait-for-state ACTIVE \
    --max-wait-seconds "$OCI_WAIT_SECONDS" \
    --query 'data.id' \
    --raw-output
}

create_key() {
  oci kms management key create \
    --endpoint "$management_endpoint" \
    --compartment-id "$compartment_id" \
    --display-name "$key_name" \
    --key-shape '{"algorithm":"AES","length":32}' \
    --protection-mode SOFTWARE \
    --freeform-tags "$FREEFORM_TAGS" \
    --wait-for-state ENABLED \
    --max-wait-seconds "$OCI_WAIT_SECONDS" \
    --query 'data.id' \
    --raw-output
}

create_secret() {
  local secret_name="$1"
  local secret_b64="$2"
  oci vault secret create-base64 \
    --compartment-id "$compartment_id" \
    --vault-id "$vault_id" \
    --key-id "$key_id" \
    --secret-name "$secret_name" \
    --description "Bootstrap secret for ${PROJECT_PREFIX}" \
    --secret-content-content "$secret_b64" \
    --freeform-tags "$FREEFORM_TAGS" \
    --wait-for-state ACTIVE \
    --max-wait-seconds "$OCI_WAIT_SECONDS" \
    --query 'data.id' \
    --raw-output
}

rotate_secret() {
  local secret_id="$1"
  local secret_b64="$2"
  oci vault secret update-base64 \
    --secret-id "$secret_id" \
    --secret-content-content "$secret_b64" \
    --current-version-number 1 >/dev/null 2>&1
}

ensure_secret_state() {
  local logical_key="$1"
  local secret_name="$2"
  local desired_plaintext="$3"
  local desired_b64="$4"
  local allow_replace="${REPLACE_SECRETS[$logical_key]:-0}"
  local secret_id
  local current_plaintext
  local action

  if [ "${vault_action}" = "created" ] && [ "$DRY_RUN" -eq 1 ]; then
    SECRET_ID_BY_KEY["$logical_key"]="<dry-run:create:${secret_name}>"
    SECRET_ACTION_BY_KEY["$logical_key"]="created"
    return 0
  fi

  secret_id="$(find_secret_id "$secret_name")"
  if [ -z "$secret_id" ] || [ "$secret_id" = "null" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      action="created"
      secret_id="<dry-run:create:${secret_name}>"
    else
      secret_id="$(create_secret "$secret_name" "$desired_b64")"
      action="created"
    fi
    SECRET_ID_BY_KEY["$logical_key"]="$secret_id"
    SECRET_ACTION_BY_KEY["$logical_key"]="$action"
    return 0
  fi

  current_plaintext="$(fetch_secret_plaintext "$secret_id")"
  if [ "$current_plaintext" = "$desired_plaintext" ]; then
    SECRET_ID_BY_KEY["$logical_key"]="$secret_id"
    SECRET_ACTION_BY_KEY["$logical_key"]="reused"
    return 0
  fi

  if [ "$allow_replace" = "1" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      action="rotated"
    else
      oci vault secret update-base64 \
        --secret-id "$secret_id" \
        --secret-content-content "$desired_b64" \
        --force \
        --wait-for-state ACTIVE \
        --max-wait-seconds "$OCI_WAIT_SECONDS" >/dev/null
      action="rotated"
    fi
    SECRET_ID_BY_KEY["$logical_key"]="$secret_id"
    SECRET_ACTION_BY_KEY["$logical_key"]="$action"
    return 0
  fi

  SECRET_ID_BY_KEY["$logical_key"]="$secret_id"
  SECRET_ACTION_BY_KEY["$logical_key"]="drift-blocked"
  echo "Secret drift detected for ${secret_name}. Re-run with --replace-secret ${logical_key} to rotate only that secret." >&2
  exit 1
}

vault_id="$(find_active_vault_id || true)"
if [ -z "$vault_id" ] || [ "$vault_id" = "null" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    vault_id="<dry-run:create:${vault_name}>"
    vault_action="created"
    management_endpoint="<dry-run:management-endpoint>"
  else
    vault_id="$(create_vault)"
    vault_action="created"
    management_endpoint="$(
      oci kms management vault get \
        --vault-id "$vault_id" \
        --query 'data."management-endpoint"' \
        --raw-output
    )"
  fi
else
  vault_action="reused"
  management_endpoint="$(
    oci kms management vault get \
      --vault-id "$vault_id" \
      --query 'data."management-endpoint"' \
      --raw-output
  )"
fi

if [ "${vault_action}" = "created" ] && [ "$DRY_RUN" -eq 1 ]; then
  key_id="<dry-run:create:${key_name}>"
  key_action="created"
else
  key_id="$(find_enabled_key_id || true)"
  if [ -z "$key_id" ] || [ "$key_id" = "null" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      key_id="<dry-run:create:${key_name}>"
      key_action="created"
    else
      key_id="$(create_key)"
      key_action="created"
    fi
  else
    key_action="reused"
  fi
fi

SECRET_NAME_BY_KEY["duckdns-token"]="${PROJECT_PREFIX}-duckdns-token"
SECRET_NAME_BY_KEY["wg-admin-password-hash-base64"]="${PROJECT_PREFIX}-wg-admin-password-hash-base64"
SECRET_NAME_BY_KEY["ssh-host-private-key"]="${PROJECT_PREFIX}-ssh-host-private-key"
SECRET_NAME_BY_KEY["ssh-host-public-key"]="${PROJECT_PREFIX}-ssh-host-public-key"

ensure_secret_state \
  "duckdns-token" \
  "${SECRET_NAME_BY_KEY["duckdns-token"]}" \
  "$duck_token" \
  "$(printf '%s' "$duck_token" | base64 -w0)"
ensure_secret_state \
  "wg-admin-password-hash-base64" \
  "${SECRET_NAME_BY_KEY["wg-admin-password-hash-base64"]}" \
  "$wg_admin_password_hash_base64" \
  "$(printf '%s' "$wg_admin_password_hash_base64" | base64 -w0)"
ensure_secret_state \
  "ssh-host-private-key" \
  "${SECRET_NAME_BY_KEY["ssh-host-private-key"]}" \
  "$(cat "$HOST_KEY_PATH")" \
  "$(base64 -w0 < "$HOST_KEY_PATH")"
ensure_secret_state \
  "ssh-host-public-key" \
  "${SECRET_NAME_BY_KEY["ssh-host-public-key"]}" \
  "$(cat "$HOST_KEY_PUBLIC_PATH")" \
  "$(base64 -w0 < "$HOST_KEY_PUBLIC_PATH")"

duckdns_token_secret_ocid="${SECRET_ID_BY_KEY["duckdns-token"]}"
wg_admin_password_hash_base64_secret_ocid="${SECRET_ID_BY_KEY["wg-admin-password-hash-base64"]}"
ssh_host_private_key_secret_ocid="${SECRET_ID_BY_KEY["ssh-host-private-key"]}"
ssh_host_public_key_secret_ocid="${SECRET_ID_BY_KEY["ssh-host-public-key"]}"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[dry-run] Would write ${OUTPUT_FILE}"
else
  cat > "$OUTPUT_FILE" <<EOF
region                    = "${region}"
tenancy_ocid              = "${tenancy_ocid}"
compartment_id            = "${compartment_id}"
user_ocid                 = "${user_ocid}"
fingerprint               = "${fingerprint}"
private_key_path          = "${private_key_path}"
ssh_authorized_keys_path  = "${ssh_authorized_keys_path}"
duck_domain               = "${duck_domain}"
duckdns_token_secret_ocid = "${duckdns_token_secret_ocid}"
wg_admin_password_hash_base64_secret_ocid = "${wg_admin_password_hash_base64_secret_ocid}"
ssh_host_private_key_secret_ocid   = "${ssh_host_private_key_secret_ocid}"
ssh_host_public_key_secret_ocid    = "${ssh_host_public_key_secret_ocid}"
EOF
  chmod 600 "$OUTPUT_FILE"
fi

write_manifest() {
  cat > "$MANIFEST_PATH" <<EOF
PROJECT_PREFIX=$(printf '%q' "$PROJECT_PREFIX")
OCI_REGION=$(printf '%q' "$region")
COMPARTMENT_ID=$(printf '%q' "$compartment_id")
INPUT_FILE=$(printf '%q' "$INPUT_FILE")
OUTPUT_FILE=$(printf '%q' "$OUTPUT_FILE")
VAULT_NAME=$(printf '%q' "$vault_name")
VAULT_ID=$(printf '%q' "$vault_id")
VAULT_ACTION=$(printf '%q' "$vault_action")
KEY_NAME=$(printf '%q' "$key_name")
KEY_ID=$(printf '%q' "$key_id")
KEY_ACTION=$(printf '%q' "$key_action")
SECRET_DUCKDNS_TOKEN_NAME=$(printf '%q' "${SECRET_NAME_BY_KEY["duckdns-token"]}")
SECRET_DUCKDNS_TOKEN_ID=$(printf '%q' "${SECRET_ID_BY_KEY["duckdns-token"]}")
SECRET_DUCKDNS_TOKEN_ACTION=$(printf '%q' "${SECRET_ACTION_BY_KEY["duckdns-token"]}")
SECRET_WG_ADMIN_PASSWORD_HASH_BASE64_NAME=$(printf '%q' "${SECRET_NAME_BY_KEY["wg-admin-password-hash-base64"]}")
SECRET_WG_ADMIN_PASSWORD_HASH_BASE64_ID=$(printf '%q' "${SECRET_ID_BY_KEY["wg-admin-password-hash-base64"]}")
SECRET_WG_ADMIN_PASSWORD_HASH_BASE64_ACTION=$(printf '%q' "${SECRET_ACTION_BY_KEY["wg-admin-password-hash-base64"]}")
SECRET_SSH_HOST_PRIVATE_KEY_NAME=$(printf '%q' "${SECRET_NAME_BY_KEY["ssh-host-private-key"]}")
SECRET_SSH_HOST_PRIVATE_KEY_ID=$(printf '%q' "${SECRET_ID_BY_KEY["ssh-host-private-key"]}")
SECRET_SSH_HOST_PRIVATE_KEY_ACTION=$(printf '%q' "${SECRET_ACTION_BY_KEY["ssh-host-private-key"]}")
SECRET_SSH_HOST_PUBLIC_KEY_NAME=$(printf '%q' "${SECRET_NAME_BY_KEY["ssh-host-public-key"]}")
SECRET_SSH_HOST_PUBLIC_KEY_ID=$(printf '%q' "${SECRET_ID_BY_KEY["ssh-host-public-key"]}")
SECRET_SSH_HOST_PUBLIC_KEY_ACTION=$(printf '%q' "${SECRET_ACTION_BY_KEY["ssh-host-public-key"]}")
EOF
  chmod 600 "$MANIFEST_PATH"
}

write_manifest

echo "Prerequisite summary:"
echo "  Vault ${vault_name}: ${vault_action}"
echo "  Key ${key_name}: ${key_action}"
echo "  Secret ${SECRET_NAME_BY_KEY["duckdns-token"]}: ${SECRET_ACTION_BY_KEY["duckdns-token"]}"
echo "  Secret ${SECRET_NAME_BY_KEY["wg-admin-password-hash-base64"]}: ${SECRET_ACTION_BY_KEY["wg-admin-password-hash-base64"]}"
echo "  Secret ${SECRET_NAME_BY_KEY["ssh-host-private-key"]}: ${SECRET_ACTION_BY_KEY["ssh-host-private-key"]}"
echo "  Secret ${SECRET_NAME_BY_KEY["ssh-host-public-key"]}: ${SECRET_ACTION_BY_KEY["ssh-host-public-key"]}"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry run complete. No OCI resources or local tfvars were changed."
else
  echo "Generated ${OUTPUT_FILE} with OCI Secret OCIDs."
fi
echo "Manifest: ${MANIFEST_PATH}"
