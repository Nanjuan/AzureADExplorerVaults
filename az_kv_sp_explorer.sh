#!/usr/bin/env bash
# az_kv_sp_explorer.sh
# Login as SP, list vaults, search across vaults, browse secrets, fetch values on demand.
# Terminal output is clean (no timestamps). Logs contain timestamps and command traces.
#
# Optional config file:
#   Path (default): ./az_kv_sp_explorer.conf
#   Format: KEY=VALUE (no quotes). Supported keys:
#     TENANT_ID=00000000-0000-0000-0000-000000000000
#     LOG_SECRET_VALUES=false
#     AZ_CMD_TIMEOUT_SECONDS=30
#
# Example:
#   TENANT_ID=11111111-2222-3333-4444-555555555555
#   LOG_SECRET_VALUES=false
#   AZ_CMD_TIMEOUT_SECONDS=45

set -o errexit
set -o nounset
set -o pipefail

# Require bash
if [ -z "${BASH_VERSION:-}" ]; then
  echo "This script must be run with bash. Try: bash $0" >&2
  exit 1
fi

# ----- Timestamped log files -----
START_STAMP="$(date +"%Y%m%d.%H%M%S")"
LOG_FILE="./${START_STAMP}.script.log"
READPASS_LOG="./${START_STAMP}.readPass.log"

TMP_DIR="/tmp/az_kv_sp_explorer.$$"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

# Settings (may be overridden by config)
LOG_SECRET_VALUES="${LOG_SECRET_VALUES:-false}"         # set true to also log secret values (not recommended)
AZ_CMD_TIMEOUT_SECONDS="${AZ_CMD_TIMEOUT_SECONDS:-30}"  # wrap az calls in timeout

# Config path
CONFIG_FILE="${CONFIG_FILE:-./az_kv_sp_explorer.conf}"

# State
CURRENT_LOGIN="unset"
NAV_SIGNAL=""

# ===== Persistent capture (functions only; not Main Menu) =====
CAPTURE_ENABLED="false"   # when true, function outputs are mirrored to CAPTURE_FILE (both stdout & stderr)
CAPTURE_FILE=""           # target file

timestamp(){ date +"%Y-%m-%d %H:%M:%S"; }
# Log to file only (with timestamps)
log(){ echo "$(timestamp) - user:${CURRENT_LOGIN} - $*" >>"$LOG_FILE"; }
err(){ echo "$(timestamp) - user:${CURRENT_LOGIN} - ERROR - $*" >>"$LOG_FILE"; }
# Clean terminal output (no timestamps)
say(){ echo "$*" >&2; }

# ----- Load config (safe parser for KEY=VALUE lines) -----
TENANT_ID_CFG="${TENANT_ID_CFG:-}"
load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    while IFS='=' read -r key val; do
      key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
      val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
      [[ -z "$key" || "$key" =~ ^# ]] && continue
      case "$key" in
        TENANT_ID) TENANT_ID_CFG="$val" ;;
        LOG_SECRET_VALUES) LOG_SECRET_VALUES="$val" ;;
        AZ_CMD_TIMEOUT_SECONDS) AZ_CMD_TIMEOUT_SECONDS="$val" ;;
        *) : ;;
      esac
    done < "$CONFIG_FILE"
    log "Loaded config from $CONFIG_FILE (TENANT_ID present: $([[ -n "$TENANT_ID_CFG" ]] && echo yes || echo no))"
  fi
}

# Log commands with safe redaction (don’t leak secrets in logs)
log_cmd() {
  local out=""; local redact_next=0
  for arg in "$@"; do
    if (( redact_next )); then out+=" ***REDACTED***"; redact_next=0; continue; fi
    case "$arg" in
      --password|--client-secret|-p) out+=" $(printf '%q' "$arg")"; redact_next=1 ;;
      *) out+=" $(printf '%q' "$arg")" ;;
    esac
  done
  log "CMD:${out# }"
}

