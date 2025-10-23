#!/usr/bin/env bash
# az_kv_sp_explorer.sh
# Interactive tool to:
#  - login as a Service Principal
#  - list key vaults
#  - list secrets (names)
#  - optionally fetch secret value (explicit confirmation)
#  - optionally attempt az login as another principal/user using that value as password
#  - write operational logs to script.log (no secret values by default)
#  - write username metadata to readPass.log when a password is extracted/used
#
# Requirements: Azure CLI (az). jq recommended but optional.
# Usage: ./az_kv_sp_explorer.sh

set -o errexit
set -o nounset
set -o pipefail

LOG_FILE="./script.log"
READPASS_LOG="./readPass.log"
TMP_JSON="/tmp/az_kv_sp_explorer.tmp.json"
JQ="$(command -v jq || true)"

timestamp(){ date +"%Y-%m-%d %H:%M:%S"; }
log(){ echo "$(timestamp) - $*" | tee -a "$LOG_FILE"; }
err(){ echo "$(timestamp) - ERROR - $*" | tee -a "$LOG_FILE" >&2; }

cleanup(){ rm -f "$TMP_JSON" "$TMP_JSON.value" || true; }
trap cleanup EXIT

# default: do not log secret VALUES to script.log. Set to "true" if you explicitly want it.
LOG_SECRET_VALUES="${LOG_SECRET_VALUES:-false}"

# ----- SP login function (explicit per your flow) -----
sp_login_interactive() {
  echo
  echo "Service Principal login (interactive). Enter values below."
  read -r -p "Service Principal AppID (username): " SP_APPID
  read -r -s -p "Service Principal Password (password): " SP_PASS
  echo
  read -r -p "Tenant ID (or domain): " SP_TENANT

  log "Attempting SP login for appId $SP_APPID (tenant $SP_TENANT)"
  if az login --service-principal --username "$SP_APPID" --password "$SP_PASS" --tenant "$SP_TENANT" &>>"$LOG_FILE"; then
    log "SP login succeeded for $SP_APPID"
    return 0
  else
    err "SP login failed for $SP_APPID (see $LOG_FILE for az output)"
    return 1
  fi
}

# ----- choose subscription (optional) -----
choose_subscription() {
  if az account show &>/dev/null; then
    az account list --output json > "$TMP_JSON"
    if [[ -n "$JQ" ]]; then
      local count; count=$(jq 'length' "$TMP_JSON")
      if [[ "$count" -gt 1 ]]; then
        echo "Available subscriptions:"
        jq -r '.[] | "\(.name) | \(.id)"' "$TMP_JSON" | nl -w2 -s'. ' -v1
        read -r -p "Enter subscription number to set (or press Enter to keep current): " sub_choice
        if [[ -n "$sub_choice" ]]; then
          sub_id=$(jq -r ".[$((sub_choice-1))].id" "$TMP_JSON")
          az account set --subscription "$sub_id" &>>"$LOG_FILE" && log "Set subscription to $sub_id"
        fi
      fi
    else
      az account list --output table | tee -a "$LOG_FILE"
      read -r -p "If you want to set a subscription now, paste its ID (or press Enter to skip): " sub_id
      if [[ -n "$sub_id" ]]; then
        az account set --subscription "$sub_id" &>>"$LOG_FILE" && log "Set subscription to $sub_id"
      fi
    fi
  else
    err "No active account info available. Are you logged in?"
  fi
}

# ----- List vaults and let user pick one -----
select_vault() {
  az keyvault list --output json > "$TMP_JSON" 2>>"$LOG_FILE" || { err "Failed to list vaults"; return 1; }
  if [[ -n "$JQ" ]]; then
    local n; n=$(jq 'length' "$TMP_JSON")
    if [[ "$n" -eq 0 ]]; then
      echo "No Key Vaults found or insufficient permissions."
      return 1
    fi
    echo "Key Vaults:"
    jq -r '.[] | .name + " (" + (.properties.vaultUri // "") + ")"' "$TMP_JSON" | nl -w2 -s'. ' -v1
    read -r -p "Choose vault number (or q to cancel): " vchoice
    [[ "$vchoice" == "q" ]] && return 2
    VAULT_NAME="$(jq -r ".[$((vchoice-1))].name" "$TMP_JSON")"
  else
    az keyvault list --output table | tee -a "$LOG_FILE"
    read -r -p "Enter vault name to inspect (or q to cancel): " VAULT_NAME
    [[ "$VAULT_NAME" == "q" ]] && return 2
  fi

  if [[ -z "${VAULT_NAME:-}" || "$VAULT_NAME" == "null" ]]; then
    err "Invalid vault selection"
    return 1
  fi
  log "Selected vault: $VAULT_NAME"
  return 0
}

