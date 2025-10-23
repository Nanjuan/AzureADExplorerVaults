#!/usr/bin/env bash
# az_kv_sp_explorer.sh
# Interactive tool to:
#  - login as a Service Principal (SP) with progress messages
#  - detect existing az session and log out before a new login
#  - list key vaults
#  - list secrets (names)
#  - optionally fetch a secret value (explicit confirmation)
#  - optionally attempt az login as another principal/user using that value as password
#  - write operational logs to script.log (no secret values by default)
#  - write username metadata to readPass.log when a password is extracted/used
#
# Usage: ./az_kv_sp_explorer.sh
# Requirements: Azure CLI (az). jq recommended (optional).

set -o errexit
set -o nounset
set -o pipefail

LOG_FILE="./script.log"
READPASS_LOG="./readPass.log"
TMP_JSON="/tmp/az_kv_sp_explorer.tmp.json"
JQ="$(command -v jq || true)"

# Do NOT log secret values by default (override with: export LOG_SECRET_VALUES=true)
LOG_SECRET_VALUES="${LOG_SECRET_VALUES:-false}"

# Timeout (seconds) for az commands (override: export AZ_CMD_TIMEOUT_SECONDS=45)
AZ_CMD_TIMEOUT_SECONDS="${AZ_CMD_TIMEOUT_SECONDS:-30}"

timestamp(){ date +"%Y-%m-%d %H:%M:%S"; }
log(){ echo "$(timestamp) - $*" | tee -a "$LOG_FILE"; }
err(){ echo "$(timestamp) - ERROR - $*" | tee -a "$LOG_FILE" >&2; }

cleanup(){ rm -f "$TMP_JSON" "$TMP_JSON.value" || true; }
trap cleanup EXIT

# ---------------- Utility wrappers ----------------

run_az() {
  # usage: run_az "desc" -- <cmd> [args...]
  local desc="$1"; shift
  if [[ "${1:-}" != "--" ]]; then
    err "run_az requires -- before the command"
    return 1
  fi
  shift
  log "START: ${desc}"
  echo "[ $(timestamp) ] ${desc} ..." 1>&2
  if command -v timeout >/dev/null 2>&1; then
    if timeout "${AZ_CMD_TIMEOUT_SECONDS}s" "$@" >>"$LOG_FILE" 2>&1; then
      log "OK: ${desc}"
      echo "[ $(timestamp) ] ${desc} ... OK" 1>&2
      return 0
    else
      log "FAIL/Timeout: ${desc}"
      echo "[ $(timestamp) ] ${desc} ... FAIL or TIMEOUT" 1>&2
      return 1
    fi
  else
    if "$@" >>"$LOG_FILE" 2>&1; then
      log "OK: ${desc}"
      echo "[ $(timestamp) ] ${desc} ... OK" 1>&2
      return 0
    else
      log "FAIL: ${desc}"
      echo "[ $(timestamp) ] ${desc} ... FAIL" 1>&2
      return 1
    fi
  fi
}