run_az() {
  local desc="$1"; shift
  if [[ "${1:-}" != "--" ]]; then err "run_az requires -- before the command"; return 1; fi
  shift
  log "START: ${desc}"
  log_cmd "$@"
  say "${desc} ..."
  if command -v timeout >/dev/null 2>&1; then
    if timeout "${AZ_CMD_TIMEOUT_SECONDS}s" "$@" >>"$LOG_FILE" 2>&1; then log "OK: ${desc}"; return 0
    else log "FAIL/Timeout: ${desc}"; return 1; fi
  else
    if "$@" >>"$LOG_FILE" 2>&1; then log "OK: ${desc}"; return 0
    else log "FAIL: ${desc}"; return 1; fi
  fi
}

already_logged_in() { az account show >/dev/null 2>&1; }

# ===== Capture toggle helpers (functions-only capture) =====
capture_enable() {
  read -r -p "Enter TXT filename to capture function outputs (append mode): " CAPTURE_FILE
  if [[ -z "${CAPTURE_FILE:-}" ]]; then
    say "No file provided. Capture not enabled."
    return 0
  fi
  : >> "$CAPTURE_FILE" || { say "Cannot write to $CAPTURE_FILE"; CAPTURE_FILE=""; return 1; }
  CAPTURE_ENABLED="true"
  say "Capture ENABLED (functions only) → $CAPTURE_FILE"
}

capture_disable() {
  if [[ "$CAPTURE_ENABLED" != "true" ]]; then
    say "Capture is already disabled."
    return 0
  fi
  CAPTURE_ENABLED="false"
  say "Capture DISABLED."
}

# Run a function with capture if enabled (captures both stdout and stderr).
# Uses a brace group { ...; } to avoid subshell, so state changes persist.
run_maybe_capture() {
  if [[ "$CAPTURE_ENABLED" == "true" ]]; then
    { "$@"; } > >(tee -a "$CAPTURE_FILE") 2> >(tee -a "$CAPTURE_FILE" >&2)
  else
    "$@"
  fi
}

# ---- Helper: try to reuse an existing SP session for the given AppID ----
reuse_or_login_sp() {
  # Args: SP_APPID SP_PASS SP_TENANT
  local SP_APPID="$1"; local SP_PASS="$2"; local SP_TENANT="$3"

  # 1) Check if ANY account in the machine sessions matches this SP
  local existing_sub_id=""
  existing_sub_id="$(az account list --all \
    --query "[?user.type=='servicePrincipal' && user.name=='${SP_APPID}'].id | [0]" -o tsv 2>/dev/null || true)"

  if [[ -n "$existing_sub_id" ]]; then
    log "Found existing SP session for appId ${SP_APPID}; reusing (subscription ${existing_sub_id})."
    say "Reusing existing Service Principal session (subscription: ${existing_sub_id})"
    if ! run_az "az account set ${existing_sub_id}" -- az account set --subscription "$existing_sub_id"; then
      say "Warning: failed to set subscription to existing SP session; proceeding anyway."
    fi
    CURRENT_LOGIN="$SP_APPID"
    return 0
  fi

  # 2) Fallback: if current active account is already this SP, reuse it.
  local cur_name cur_type
  cur_name="$(az account show --query user.name -o tsv 2>/dev/null || true)"
  cur_type="$(az account show --query user.type -o tsv 2>/dev/null || true)"
  if [[ "$cur_type" == "servicePrincipal" && "$cur_name" == "$SP_APPID" ]]; then
    log "Active account already matches SP ${SP_APPID}; reusing."
    say "Reusing current active Service Principal session."
    CURRENT_LOGIN="$SP_APPID"
    return 0
  fi

  # 3) Not found → perform login (NO automatic logout)
  log "Attempting SP login for appId $SP_APPID (tenant $SP_TENANT)"
  say "Logging in..."
  if run_az "az login (SP)" -- az login --service-principal \
        --username "$SP_APPID" --password "$SP_PASS" --tenant "$SP_TENANT"
  then
    CURRENT_LOGIN="$SP_APPID"
    log "SP login succeeded for $SP_APPID"
    say "Login successful as $SP_APPID"
    return 0
  else
    err "SP login failed for $SP_APPID"
    say "Login failed — check $LOG_FILE for details."
    return 1
  fi
}

