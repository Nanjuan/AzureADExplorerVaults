#!/usr/bin/env bash
# az_kv_sp_explorer.sh
# Login as SP, list vaults, show secrets (with cross-vault search), fetch values on demand.
# Logs include timestamps; terminal output is clean (no timestamps).

set -o errexit
set -o nounset
set -o pipefail

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

LOG_SECRET_VALUES="${LOG_SECRET_VALUES:-false}"
AZ_CMD_TIMEOUT_SECONDS="${AZ_CMD_TIMEOUT_SECONDS:-30}"

CURRENT_LOGIN="unset"
NAV_SIGNAL=""

timestamp(){ date +"%Y-%m-%d %H:%M:%S"; }
log(){ echo "$(timestamp) - user:${CURRENT_LOGIN} - $*" >>"$LOG_FILE"; }
err(){ echo "$(timestamp) - user:${CURRENT_LOGIN} - ERROR - $*" >>"$LOG_FILE"; }
say(){ echo "$*"; }

# --- Log commands with safe redaction ---
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
    if timeout "${AZ_CMD_TIMEOUT_SECONDS}s" "$@" >>"$LOG_FILE" 2>&1; then
      log "OK: ${desc}"; return 0
    else
      log "FAIL/Timeout: ${desc}"; return 1
    fi
  else
    if "$@" >>"$LOG_FILE" 2>&1; then
      log "OK: ${desc}"; return 0
    else
      log "FAIL: ${desc}"; return 1
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

# ---------------- Login flow ----------------
sp_login_interactive() {
  echo
  echo "Service Principal login (interactive)."
  read -r -p "Service Principal AppID (username): " SP_APPID
  read -r -s -p "Service Principal Password: " SP_PASS ; echo
  read -r -p "Tenant ID (or domain): " SP_TENANT

  logout_if_logged_in

  log "Attempting SP login for appId $SP_APPID (tenant $SP_TENANT)"
  say "Logging in..."
  if run_az "az login (SP)" -- az login --service-principal \
        --username "$SP_APPID" --password "$SP_PASS" --tenant "$SP_TENANT"
  then
    CURRENT_LOGIN="$SP_APPID"
    log "SP login succeeded for $SP_APPID"
    say "Login successful as $SP_APPID"
  else
    err "SP login failed for $SP_APPID"
    say "Login failed — check $LOG_FILE for details."
  fi
}

