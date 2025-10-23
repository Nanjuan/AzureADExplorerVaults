#!/usr/bin/env bash
# az_kv_sp_explorer.sh
# Login as SP, list vaults, show secrets as a table, fetch values on demand,
# optionally try logging in as another user/SP using a fetched value.
# Logs to script.log (no secret values by default) and readPass.log (usernames only).

set -o errexit
set -o nounset
set -o pipefail

# --- Hard require Bash (avoid dash/sh arithmetic and [[ ]] errors) ---
if [ -z "${BASH_VERSION:-}" ]; then
  echo "This script must be run with bash. Try: bash $0" >&2
  exit 1
fi

LOG_FILE="./script.log"
READPASS_LOG="./readPass.log"
TMP_DIR="/tmp/az_kv_sp_explorer.$$"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

# Do NOT log secret values by default. Override: export LOG_SECRET_VALUES=true
LOG_SECRET_VALUES="${LOG_SECRET_VALUES:-false}"

# Timeout for az calls (seconds). Override with env if desired.
AZ_CMD_TIMEOUT_SECONDS="${AZ_CMD_TIMEOUT_SECONDS:-30}"

timestamp(){ date +"%Y-%m-%d %H:%M:%S"; }
log(){ echo "$(timestamp) - $*" | tee -a "$LOG_FILE"; }
err(){ echo "$(timestamp) - ERROR - $*" | tee -a "$LOG_FILE" >&2; }

say(){ echo "[ $(timestamp) ] $*" >&2; }

run_az() {
  # usage: run_az "desc" -- <cmd> [args...]
  local desc="$1"; shift
  if [[ "${1:-}" != "--" ]]; then
    err "run_az requires -- before the command"
    return 1
  fi
  shift
  log "START: ${desc}"
  say "${desc} ..."
  if command -v timeout >/dev/null 2>&1; then
    if timeout "${AZ_CMD_TIMEOUT_SECONDS}s" "$@" >>"$LOG_FILE" 2>&1; then
      log "OK: ${desc}"
      say "${desc} ... OK"
      return 0
    else
      log "FAIL/Timeout: ${desc}"
      say "${desc} ... FAIL or TIMEOUT"
      return 1
    fi
  else
    if "$@" >>"$LOG_FILE" 2>&1; then
      log "OK: ${desc}"
      say "${desc} ... OK"
      return 0
    else
      log "FAIL: ${desc}"
      say "${desc} ... FAIL"
      return 1
    fi
  fi
}

already_logged_in() {
  az account show >/dev/null 2>&1
}

logout_if_logged_in() {
  if already_logged_in; then
    log "Existing az session detected. Logging out first."
    say "Logging out existing Azure session..."
    run_az "az logout" -- az logout || true
  fi
}

# ---------------- Login flows ----------------

sp_login_interactive() {
  echo
  echo "Service Principal login (interactive). Enter values below."
  read -r -p "Service Principal AppID (username): " SP_APPID
  read -r -s -p "Service Principal Password (password): " SP_PASS ; echo
  read -r -p "Tenant ID (or domain): " SP_TENANT

  say "Checking current az session..."
  logout_if_logged_in

  log "Attempting SP login for appId $SP_APPID (tenant $SP_TENANT)"
  say "Running az login (SP)..."
  if run_az "az login (SP)" -- az login --service-principal \
        --username "$SP_APPID" \
        --password "$SP_PASS" \
        --tenant   "$SP_TENANT"
  then
    log "SP login succeeded for $SP_APPID"
    say "Logged in as SP: $SP_APPID"
    say "Account summary:"
    az account show --output table 2>/dev/null | tee -a "$LOG_FILE"
    return 0
  else
    err "SP login FAILED or timed out for $SP_APPID"
    tail -n 40 "$LOG_FILE" || true
    return 1
  fi
}

login_with_secret_value_as_user() {
  local try_user="$1"
  local secret_value="$2"
  local context_msg="${3:-}"

  say "Preparing to login as: $try_user ($context_msg)"
  logout_if_logged_in

  log "Attempting az login as $try_user ${context_msg:+($context_msg)}"
  say "Running az login for $try_user ..."
  if run_az "az login (target $try_user)" -- az login -u "$try_user" -p "$secret_value"
  then
    log "Login succeeded for $try_user"
    say "Login succeeded for $try_user"
    say "Current account:"
    az account show --output table 2>/dev/null | tee -a "$LOG_FILE"
    return 0
  else
    err "Login failed or timed out for $try_user"
    tail -n 40 "$LOG_FILE" || true
    return 1
  fi
}

