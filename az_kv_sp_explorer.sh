#!/usr/bin/env bash
# az_kv_sp_explorer.sh
# Login as SP, list vaults, show secrets as a table, fetch values on demand,
# optionally try logging in as another user/SP using a fetched value.
# Logs to {date}.{time}.script.log (no secret values by default) and {date}.{time}.readPass.log (usernames only).

set -o errexit
set -o nounset
set -o pipefail

# --- Require Bash explicitly (avoid sh/dash issues) ---
if [ -z "${BASH_VERSION:-}" ]; then
  echo "This script must be run with bash. Try: bash $0" >&2
  exit 1
fi

# ----- timestamped log files -----
START_STAMP="$(date +"%Y%m%d.%H%M%S")"
LOG_FILE="./${START_STAMP}.script.log"
READPASS_LOG="./${START_STAMP}.readPass.log"

TMP_DIR="/tmp/az_kv_sp_explorer.$$"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

# Do NOT log secret values by default. Override: export LOG_SECRET_VALUES=true
LOG_SECRET_VALUES="${LOG_SECRET_VALUES:-false}"

# Timeout for az calls (seconds). Override with: export AZ_CMD_TIMEOUT_SECONDS=45
AZ_CMD_TIMEOUT_SECONDS="${AZ_CMD_TIMEOUT_SECONDS:-30}"

# Track who we're logged in as (shown on every log line)
CURRENT_LOGIN="unset"

timestamp(){ date +"%Y-%m-%d %H:%M:%S"; }
log(){ echo "$(timestamp) - user:${CURRENT_LOGIN} - $*" | tee -a "$LOG_FILE"; }
err(){ echo "$(timestamp) - user:${CURRENT_LOGIN} - ERROR - $*" | tee -a "$LOG_FILE" >&2; }
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

already_logged_in() { az account show >/dev/null 2>&1; }

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
    CURRENT_LOGIN="$SP_APPID"
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
    CURRENT_LOGIN="$try_user"
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

  if ! command -v jq >/dev/null 2>&1; then
    say "jq not found; showing raw table instead."
    az account list --output table | tee -a "$LOG_FILE"
    read -r -p "Paste subscription ID to set (or Enter to keep current): " sub_id
    if [[ -n "$sub_id" ]]; then
      run_az "az account set $sub_id" -- az account set --subscription "$sub_id" || { err "Unable to set subscription"; return 1; }
      log "Active subscription set to $sub_id"
    fi
    return 0
  fi

  mapfile -t SUB_NAMES < <(jq -r '.[].name' "$subs_json")
  mapfile -t SUB_IDS   < <(jq -r '.[].id'   "$subs_json")

  if ((${#SUB_IDS[@]} <= 1)); then
    say "One or zero subscriptions visible; nothing to change."
    return 0
  fi

  echo "Available subscriptions:"
  for ((i=0; i<${#SUB_IDS[@]}; i++)); do
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
  run_az "az account set $sub_id" -- az account set --subscription "$sub_id" || { err "Unable to set subscription"; return 1; }
  log "Active subscription set to $sub_id"
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

  # If jq is missing, fall back to table + manual name entry
  if ! command -v jq >/dev/null 2>&1; then
    say "jq not found; showing vaults in table. Enter vault name manually."
    az keyvault list --output table | tee -a "$LOG_FILE"
    read -r -p "Enter vault name to inspect (or q to cancel): " VAULT_NAME
    [[ "${VAULT_NAME:-}" == "q" ]] && return 2
    if [[ -z "${VAULT_NAME:-}" ]]; then err "Empty vault name."; return 1; fi
    log "Selected vault: $VAULT_NAME"
    echo "Selected vault: $VAULT_NAME"
    return 0
  fi

  # Normal path with jq
  mapfile -t VAULT_NAMES < <(jq -r '.[].name' "$vaults_json")
  mapfile -t VAULT_URIS  < <(jq -r '.[].properties.vaultUri // ""' "$vaults_json")

  if ((${#VAULT_NAMES[@]} == 0)); then
    echo "No Key Vaults found or insufficient permissions."
    return 1
  fi

  # Print with safe defaults to avoid unbound variable on URIs
  echo "Key Vaults:"
  for ((i=0; i<${#VAULT_NAMES[@]}; i++)); do
    uri="${VAULT_URIS[$i]:-}"
    printf "%2d) %s (%s)\n" $((i+1)) "${VAULT_NAMES[$i]}" "$uri"
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

  # Show your requested table view
  say "Listing secrets (table) for vault: $vault"
  az keyvault secret list --vault-name "$vault" --query "[].{Name:name}" -o table 2>>"$LOG_FILE" || {
    err "Failed to list secrets (table) for $vault"
    return 1
  }

  # Build a numbered list for selection from TSV (names only)
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

  # NEW: log each enumerated secret name with vault and user
  for s in "${SECRET_NAMES[@]}"; do
    log "ENUM: vault:${vault} secret_name:${s}"
  done

  echo
  echo "Select a secret by number to fetch its VALUE, or choose:"
  echo "  a) Fetch ALL values (display only; high risk)"
  echo "  q) Back"
  echo
  for ((i=0; i<${#SECRET_NAMES[@]}; i++)); do
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

# -------- List all vaults and secret NAMES (no values) --------
list_all_vaults_and_secret_names() {
  if ! already_logged_in; then
    err "Please login first."
    return 1
  fi

  say "Enumerating all Key Vaults and listing secret NAMES (no values)..."

  # Try jq path first for nicer output; else fallback to tsv
  if command -v jq >/dev/null 2>&1; then
    local vaults_json="$TMP_DIR/vaults_all.json"
    if ! az keyvault list --output json > "$vaults_json" 2>>"$LOG_FILE"; then
      err "Failed to list vaults"
      return 1
    fi
    mapfile -t VAULTS_ALL < <(jq -r '.[].name' "$vaults_json")
  else
    if ! az keyvault list --query "[].name" -o tsv > "$TMP_DIR/vaults.tsv" 2>>"$LOG_FILE"; then
      err "Failed to list vaults"
      return 1
    fi
    mapfile -t VAULTS_ALL < "$TMP_DIR/vaults.tsv"
  fi

  if ((${#VAULTS_ALL[@]} == 0)); then
    echo "No Key Vaults found or insufficient permissions."
    return 0
  fi

  for v in "${VAULTS_ALL[@]}"; do
    echo
    echo "=== Vault: $v ==="
    # Screen: secret names table (no values)
    if ! az keyvault secret list --vault-name "$v" --query "[].{Name:name}" -o table 2>>"$LOG_FILE" | tee -a "$LOG_FILE"; then
      echo "(failed to list secrets for $v)"
      log "Failed to list secrets (names) for $v"
      continue
    fi

    # Log: one line per secret with vault name
    if az keyvault secret list --vault-name "$v" --query "[].name" -o tsv > "$TMP_DIR/names.tsv" 2>>"$LOG_FILE"; then
      while IFS= read -r nm; do
        [[ -z "$nm" ]] && continue
        log "ENUM: vault:${v} secret_name:${nm}"
      done < "$TMP_DIR/names.tsv"
    fi
  done

  say "Completed listing secret names for all vaults."
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
    echo "  6) Show ALL vaults and their secret NAMES (no values)"
    echo "  7) Exit"
    read -r -p "Choose 1-7: " m
    case "$m" in
      1) sp_login_interactive || echo "SP login failed; check $LOG_FILE" ;;
      2) choose_subscription ;;
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
        list_all_vaults_and_secret_names
        ;;
      7)
        log "Exiting."
        break
        ;;
      *) echo "Invalid option" ;;
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