# ---------------- Subscription / Vault / Secrets ----------------
choose_subscription() {
  if ! already_logged_in; then say "Please login first."; return 1; fi
  local subs_json="$TMP_DIR/subs.json"
  log_cmd az account list --output json
  az account list --output json >"$subs_json" 2>>"$LOG_FILE" || { say "Cannot list subscriptions."; return 1; }

  if ! command -v jq >/dev/null 2>&1; then
    az account list --output table
    read -r -p "Enter subscription ID (Enter to skip): " sub_id
    [[ -z "$sub_id" ]] && return 0
    run_az "az account set $sub_id" -- az account set --subscription "$sub_id" || say "Failed to set subscription."
    return
  fi

  mapfile -t SUB_NAMES < <(jq -r '.[].name' "$subs_json")
  mapfile -t SUB_IDS   < <(jq -r '.[].id' "$subs_json")

  (( ${#SUB_IDS[@]} == 0 )) && { say "No subscriptions found."; return 0; }
  echo "Available subscriptions:"
  for ((i=0;i<${#SUB_IDS[@]};i++)); do printf "%2d) %s | %s\n" $((i+1)) "${SUB_NAMES[$i]}" "${SUB_IDS[$i]}"; done
  read -r -p "Choose subscription number: " sub_choice
  [[ -z "$sub_choice" ]] && return 0
  (( sub_choice<1 || sub_choice>${#SUB_IDS[@]} )) && { say "Invalid choice."; return 1; }
  local sub_id="${SUB_IDS[$((sub_choice-1))]}"
  run_az "az account set $sub_id" -- az account set --subscription "$sub_id"
  log "Subscription set to $sub_id"
}

vault_browser() {
  while true; do
    NAV_SIGNAL=""
    local vaults_json="$TMP_DIR/vaults.json"
    log_cmd az keyvault list --output json
    az keyvault list --output json >"$vaults_json" 2>>"$LOG_FILE" || { say "Failed to list vaults."; return 1; }

    if ! command -v jq >/dev/null 2>&1; then
      az keyvault list --output table
      read -r -p "Vault name (or q): " VAULT_NAME
      [[ "$VAULT_NAME" == "q" ]] && return 0
      secrets_browser "$VAULT_NAME"
      continue
    fi

    mapfile -t VAULT_NAMES < <(jq -r '.[].name' "$vaults_json")
    mapfile -t VAULT_URIS  < <(jq -r '.[].properties.vaultUri // ""' "$vaults_json")

    (( ${#VAULT_NAMES[@]} == 0 )) && { say "No Key Vaults found."; return 0; }

    echo "Key Vaults:"
    for ((i=0;i<${#VAULT_NAMES[@]};i++)); do printf "%2d) %s (%s)\n" $((i+1)) "${VAULT_NAMES[$i]}" "${VAULT_URIS[$i]}"; done
    echo "  s) Search secret names across all vaults"
    echo "  q) Back to Main Menu"
    read -r -p "Choice: " vchoice
    [[ "$vchoice" == "q" ]] && return 0
    [[ "$vchoice" == "s" ]] && { cross_vault_search; continue; }
    (( vchoice<1 || vchoice>${#VAULT_NAMES[@]} )) && { say "Invalid."; continue; }

    local chosen="${VAULT_NAMES[$((vchoice-1))]}"
    say "Selected vault: $chosen"
    secrets_browser "$chosen"
  done
}

secrets_browser() {
  local vault="$1"
  while true; do
    say "Listing secrets for vault: $vault"
    log_cmd az keyvault secret list --vault-name "$vault" --query "[].{Name:name}" -o table
    az keyvault secret list --vault-name "$vault" --query "[].{Name:name}" -o table 2>>"$LOG_FILE" || { say "Failed to list."; return 1; }

    local secrets_tsv="$TMP_DIR/secrets.tsv"
    az keyvault secret list --vault-name "$vault" --query "[].name" -o tsv >"$secrets_tsv" 2>>"$LOG_FILE" || { say "Failed to list."; return 1; }
    mapfile -t SECRET_NAMES <"$secrets_tsv"
    (( ${#SECRET_NAMES[@]} == 0 )) && { say "No secrets."; return 0; }

    for s in "${SECRET_NAMES[@]}"; do log "ENUM: vault:${vault} secret_name:${s}"; done
    echo "Secrets:"
    for ((i=0;i<${#SECRET_NAMES[@]};i++)); do printf "%2d) %s\n" $((i+1)) "${SECRET_NAMES[$i]}"; done
    echo "  b) Back to Vaults"
    echo "  q) Main Menu"
    read -r -p "Choice: " scol
    [[ "$scol" == "q" ]] && NAV_SIGNAL="MAIN" && return 0
    [[ "$scol" == "b" ]] && NAV_SIGNAL="VAULTS" && return 0
    (( scol<1 || scol>${#SECRET_NAMES[@]} )) && { say "Invalid."; continue; }
    secret_detail_loop "$vault" "$((scol-1))" SECRET_NAMES
  done
}

secret_detail_loop() {
  local vault="$1"; local idx="$2"; local arr_name="$3"
  local -n NAMES="$arr_name"; local total="${#NAMES[@]}"

  while true; do
    local secret="${NAMES[$idx]}"
    echo "Secret [$((idx+1))/$total]: $secret (vault: $vault)"
    echo "  1) Fetch and show VALUE"
    echo "  l) Back to Secrets List"
    echo "  n/p) Next/Previous secret"
    echo "  b) Vaults   q) Main Menu"
    read -r -p "Choice: " opt
    case "$opt" in
      1)
        log_cmd az keyvault secret show --vault-name "$vault" --name "$secret" --query value -o tsv
        if az keyvault secret show --vault-name "$vault" --name "$secret" --query 'value' -o tsv >"$TMP_DIR/val" 2>>"$LOG_FILE"; then
          secret_value="$(cat "$TMP_DIR/val")"
          echo "VALUE: $secret_value"
          log "Fetched secret $secret (value displayed)"
          [[ "$LOG_SECRET_VALUES" == "true" ]] && log "SECRET_VALUE: $secret = $secret_value"
          read -r -p "Mark username to $READPASS_LOG? (leave blank to skip): " assoc_user
          [[ -n "$assoc_user" ]] && echo "$(timestamp) - $assoc_user - secret:$secret - vault:$vault" >>"$READPASS_LOG"
          unset secret_value; rm -f "$TMP_DIR/val"
        else
          say "Failed to fetch."
        fi
        ;;
      l|L) return 0 ;;
      n|N) (( idx+1<total )) && ((idx++)) || say "Last secret." ;;
      p|P) (( idx>0 )) && ((idx--)) || say "First secret." ;;
      b|B) NAV_SIGNAL="VAULTS"; return 0 ;;
      q|Q) NAV_SIGNAL="MAIN"; return 0 ;;
      *) say "Invalid." ;;
    esac
  done
}

cross_vault_search() {
  read -r -p "Enter substring to find in secret names: " filter
  [[ -z "$filter" ]] && { say "Empty."; return; }
  log "SEARCH_FILTER:${filter}"
  local VAULTS_ALL=()
  log_cmd az keyvault list --query "[].name" -o tsv
  az keyvault list --query "[].name" -o tsv >"$TMP_DIR/vaults.tsv" 2>>"$LOG_FILE" || { say "Failed."; return; }
  mapfile -t VAULTS_ALL <"$TMP_DIR/vaults.tsv"
  (( ${#VAULTS_ALL[@]} == 0 )) && { say "No vaults."; return; }

  echo "Search results for \"$filter\":"
  for v in "${VAULTS_ALL[@]}"; do
    az keyvault secret list --vault-name "$v" --query "[].name" -o tsv >"$TMP_DIR/names.tsv" 2>>"$LOG_FILE" || continue
    mapfile -t HITS < <(grep -iF -- "$filter" "$TMP_DIR/names.tsv" || true)
    (( ${#HITS[@]} == 0 )) && continue
    echo "Vault: $v"; for nm in "${HITS[@]}"; do echo "  - $nm"; log "ENUM_SEARCH: vault:${v} secret:${nm} substr:${filter}"; done
  done
}

list_all_vaults_and_secret_names() {
  log_cmd az keyvault list --query "[].name" -o tsv
  az keyvault list --query "[].name" -o tsv >"$TMP_DIR/vaults.tsv" 2>>"$LOG_FILE" || { say "Failed."; return; }
  mapfile -t VAULTS_ALL <"$TMP_DIR/vaults.tsv"
  (( ${#VAULTS_ALL[@]} == 0 )) && { say "No vaults."; return; }

  for v in "${VAULTS_ALL[@]}"; do
    echo "=== Vault: $v ==="
    az keyvault secret list --vault-name "$v" --query "[].{Name:name}" -o table 2>>"$LOG_FILE" | tee -a "$LOG_FILE"
  done
}

main_menu() {
  while true; do
    echo
    echo "Main Menu:"
    echo "  1) SP Login"
    echo "  2) Choose subscription"
    echo "  3) Browse vaults → secrets"
    echo "  4) Show logs"
    echo "  5) Logout"
    echo "  6) List ALL vaults & secret names"
    echo "  7) Exit"
    read -r -p "Choice: " c
    case "$c" in
      1) sp_login_interactive ;;
      2) choose_subscription ;;
      3) already_logged_in || { say "Please login first."; continue; }; vault_browser ;;
      4) tail -n 200 "$LOG_FILE" ;;
      5) logout_if_logged_in; CURRENT_LOGIN="unset"; say "Logged out." ;;
      6) list_all_vaults_and_secret_names ;;
      7) log "Exiting."; break ;;
      *) say "Invalid." ;;
    esac
  done
}

# ---------------- Start ----------------
log "Script started by $(whoami)"
log_cmd az version
main_menu
log "Script finished"