already_logged_in() {
  if az account show >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

logout_if_logged_in() {
  if already_logged_in; then
    log "Existing az session detected. Logging out before new login per policy."
    echo "[ $(timestamp) ] Logging out existing Azure session..." 1>&2
    run_az "az logout" -- az logout || true
  fi
}

show_last_log_lines() {
  echo "----- last 40 lines of $LOG_FILE -----"
  tail -n 40 "$LOG_FILE" || true
}

# ---------------- Login flows ----------------

sp_login_interactive() {
  echo
  echo "Service Principal login (interactive). Enter values below."
  read -r -p "Service Principal AppID (username): " SP_APPID
  read -r -s -p "Service Principal Password (password): " SP_PASS ; echo
  read -r -p "Tenant ID (or domain): " SP_TENANT

  echo "[ $(timestamp) ] Checking current az session..." 1>&2
  logout_if_logged_in

  log "Attempting SP login for appId $SP_APPID (tenant $SP_TENANT)"
  echo "[ $(timestamp) ] Running az login (SP) ..." 1>&2
  if run_az "az login (SP)" -- az login --service-principal \
         --username "$SP_APPID" \
         --password "$SP_PASS" \
         --tenant   "$SP_TENANT"
  then
    log "SP login succeeded for $SP_APPID"
    echo "[ $(timestamp) ] Logged in as SP: $SP_APPID" 1>&2
    # Show a short account summary to user (to prove we're in)
    echo "[ $(timestamp) ] Fetching az account summary..." 1>&2
    az account show --output table 2>/dev/null | tee -a "$LOG_FILE"
    return 0
  else
    err "SP login FAILED or timed out for $SP_APPID (see $LOG_FILE)"
    show_last_log_lines
    return 1
  fi
}

login_with_secret_value_as_user() {
  local try_user="$1"
  local secret_value="$2"
  local context_msg="${3:-}"

  echo "[ $(timestamp) ] Checking current az session before target login..." 1>&2
  logout_if_logged_in

  log "Attempting az login as $try_user ${context_msg:+($context_msg)}"
  echo "[ $(timestamp) ] Running az login for user/SP: $try_user ..." 1>&2
  if run_az "az login (target $try_user)" -- az login -u "$try_user" -p "$secret_value"
  then
    log "Login succeeded for $try_user"
    echo "[ $(timestamp) ] Login succeeded for $try_user" 1>&2
    echo "[ $(timestamp) ] Current account:" 1>&2
    az account show --output table 2>/dev/null | tee -a "$LOG_FILE"
    return 0
  else
    err "Login failed or timed out for $try_user"
    show_last_log_lines
    return 1
  fi
}

# ---------------- Subscription / Vault / Secrets ----------------

choose_subscription() {
  if ! already_logged_in; then
    err "No active account info available. Please login first."
    return 1
  fi

  run_az "az account list" -- az account list --output json || { err "Unable to list subscriptions"; return 1; }
  cp "$LOG_FILE" "$LOG_FILE.tmp" 2>/dev/null || true
  # Extract the last JSON blob from the log into TMP_JSON
  awk '/^\[/,/\]$/' "$LOG_FILE.tmp" > "$TMP_JSON" || true
  rm -f "$LOG_FILE.tmp" || true

  if [[ -n "$JQ" && -s "$TMP_JSON" ]]; then
    local count; count=$(jq 'length' "$TMP_JSON" 2>/dev/null || echo 0)
    if [[ "$count" -gt 1 ]]; then
      echo "Available subscriptions:"
      jq -r '.[] | "\(.name) | \(.id)"' "$TMP_JSON" | nl -w2 -s'. ' -v1
      read -r -p "Enter subscription number to set (or press Enter to keep current): " sub_choice
      if [[ -n "$sub_choice" ]]; then
        sub_id=$(jq -r ".[$((sub_choice-1))].id" "$TMP_JSON")
        run_az "az account set $sub_id" -- az account set --subscription "$sub_id" || { err "Unable to set subscription"; return 1; }
        log "Set subscription to $sub_id"
      fi
    else
      echo "[info] Only one (or zero) subscription visible; nothing to change."
    fi
  else
    az account list --output table | tee -a "$LOG_FILE"
    read -r -p "If you want to set a subscription now, paste its ID (or press Enter to skip): " sub_id
    if [[ -n "$sub_id" ]]; then
      run_az "az account set $sub_id" -- az account set --subscription "$sub_id" || { err "Unable to set subscription"; return 1; }
      log "Set subscription to $sub_id"
    fi
  fi
}

select_vault() {
  if ! already_logged_in; then
    err "Please login first."
    return 1
  fi

  if ! run_az "az keyvault list" -- az keyvault list --output json; then
    err "Failed to list vaults"
    return 1
  fi

  # Pull the last JSON array from log into TMP_JSON
  awk '/^\[/,/\]$/' "$LOG_FILE" | tail -n +1 > "$TMP_JSON" || true

  if [[ -n "$JQ" && -s "$TMP_JSON" ]]; then
    local n; n=$(jq 'length' "$TMP_JSON" 2>/dev/null || echo 0)
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

select_secret_in_vault() {
  local vault="$1"
  if ! run_az "az keyvault secret list ($vault)" -- az keyvault secret list --vault-name "$vault" --query "[].name" -o tsv; then
    err "Failed to list secrets for $vault"
    return 1
  fi

  # Grab the last TSV lines from the log for names
  awk '/START: az keyvault secret list/,0' "$LOG_FILE" | tail -n +1 >/dev/null 2>&1 # noop to move cursor
  # Safer: re-run the command directly (to file) without cluttering log again:
  if ! az keyvault secret list --vault-name "$vault" --query "[].name" -o tsv > "$TMP_JSON" 2>>"$LOG_FILE"; then
    err "Failed to retrieve secret names for $vault"
    return 1
  fi

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
        if run_az "az keyvault secret show ($s)" -- az keyvault secret show --vault-name "$vault" --name "$s" --query 'value' -o tsv; then
          # Fetch value into file directly to avoid parsing from log
          if az keyvault secret show --vault-name "$vault" --name "$s" --query 'value' -o tsv > "$TMP_JSON.value" 2>>"$LOG_FILE"; then
            val="$(cat "$TMP_JSON.value")"
            echo "SECRET: $s = $val"
            [[ "$LOG_SECRET_VALUES" == "true" ]] && log "SECRET_VALUE: $s = $val"
          fi
        else
          echo "Failed: $s"
          log "Failed reading secret $s from $vault"
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
        if az keyvault secret show --vault-name "$vault" --name "$secret" --query 'value' -o tsv > "$TMP_JSON.value" 2>>"$LOG_FILE"; then
          secret_value="$(cat "$TMP_JSON.value")"
          echo "VALUE: $secret_value"
          log "Fetched secret $secret (value displayed in terminal on user confirmation)"
          [[ "$LOG_SECRET_VALUES" == "true" ]] && log "SECRET_VALUE: $secret = $secret_value"
          read -r -p "Do you want to mark an account username to $READPASS_LOG for follow-up? (enter username or leave blank): " assoc_user
          if [[ -n "$assoc_user" ]]; then
            echo "$(timestamp) - $assoc_user - secret:$secret - vault:$vault" >> "$READPASS_LOG"
            log "Marked $assoc_user in $READPASS_LOG"
          fi
          unset secret_value
          rm -f "$TMP_JSON.value" || true
        else
          err "Failed to fetch secret value for $secret"
        fi
      else
        echo "Cancelled."
      fi
      ;;
    3)
      read -r -p "Fetch secret value and attempt login? Proceed [y/N]: " c3
      if [[ "$c3" =~ ^[Yy]$ ]]; then
        if az keyvault secret show --vault-name "$vault" --name "$secret" --query 'value' -o tsv > "$TMP_JSON.value" 2>>"$LOG_FILE"; then
          secret_value="$(cat "$TMP_JSON.value")"
          echo "Fetched secret value (not logged)."
          read -r -p "Enter username (UPN) or SP appId to attempt az login as: " try_user
          if [[ -z "$try_user" ]]; then
            err "No username provided. Aborting attempt."
          else
            # logout first per policy, then try login with secret value
            if login_with_secret_value_as_user "$try_user" "$secret_value" "from secret:$secret vault:$vault"; then
              # success: add to readPass.log
              echo "$(timestamp) - $try_user - password_extracted_from:$secret - vault:$vault" >> "$READPASS_LOG"
              log "Wrote $try_user record to $READPASS_LOG"
            fi
          fi
          unset secret_value
          rm -f "$TMP_JSON.value" || true
        else
          err "Failed to fetch secret value for $secret"
        fi
      else
        echo "Cancelled."
      fi
      ;;
    *)
      echo "Going back."
      ;;
  esac
}