# ---------------- Login flow (Service Principal) ----------------
sp_login_interactive() {
  echo
  echo "Service Principal login (interactive)."
  read -r -p "Service Principal AppID (username): " SP_APPID
  read -r -s -p "Service Principal Password: " SP_PASS ; echo

  load_config
  local SP_TENANT=""
  if [[ -n "${TENANT_ID_CFG:-}" ]]; then
    echo "Config file detected at: $CONFIG_FILE"
    echo "TENANT_ID in config: $TENANT_ID_CFG"
    read -r -p "Use TENANT_ID from config? [Y/n]: " use_cfg
    if [[ -z "$use_cfg" || "$use_cfg" =~ ^[Yy]$ ]]; then
      SP_TENANT="$TENANT_ID_CFG"
    else
      read -r -p "Tenant ID (or domain): " SP_TENANT
    fi
  else
    read -r -p "Tenant ID (or domain): " SP_TENANT
  fi

  # Do NOT auto-logout. Reuse if present, else login.
  reuse_or_login_sp "$SP_APPID" "$SP_PASS" "$SP_TENANT"
}

# ---------------- Subscription selection ----------------
choose_subscription() {
  if ! already_logged_in; then say "Please login first."; return 1; fi

  local subs_json="$TMP_DIR/subs.json"
  log_cmd az account list --output json
  if ! az account list --output json >"$subs_json" 2>>"$LOG_FILE"; then
    err "Unable to list subscriptions"
    say "Cannot list subscriptions (see log)."
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    say "jq not found; showing table output."
    log_cmd az account list --output table
    az account list --output table 2>>"$LOG_FILE"
    read -r -p "Enter subscription ID to set (Enter to skip): " sub_id
    [[ -z "$sub_id" ]] && return 0
    run_az "az account set $sub_id" -- az account set --subscription "$sub_id" || say "Failed to set subscription."
    return 0
  fi

  mapfile -t SUB_NAMES < <(jq -r '.[].name' "$subs_json")
  mapfile -t SUB_IDS   < <(jq -r '.[].id'   "$subs_json")

  (( ${#SUB_IDS[@]} == 0 )) && { say "No subscriptions found."; return 0; }

  echo "Available subscriptions:"
  for ((i=0; i<${#SUB_IDS[@]}; i++)); do
    printf "%2d) %s | %s\n" $((i+1)) "${SUB_NAMES[$i]}" "${SUB_IDS[$i]}"
  done
  read -r -p "Choose subscription number (Enter to keep current): " sub_choice
  [[ -z "$sub_choice" ]] && return 0
  if [[ ! "$sub_choice" =~ ^[0-9]+$ ]]; then say "Invalid selection."; return 1; fi
  local idx=$((sub_choice-1))
  if (( idx < 0 || idx >= ${#SUB_IDS[@]} )); then say "Invalid selection."; return 1; fi
  local sub_id="${SUB_IDS[$idx]}"
  run_az "az account set $sub_id" -- az account set --subscription "$sub_id" || { say "Unable to set subscription."; return 1; }
  log "Active subscription set to $sub_id"
}

# ---------------- Vaults → Secrets → Secret Detail ----------------
vault_browser() {
  while true; do
    NAV_SIGNAL=""

    local vaults_json="$TMP_DIR/vaults.json"
    log_cmd az keyvault list --output json
    if ! az keyvault list --output json > "$vaults_json" 2>>"$LOG_FILE"; then
      err "Failed to list vaults"
      say "Failed to list vaults (see log)."
      return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
      say "jq not found; showing vaults in table. Enter vault name, 's' to search, or 'q' to main."
      log_cmd az keyvault list --output table
      az keyvault list --output table 2>>"$LOG_FILE"
      echo "  s) Search secret names across ALL vaults (by substring)"
      echo "  q) Back to Main Menu"
      read -r -p "Enter vault name or 's'/'q': " choice
      if [[ "$choice" == "q" ]]; then return 0; fi
      if [[ "$choice" == "s" ]]; then cross_vault_search; [[ "$NAV_SIGNAL" == "MAIN" ]] && { NAV_SIGNAL=""; return 0; }; continue; fi
      local VAULT_NAME="$choice"
      [[ -z "$VAULT_NAME" ]] && { say "Empty vault name."; continue; }
      say "Selected vault: $VAULT_NAME"
      secrets_browser "$VAULT_NAME" || true
      [[ "$NAV_SIGNAL" == "MAIN" ]] && { NAV_SIGNAL=""; return 0; }
      NAV_SIGNAL=""
      continue
    fi

    local VAULT_NAMES=()
    local VAULT_URIS=()
    mapfile -t VAULT_NAMES < <(jq -r '.[].name' "$vaults_json")
    mapfile -t VAULT_URIS  < <(jq -r '.[].properties.vaultUri // ""' "$vaults_json")

    (( ${#VAULT_NAMES[@]} == 0 )) && { say "No Key Vaults found."; return 0; }

    echo
    echo "Key Vaults:"
    for ((i=0; i<${#VAULT_NAMES[@]}; i++)); do
      uri="${VAULT_URIS[$i]:-}"
      printf "%2d) %s (%s)\n" $((i+1)) "${VAULT_NAMES[$i]}" "$uri"
    done
    echo "  s) Search secret names across ALL vaults (by substring)"
    echo "  q) Back to Main Menu"
    read -r -p "Choose number, or 's'/'q': " vchoice
    [[ "$vchoice" == "q" ]] && return 0
    if [[ "$vchoice" == "s" ]]; then
      cross_vault_search
      [[ "$NAV_SIGNAL" == "MAIN" ]] && { NAV_SIGNAL=""; return 0; }
      NAV_SIGNAL=""
      continue
    fi
    if [[ ! "$vchoice" =~ ^[0-9]+$ ]]; then say "Invalid selection."; continue; fi
    local idx=$((vchoice-1))
    if (( idx < 0 || idx >= ${#VAULT_NAMES[@]} )); then say "Invalid selection."; continue; fi

    local chosen_vault="${VAULT_NAMES[$idx]}"
    say "Selected vault: $chosen_vault"
    secrets_browser "$chosen_vault" || true
    [[ "$NAV_SIGNAL" == "MAIN" ]] && { NAV_SIGNAL=""; return 0; }
    NAV_SIGNAL=""
  done
}

secrets_browser() {
  local vault="$1"

  while true; do
    say "Listing secrets (table) for vault: $vault"
    log_cmd az keyvault secret list --vault-name "$vault" --query "[].{Name:name}" -o table
    if ! az keyvault secret list --vault-name "$vault" --query "[].{Name:name}" -o table 2>>"$LOG_FILE"; then
      err "Failed to list secrets (table) for $vault"
      say "Failed to list secrets (see log)."
      return 1
    fi

    local secrets_tsv="$TMP_DIR/secrets.tsv"
    log_cmd az keyvault secret list --vault-name "$vault" --query "[].name" -o tsv
    if ! az keyvault secret list --vault-name "$vault" --query "[].name" -o tsv > "$secrets_tsv" 2>>"$LOG_FILE"; then
      err "Failed to list secret names for $vault"
      say "Failed to list secret names (see log)."
      return 1
    fi
    mapfile -t SECRET_NAMES < "$secrets_tsv"
    (( ${#SECRET_NAMES[@]} == 0 )) && { say "No secrets found."; return 0; }

    for s in "${SECRET_NAMES[@]}"; do
      log "ENUM: vault:${vault} secret_name:${s}"
    done

    echo
    echo "Secrets in $vault:"
    for ((i=0; i<${#SECRET_NAMES[@]}; i++)); do
      printf "%2d) %s\n" $((i+1)) "${SECRET_NAMES[$i]}"
    done
    echo "  b) Back to Vaults"
    echo "  q) Main Menu"
    read -r -p "Your choice: " scol

    if [[ "$scol" == "q" ]]; then NAV_SIGNAL="MAIN"; return 0; fi
    if [[ "$scol" == "b" ]]; then NAV_SIGNAL="VAULTS"; return 0; fi
    if [[ ! "$scol" =~ ^[0-9]+$ ]]; then say "Invalid selection."; continue; fi
    local idx=$((scol-1))
    if (( idx < 0 || idx >= ${#SECRET_NAMES[@]} )); then say "Invalid selection."; continue; fi

    secret_detail_loop "$vault" "$idx" SECRET_NAMES || true
    if [[ "$NAV_SIGNAL" == "MAIN" ]]; then return 0; fi
    if [[ "$NAV_SIGNAL" == "VAULTS" ]]; then NAV_SIGNAL=""; return 0; fi
    NAV_SIGNAL=""
  done
}

secret_detail_loop() {
  local vault="$1"; local idx="$2"; local arr_name="$3"
  local -n NAMES="$arr_name"; local total="${#NAMES[@]}"

  while true; do
    local secret="${NAMES[$idx]}"
    echo
    echo "Secret [$((idx+1))/$total]: $secret (vault: $vault)"
    echo "  1) Fetch and show VALUE"
    echo "  l) Back to Secrets List"
    echo "  n) Next   p) Previous"
    echo "  b) Back to Vaults   q) Main Menu"
    read -r -p "Choose: " opt
    case "$opt" in
      1)
        log_cmd az keyvault secret show --vault-name "$vault" --name "$secret" --query value -o tsv
        if az keyvault secret show --vault-name "$vault" --name "$secret" --query 'value' -o tsv > "$TMP_DIR/val" 2>>"$LOG_FILE"; then
          secret_value="$(cat "$TMP_DIR/val")"
          echo "VALUE: $secret_value"
          log "Fetched secret $secret (value displayed on-screen)"
          [[ "$LOG_SECRET_VALUES" == "true" ]] && log "SECRET_VALUE: $secret = $secret_value"
          read -r -p "Mark an account username to $READPASS_LOG? (leave blank to skip): " assoc_user
          if [[ -n "$assoc_user" ]]; then
            echo "$(timestamp) - $assoc_user - secret:$secret - vault:$vault" >> "$READPASS_LOG"
            log "Marked $assoc_user in $READPASS_LOG"
          fi
          unset secret_value; rm -f "$TMP_DIR/val" || true
        else
          err "Failed to fetch value for $secret"; say "Failed to fetch value (see log)."
        fi
        ;;
      l|L) return 0 ;;
      n|N) if (( idx + 1 < total )); then idx=$((idx+1)); else say "Already at the last secret."; fi ;;
      p|P) if (( idx - 1 >= 0 )); then idx=$((idx-1)); else say "Already at the first secret."; fi ;;
      b|B) NAV_SIGNAL="VAULTS"; return 0 ;;
      q|Q) NAV_SIGNAL="MAIN"; return 0 ;;
      *) say "Invalid option." ;;
    esac
  done
}

# -------- Cross-vault search (by substring, names only) --------
cross_vault_search() {
  read -r -p "Enter substring to find in secret names (case-insensitive): " filter_substr
  [[ -z "$filter_substr" ]] && { say "Empty filter; cancelled."; NAV_SIGNAL=""; return 0; }
  log "SEARCH_FILTER: substr:${filter_substr}"

  local VAULTS_ALL=()
  if command -v jq >/dev/null 2>&1; then
    local vaults_json="$TMP_DIR/vaults_all.json"
    log_cmd az keyvault list --output json
    if ! az keyvault list --output json > "$vaults_json" 2>>"$LOG_FILE"; then
      err "Failed to list vaults"; say "Failed to list vaults (see log)."; NAV_SIGNAL=""; return 1
    fi
    mapfile -t VAULTS_ALL < <(jq -r '.[].name' "$vaults_json")
  else
    log_cmd az keyvault list --query "[].name" -o tsv
    if ! az keyvault list --query "[].name" -o tsv > "$TMP_DIR/vaults.tsv" 2>>"$LOG_FILE"; then
      err "Failed to list vaults"; say "Failed to list vaults (see log)."; NAV_SIGNAL=""; return 1
    fi
    mapfile -t VAULTS_ALL < "$TMP_DIR/vaults.tsv"
  fi

  (( ${#VAULTS_ALL[@]} == 0 )) && { say "No Key Vaults found."; NAV_SIGNAL=""; return 0; }

  local RES_VAULTS=(); local RES_SECRETS=()
  echo; echo "=== Search results for \"$filter_substr\" across all vaults ==="
  for v in "${VAULTS_ALL[@]}"; do
    log_cmd az keyvault secret list --vault-name "$v" --query "[].name" -o tsv
    if az keyvault secret list --vault-name "$v" --query "[].name" -o tsv > "$TMP_DIR/names.tsv" 2>>"$LOG_FILE"; then
      mapfile -t HITS < <(grep -iF -- "$filter_substr" "$TMP_DIR/names.tsv" || true)
      if ((${#HITS[@]} > 0)); then
        echo; echo "Vault: $v"
        for nm in "${HITS[@]}"; do
          printf "  - %s\n" "$nm"
          log "ENUM_SEARCH: vault:${v} secret_name:${nm} substr:${filter_substr}"
          RES_VAULTS+=("$v"); RES_SECRETS+=("$nm")
        done
      fi
    else
      log "Failed to list secrets for vault ${v} during search"
    fi
  done

  if ((${#RES_SECRETS[@]} == 0)); then
    echo; echo "(No matching secret names found.)"; NAV_SIGNAL=""; return 0
  fi

  while true; do
    echo; echo "Open a result by number, or:"
    echo "  r) New search"
    echo "  b) Back to Vaults"
    echo "  q) Main Menu"
    for ((k=0; k<${#RES_SECRETS[@]}; k++)); do
      printf "%3d) %s :: %s\n" $((k+1)) "${RES_VAULTS[$k]}" "${RES_SECRETS[$k]}"
    done
    read -r -p "Your choice: " choice
    case "$choice" in
      q) NAV_SIGNAL="MAIN"; return 0 ;;
      b) NAV_SIGNAL="VAULTS"; return 0 ;;
      r) cross_vault_search; return 0 ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
          local sel=$((choice-1))
          if (( sel >= 0 && sel < ${#RES_SECRETS[@]} )); then
            local v="${RES_VAULTS[$sel]}"; local s="${RES_SECRETS[$sel]}"
            log_cmd az keyvault secret list --vault-name "$v" --query "[].name" -o tsv
            if az keyvault secret list --vault-name "$v" --query "[].name" -o tsv > "$TMP_DIR/view.tsv" 2>>"$LOG_FILE"; then
              mapfile -t VIEW_NAMES < <(grep -iF -- "$filter_substr" "$TMP_DIR/view.tsv" || true)
              local start_idx=-1
              for ((i=0;i<${#VIEW_NAMES[@]};i++)); do [[ "${VIEW_NAMES[$i]}" == "$s" ]] && { start_idx=$i; break; }; done
              if (( start_idx == -1 )); then err "Selected secret not found in filtered view; refreshing search."; continue; fi
              secret_detail_loop "$v" "$start_idx" VIEW_NAMES || true
              if [[ "$NAV_SIGNAL" == "MAIN" || "$NAV_SIGNAL" == "VAULTS" ]]; then return 0; fi
              NAV_SIGNAL=""; continue
            else
              err "Failed to rebuild filtered view for $v"; say "Failed to open selection (see log)."; continue
            fi
          else
            say "Invalid selection."
          fi
        else
          say "Invalid choice."
        fi
        ;;
    esac
  done
}

# -------- Cross-vault search (names match substring) and PRINT VALUES --------
search_and_print_secret_values() {
  read -r -p "Enter substring to find in secret names (case-insensitive, will PRINT VALUES): " filter_substr
  [[ -z "$filter_substr" ]] && { say "Empty filter; cancelled."; return 0; }
  log "SEARCH_VALUES_FILTER: substr:${filter_substr}"

  local VAULTS_ALL=()
  log_cmd az keyvault list --query "[].name" -o tsv
  if ! az keyvault list --query "[].name" -o tsv > "$TMP_DIR/vaults.tsv" 2>>"$LOG_FILE"; then
    err "Failed to list vaults for value search"; say "Failed to list vaults (see log)."; return 1
  fi
  mapfile -t VAULTS_ALL < "$TMP_DIR/vaults.tsv"
  (( ${#VAULTS_ALL[@]} == 0 )) && { say "No Key Vaults found."; return 0; }

  local total_hits=0
  echo; echo "=== Matching secrets (with VALUES) for \"$filter_substr\" ==="
  for v in "${VAULTS_ALL[@]}"; do
    log_cmd az keyvault secret list --vault-name "$v" --query "[].name" -o tsv
    if az keyvault secret list --vault-name "$v" --query "[].name" -o tsv > "$TMP_DIR/names.tsv" 2>>"$LOG_FILE"; then
      mapfile -t HITS < <(grep -iF -- "$filter_substr" "$TMP_DIR/names.tsv" || true)
      if ((${#HITS[@]} > 0)); then
        echo; echo "Vault: $v"
        for nm in "${HITS[@]}"; do
          log_cmd az keyvault secret show --vault-name "$v" --name "$nm" --query value -o tsv
          if az keyvault secret show --vault-name "$v" --name "$nm" --query 'value' -o tsv > "$TMP_DIR/val.txt" 2>>"$LOG_FILE"; then
            val="$(cat "$TMP_DIR/val.txt")"
            echo "  ${nm} = ${val}"
            log "FETCHED_VALUE: vault:${v} secret_name:${nm} (printed to terminal)"
            [[ "$LOG_SECRET_VALUES" == "true" ]] && log "SECRET_VALUE: vault:${v} secret:${nm} value:${val}"
            total_hits=$((total_hits+1))
          else
            err "Failed to fetch value for ${nm} in ${v}"; echo "  ${nm} = <FAILED TO READ>"
          fi
        done
      fi
    else
      log "Failed to list secrets for vault ${v} during value search"
    fi
  done

  if (( total_hits == 0 )); then echo; echo "(No matching secret names found.)"
  else echo; echo "Total matching secrets printed: ${total_hits}"; fi
}

# -------- List all vaults and secret NAMES (no values) --------
list_all_vaults_and_secret_names() {
  log_cmd az keyvault list --query "[].name" -o tsv
  if ! az keyvault list --query "[].name" -o tsv > "$TMP_DIR/vaults.tsv" 2>>"$LOG_FILE"; then
    err "Failed to list vaults"; say "Failed to list vaults (see log)."; return 1
  fi
  mapfile -t VAULTS_ALL < "$TMP_DIR/vaults.tsv"
  (( ${#VAULTS_ALL[@]} == 0 )) && { say "No Key Vaults found."; return 0; }

  for v in "${VAULTS_ALL[@]}"; do
    echo; echo "=== Vault: $v ==="
    log_cmd az keyvault secret list --vault-name "$v" --query "[].{Name:name}" -o table
    az keyvault secret list --vault-name "$v" --query "[].{Name:name}" -o table 2>>"$LOG_FILE" | tee -a "$LOG_FILE" >/dev/stderr
    log_cmd az keyvault secret list --vault-name "$v" --query "[].name" -o tsv
    if az keyvault secret list --vault-name "$v" --query "[].name" -o tsv > "$TMP_DIR/names.tsv" 2>>"$LOG_FILE"; then
      while IFS= read -r nm; do [[ -z "$nm" ]] && continue; log "ENUM: vault:${v} secret_name:${nm}"; done < "$TMP_DIR/names.tsv"
    fi
  done
}

# -------- Selective logout (list accounts and choose which to logout) --------
list_and_select_logout() {
  say "Querying signed-in Azure accounts..."
  # TSV: Name[TAB]Type[TAB]Tenant[TAB]Sub
  local acct_tsv="$TMP_DIR/accounts.tsv"
  log_cmd az account list --all --query "[].{Name:user.name,Type:user.type,Tenant:tenantId,Sub:id}" -o tsv
  if ! az account list --all --query "[].{Name:user.name,Type:user.type,Tenant:tenantId,Sub:id}" -o tsv > "$acct_tsv" 2>>"$LOG_FILE"; then
    err "Failed to list accounts"
    say "Failed to list accounts (see log)."
    return 1
  fi

  if ! [[ -s "$acct_tsv" ]]; then
    say "No active az logins found."
    return 0
  fi

  # Deduplicate by Name|Type; count sessions; store a sample tenant
  declare -A SEEN COUNT TENANT_SAMPLE
  declare -a UNI_NAMES=() UNI_TYPES=()
  while IFS=$'\t' read -r nm tp tn sub; do
    [[ -z "${nm:-}" || -z "${tp:-}" ]] && continue
    local key="${nm}|${tp}"
    if [[ -z "${SEEN[$key]+x}" ]]; then
      SEEN[$key]=1
      COUNT[$key]=1
      TENANT_SAMPLE[$key]="$tn"
      UNI_NAMES+=("$nm")
      UNI_TYPES+=("$tp")
    else
      COUNT[$key]=$(( ${COUNT[$key]} + 1 ))
      # keep first tenant as sample
    fi
  done < "$acct_tsv"

  if ((${#UNI_NAMES[@]} == 0)); then
    say "No active az logins found."
    return 0
  fi

  echo
  echo "Signed-in accounts:"
  for ((i=0; i<${#UNI_NAMES[@]}; i++)); do
    key="${UNI_NAMES[$i]}|${UNI_TYPES[$i]}"
    cnt="${COUNT[$key]:-1}"
    tns="${TENANT_SAMPLE[$key]:-unknown}"
    printf "%2d) %-40s %-18s tenant:%s sessions:%s\n" $((i+1)) "${UNI_NAMES[$i]}" "${UNI_TYPES[$i]}" "$tns" "$cnt"
  done
  echo "  all) Logout ALL above"
  echo "   q) Cancel"
  read -r -p "Select indices (e.g., '1 3 4'), 'all', or 'q': " selection
  [[ "$selection" == "q" ]] && { say "Cancelled."; return 0; }

  # Build list of usernames to logout
  declare -a TO_LOGOUT=()
  if [[ "$selection" == "all" ]]; then
    for ((i=0; i<${#UNI_NAMES[@]}; i++)); do TO_LOGOUT+=("${UNI_NAMES[$i]}"); done
  else
    for tok in $selection; do
      [[ "$tok" =~ ^[0-9]+$ ]] || { say "Ignoring invalid token: $tok"; continue; }
      idx=$((tok-1))
      if (( idx < 0 || idx >= ${#UNI_NAMES[@]} )); then
        say "Index out of range: $tok"
        continue
      fi
      TO_LOGOUT+=("${UNI_NAMES[$idx]}")
    done
  fi

  if ((${#TO_LOGOUT[@]} == 0)); then
    say "Nothing selected."
    return 0
  fi

  # Perform targeted logouts
  for uname in "${TO_LOGOUT[@]}"; do
    say "Logging out: ${uname}"
    if run_az "az logout --username ${uname}" -- az logout --username "$uname"; then
      log "Logged out username:${uname}"
      if [[ "$CURRENT_LOGIN" == "$uname" ]]; then
        CURRENT_LOGIN="unset"
      fi
    else
      err "Failed to logout username:${uname}"
      say "  Failed to logout ${uname} (see log)."
    fi
  done

  say "Logout operations complete."
}

# ---------------- Main Menu ----------------
main_menu() {
  while true; do
    echo
    echo "Main Menu:"
    echo "  1) SP Login (service-principal)"
    echo "  2) Choose subscription"
    echo "  3) Browse vaults → (or search) → secrets → secret details"
    echo "  4) Show logs (last 200 lines)"
    echo "  5) Logout selected accounts"
    echo "  6) Show ALL vaults and their secret NAMES (no values)"
    echo "  7) Search across ALL vaults for secret NAMES matching a string and PRINT their VALUES"
    echo "  8) Exit"
    if [[ "$CAPTURE_ENABLED" == "true" ]]; then
      echo "  9) Disable capture (functions only)  (Capture: ON → $CAPTURE_FILE)"
    else
      echo "  9) Enable capture to TXT (functions only)  (Capture: OFF)"
    fi
    read -r -p "Choose 1-9: " m
    case "$m" in
      1) run_maybe_capture sp_login_interactive ;;
      2) run_maybe_capture choose_subscription ;;
      3)
        if ! already_logged_in; then say "Please login first."
        else run_maybe_capture vault_browser; fi
        ;;
      4)
        run_maybe_capture bash -c 'echo "----- '"$LOG_FILE"' -----"; tail -n 200 "'"$LOG_FILE"'" || true; echo; echo "----- '"$READPASS_LOG"' -----"; tail -n 200 "'"$READPASS_LOG"'" || true'
        ;;
      5) run_maybe_capture list_and_select_logout ;;
      6) run_maybe_capture list_all_vaults_and_secret_names ;;
      7) run_maybe_capture search_and_print_secret_values ;;
      8) log "Exiting."; break ;;
      9)
        if [[ "$CAPTURE_ENABLED" == "true" ]]; then
          capture_disable
        else
          capture_enable
        fi
        ;;
      *) say "Invalid option" ;;
    esac
  done
}

# ---------------- Start ----------------
log "Script started by $(whoami)"
log_cmd az version
log "az version: $(az version 2>/dev/null | tr -d '\n' | cut -c1-220 || echo 'unknown')"
log "Proxy env: HTTP_PROXY=${HTTP_PROXY:-} HTTPS_PROXY=${HTTPS_PROXY:-} NO_PROXY=${NO_PROXY:-}"

main_menu
log "Script finished"