# ----- List secrets in vault and let user pick -----
select_secret_in_vault() {
  local vault="$1"
  az keyvault secret list --vault-name "$vault" --query "[].name" -o tsv > "$TMP_JSON" 2>>"$LOG_FILE" || { err "Failed to list secrets for $vault"; return 1; }
  mapfile -t secret_names < "$TMP_JSON"
  if [[ ${#secret_names[@]} -eq 0 ]]; then
    echo "No secrets found or insufficient permissions."
    return 1
  fi
  echo "Secrets in $vault:"
  for i in "${!secret_names[@]}"; do
    printf "%2d) %s\n" $((i+1)) "${secret_names[$i]}"
  done
  read -r -p "Choose a secret number (or 'a' to fetch all values, q to cancel): " scol
  [[ "$scol" == "q" ]] && return 2
  if [[ "$scol" == "a" ]]; then
    read -r -p "Fetch ALL values? This will display values in terminal. Proceed? [y/N]: " confirm_all
    if [[ "$confirm_all" =~ ^[Yy]$ ]]; then
      for s in "${secret_names[@]}"; do
        val="$(az keyvault secret show --vault-name "$vault" --name "$s" --query 'value' -o tsv 2>>"$LOG_FILE" || echo "__ERR__")"
        if [[ "$val" == "__ERR__" ]]; then
          echo "Failed: $s"
          log "Failed reading secret $s from $vault"
        else
          echo "SECRET: $s = $val"
          log "Fetched secret $s from $vault (value displayed in terminal by user request)"
          [[ "$LOG_SECRET_VALUES" == "true" ]] && log "SECRET_VALUE: $s = $val"
        fi
      done
    else
      echo "Aborted fetch all."
    fi
    return 0
  fi

  # single selection
  idx=$((scol-1))
  if (( idx < 0 || idx >= ${#secret_names[@]} )); then
    err "Invalid selection"
    return 1
  fi
  SECRET_NAME="${secret_names[$idx]}"
  log "Selected secret: $SECRET_NAME"
  return 0
}

# ----- Inspect a single secret and optionally attempt login -----
inspect_secret_and_maybe_login() {
  local vault="$1"
  local secret="$2"
  echo
  echo "Secret: $secret in vault: $vault"
  echo "Options:"
  echo "  1) Show metadata only"
  echo "  2) Fetch secret VALUE (requires explicit confirm)"
  echo "  3) Fetch value and attempt az login as another user (interactive)"
  echo "  4) Go back"
  read -r -p "Choose 1-4: " opt
  case "$opt" in
    1)
      az keyvault secret show --vault-name "$vault" --name "$secret" --output json | sed -n '1,200p'
      log "Displayed metadata for $secret in $vault"
      ;;
    2)
      read -r -p "Fetch secret value? This will print the value to your terminal. Proceed [y/N]: " c2
      if [[ "$c2" =~ ^[Yy]$ ]]; then
        secret_value="$(az keyvault secret show --vault-name "$vault" --name "$secret" --query 'value' -o tsv 2>>"$LOG_FILE" || echo "__ERR__")"
        if [[ "$secret_value" == "__ERR__" ]]; then
          err "Failed to fetch secret value for $secret"
        else
          echo "VALUE: $secret_value"
          log "Fetched secret $secret (value displayed in terminal on user confirmation)"
          [[ "$LOG_SECRET_VALUES" == "true" ]] && log "SECRET_VALUE: $secret = $secret_value"
          read -r -p "Do you want to mark an account username to $READPASS_LOG for follow-up? (enter username or leave blank): " assoc_user
          if [[ -n "$assoc_user" ]]; then
            echo "$(timestamp) - $assoc_user - secret:$secret - vault:$vault" >> "$READPASS_LOG"
            log "Marked $assoc_user in $READPASS_LOG"
          fi
          unset secret_value
        fi
      else
        echo "Cancelled."
      fi
      ;;
    3)
      read -r -p "Fetch secret value and attempt login? Proceed [y/N]: " c3
      if [[ "$c3" =~ ^[Yy]$ ]]; then
        secret_value="$(az keyvault secret show --vault-name "$vault" --name "$secret" --query 'value' -o tsv 2>>"$LOG_FILE" || echo "__ERR__")"
        if [[ "$secret_value" == "__ERR__" ]]; then
          err "Failed to fetch secret value for $secret"
          return 1
        fi
        echo "Fetched secret value (not logged)."
        # ask for username to try
        read -r -p "Enter username (UPN) to attempt az login as (e.g. user@domain.tld or appId for SP): " try_user
        if [[ -z "$try_user" ]]; then
          err "No username provided. Aborting attempt."
        else
          log "Attempting az login as $try_user using value from secret $secret (vault: $vault)"
          if az login -u "$try_user" -p "$secret_value" &>>"$LOG_FILE"; then
            log "Login succeeded for $try_user"
            echo "Login succeeded for $try_user"
            # write to readPass.log (username context only)
            echo "$(timestamp) - $try_user - password_extracted_from:$secret - vault:$vault" >> "$READPASS_LOG"
            log "Wrote $try_user record to $READPASS_LOG"
          else
            err "Login failed for $try_user (see $LOG_FILE)"
          fi
        fi
        unset secret_value
      else
        echo "Cancelled."
      fi
      ;;
    *)
      echo "Going back."
      ;;
  esac
}

# ----- Main interactive flow -----
main_menu() {
  while true; do
    echo
    echo "Main Menu:"
    echo "  1) SP Login (service-principal)"
    echo "  2) Choose subscription"
    echo "  3) List vaults and inspect secrets"
    echo "  4) Show logs (last 200 lines)"
    echo "  5) Exit"
    read -r -p "Choose 1-5: " m
    case "$m" in
      1)
        sp_login_interactive || echo "SP login failed; check $LOG_FILE"
        ;;
      2)
        choose_subscription
        ;;
      3)
        select_vault || { echo "No vault selected or error."; continue; }
        select_secret_in_vault "$VAULT_NAME" || continue
        inspect_secret_and_maybe_login "$VAULT_NAME" "$SECRET_NAME"
        ;;
      4)
        echo "----- $LOG_FILE -----"
        tail -n 200 "$LOG_FILE" || true
        echo
        echo "----- $READPASS_LOG -----"
        tail -n 200 "$READPASS_LOG" || true
        ;;
      5)
        log "Exiting."
        break
        ;;
      *)
        echo "Invalid option"
        ;;
    esac
  done
}

# --------- start ----------
log "Script started by $(whoami)"
if ! command -v az &>/dev/null; then
  err "az CLI not found. Install azure-cli and retry."
  exit 1
fi

main_menu
log "Script finished"