# ---------------- Menu ----------------

main_menu() {
  while true; do
    echo
    echo "Main Menu:"
    echo "  1) SP Login (service-principal)"
    echo "  2) Choose subscription"
    echo "  3) List vaults and inspect secrets"
    echo "  4) Show logs (last 200 lines)"
    echo "  5) Logout (if logged in)"
    echo "  6) Exit"
    read -r -p "Choose 1-6: " m
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
        if already_logged_in; then
          logout_if_logged_in
          echo "[ $(timestamp) ] Logged out." 1>&2
        else
          echo "[ $(timestamp) ] No active session." 1>&2
        fi
        ;;
      6)
        log "Exiting."
        break
        ;;
      *)
        echo "Invalid option"
        ;;
    esac
  done
}

# ---------------- Start ----------------

log "Script started by $(whoami)"
if ! command -v az >/dev/null 2>&1; then
  err "az CLI not found. Install azure-cli and retry."
  exit 1
fi

log "az version: $(az version 2>/dev/null | tr -d '\n' | cut -c1-220 || echo 'unknown')"
log "Proxy env: HTTP_PROXY=${HTTP_PROXY:-} HTTPS_PROXY=${HTTPS_PROXY:-} NO_PROXY=${NO_PROXY:-}"

main_menu
log "Script finished"