# ---------------- Subscription / Vault / Secrets ----------------

choose_subscription() {
  if ! already_logged_in; then
    err "No active account info. Please login first."
    return 1
  fi

  local subs_json="$TMP_DIR/subs.json"
  if ! az account list --output json >"$subs_json" 2>>"$LOG_FILE"; then
    err "Unable to list subscriptions"
    return 1
  fi

  # Build arrays of names & ids.
  mapfile -t SUB_NAMES < <(jq -r '.[].name' "$subs_json" 2>/dev/null || echo)
  mapfile -t SUB_IDS   < <(jq -r '.[].id'   "$subs_json" 2>/dev/null || echo)

  if ((${#SUB_IDS[@]} <= 1)); then
    say "One or zero subscriptions visible; nothing to change."
    return 0
  fi

  echo "Available subscriptions:"
  for i in "${!SUB_IDS[@]}"; do
    printf "%2d) %s | %s\n" $((i+1)) "${SUB_NAMES[$i]}" "${SUB_IDS[$i]}"
  done

  read -r -p "Enter subscription number to set (or press Enter to keep current): " sub_choice
  if [[ -z "$sub_choice" ]]; then
    say "Keeping current subscription."
    return 0
  fi
  if [[ ! "$sub_choice" =~ ^[0-9]+$ ]]; then
    err "Invalid selection (not a number)."
    return 1
  fi

  local idx=$((sub_choice-1))
  if (( idx < 0 || idx >= ${#SUB_IDS[@]} )); then
    err "Invalid selection (out of range)."
    return 1
  fi

  local sub_id="${SUB_IDS[$idx]}"
  if run_az "az account set $sub_id" -- az account set --subscription "$sub_id"; then
    log "Active subscription set to $sub_id"
  else
    err "Failed to set subscription"
    return 1
  fi
}

select_vault() {
  if ! already_logged_in; then
    err "Please login first."
    return 1
  fi

  local vaults_json="$TMP_DIR/vaults.json"
  if ! az keyvault list --output json > "$vaults_json" 2>>"$LOG_FILE"; then
    err "Failed to list vaults"
    return 1
  fi

  mapfile -t VAULT_NAMES < <(jq -r '.[].name' "$vaults_json" 2>/dev/null || echo)
  mapfile -t VAULT_URIS  < <(jq -r '.[].properties.vaultUri // ""' "$vaults_json" 2>/dev/null || echo)

  if ((${#VAULT_NAMES[@]} == 0)); then
    echo "No Key Vaults found or insufficient permissions."
    return 1
  fi

  echo "Key Vaults:"
  for i in "${!VAULT_NAMES[@]}"; do
    printf "%2d) %s (%s)\n" $((i+1)) "${VAULT_NAMES[$i]}" "${VAULT_URIS[$i]}"
  done

  read -r -p "Choose vault number (or q to cancel): " vchoice
  [[ "$vchoice" == "q" ]] && return 2
  if [[ ! "$vchoice" =~ ^[0-9]+$ ]]; then
    err "Invalid selection (not a number)."
    return 1
  fi

  local idx=$((vchoice-1))
  if (( idx < 0 || idx >= ${#VAULT_NAMES[@]} )); then
    err "Invalid selection (out of range)."
    return 1
  fi

  VAULT_NAME="${VAULT_NAMES[$idx]}"
  log "Selected vault: $VAULT_NAME"
  echo "Selected vault: $VAULT_NAME"
  return 0
}

select_secret_in_vault() {
  local vault="$1"

  # Show the table the way you requested:
  say "Listing secrets (table) for vault: $vault"
  az keyvault secret list --vault-name "$vault" --query "[].{Name:name}" -o table 2>>"$LOG_FILE" || {
    err "Failed to list secrets (table) for $vault"
    return 1
  }

  # Build a numbered selection list from the names (TSV for clean parsing):
  local secrets_tsv="$TMP_DIR/secrets.tsv"
  if ! az keyvault secret list --vault-name "$vault" --query "[].name" -o tsv > "$secrets_tsv" 2>>"$LOG_FILE"; then
    err "Failed to list secret names for $vault"
    return 1
  fi

  mapfile -t SECRET_NAMES < "$secrets_tsv"
  if ((${#SECRET_NAMES[@]} == 0)); then
    echo "No secrets found or insufficient permissions."
    return 1
  fi

  echo
  echo "Select a secret by number to fetch its VALUE, or choose:"
  echo "  a) Fetch ALL values (display only; high risk)"
  echo "  q) Back"
  echo
  for i in "${!SECRET_NAMES[@]}"; do
    printf "%2d) %s\n" $((i+1)) "${SECRET_NAMES[$i]}"
  done

  read -r -p "Your choice: " scol
  [[ "$scol" == "q" ]] && return 2

  if [[ "$scol" == "a" ]]; then
    read -r -p "Fetch ALL values and display on screen? [y/N]: " confirm_all
    if [[ "$confirm_all" =~ ^[Yy]$ ]]; then
      for s in "${SECRET_NAMES[@]}"; do
        if az keyvault secret show --vault-name "$vault" --name "$s" --query 'value' -o tsv > "$TMP_DIR/val" 2>>"$LOG_FILE"; then
          val="$(cat "$TMP_DIR/val")"
          echo "SECRET: $s = $val"
          [[ "$LOG_SECRET_VALUES" == "true" ]] && log "SECRET_VALUE: $s = $val"
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

  if [[ ! "$scol" =~ ^[0-9]+$ ]]; then
    err "Invalid selection (not a number)."
    return 1
  fi

  local idx=$((scol-1))
  if (( idx < 0 || idx >= ${#SECRET_NAMES[@]} )); then
    err "Invalid selection (out of range)."
    return 1
  fi

  SECRET_NAME="${SECRET_NAMES[$idx]}"
  log "Selected secret: $SECRET_NAME"
  return 0
}

inspect_secret_and_maybe_login() {
  local vault="$1"
  local secret="$2"
  echo
  echo "Secret: $secret in vault: $vault"
  echo "Options:"
  echo "  1) Fetch and show secret VALUE"
  echo "  2) Fetch value and attempt az login as another user/SP"
  echo "  3) Back"
  read -r -p "Choose 1-3: " opt

  case "$opt" in
    1)
      if az keyvault secret show --vault-name "$vault" --name "$secret" --query 'value' -o tsv > "$TMP_DIR/val" 2>>"$LOG_FILE"; then
        secret_value="$(cat "$TMP_DIR/val")"
        echo "VALUE: $secret_value"
        log "Fetched secret $secret (value displayed on-screen)"
        [[ "$LOG_SECRET_VALUES" == "true" ]] && log "SECRET_VALUE: $secret = $secret_value"
        read -r -p "Mark an account username to $READPASS_LOG for follow-up? (enter username or leave blank): " assoc_user
        if [[ -n "$assoc_user" ]]; then
          echo "$(timestamp) - $assoc_user - secret:$secret - vault:$vault" >> "$READPASS_LOG"
          log "Marked $assoc_user in $READPASS_LOG"
        fi
        unset secret_value
        rm -f "$TMP_DIR/val" || true
      else
        err "Failed to fetch value for $secret"
      fi
      ;;
    2)
      if az keyvault secret show --vault-name "$vault" --name "$secret" --query 'value' -o tsv > "$TMP_DIR/val" 2>>"$LOG_FILE"; then
        secret_value="$(cat "$TMP_DIR/val")"
        echo "Fetched secret value (not logged)."
        read -r -p "Enter username (UPN) or SP appId to attempt az login as: " try_user
        if [[ -z "$try_user" ]]; then
          err "No username provided. Aborting attempt."
        else
          if login_with_secret_value_as_user "$try_user" "$secret_value" "from secret:$secret vault:$vault"; then
            echo "$(timestamp) - $try_user - password_extracted_from:$secret - vault:$vault" >> "$READPASS_LOG"
            log "Wrote $try_user record to $READPASS_LOG"
          fi
        fi
        unset secret_value
        rm -f "$TMP_DIR/val" || true
      else
        err "Failed to fetch value for $secret"
      fi
      ;;
    *)
      echo "Back."
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
    echo "  3) List vaults -> show secrets table -> fetch/act"
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
          say "Logged out."
        else
          say "No active session."
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
