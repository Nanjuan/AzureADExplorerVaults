# AzureADExplorerVaults

# Azure Key Vault Exploration & Credential-Testing — Field Notes (Markdown)

> These notes summarize the full workflow and design decisions for an **interactive terminal tool** that helps you:
>
> * log in with a **Service Principal (SP)**,
> * list **Key Vaults** and **secret names**,
> * selectively fetch **secret values**,
> * optionally attempt **Azure login** using a fetched value as a password for a chosen account,
> * and keep lightweight **audit logs** (operations + extracted-accounts).
>
> The referenced implementation lives in your `az_kv_sp_explorer.sh` script . Use these notes as your runbook/reference.

---

## 1) What this tool does (at a glance)

* **Authenticate**: Primary flow is **Service Principal** (`az login --service-principal`).
* **Discover**: Enumerate **subscriptions**, **Key Vaults**, and **secrets** (names).
* **Inspect**: Optionally fetch a **secret’s value** (explicit confirmation).
* **Test access**: Optionally attempt `az login -u <user or appId> -p <secret_value>`.
* **Audit**:

  * `script.log` — operational events & errors (no secret values by default).
  * `readPass.log` — usernames marked whenever a password is **extracted/used**.

---

## 2) Prerequisites

* **Azure CLI** (`az`) installed and on `PATH`.
* **Permissions**:

  * The Service Principal must have sufficient rights (e.g., **Key Vault Secrets User**/**Reader** or custom role) to list and read secrets in target vaults.
  * Subscription listing requires appropriate tenant permissions.
* **Optional**: `jq` for nicer selection lists (the script gracefully falls back if unavailable).
* **Secure host** to run the tool (workstation or jump box you control).

---

## 3) Security posture & guardrails

* **No secret values go to `readPass.log`.** That file only records the **username** and context when a password was extracted/used.
* **By default, secret values are *not* written to `script.log`.** Values are only displayed on-screen after explicit confirmation. (You can enable value logging with an env flag in the script if you ever need to—but it’s discouraged.)
* **Attempting `az login -u ... -p ...` can fail** for users protected by **MFA**/**Conditional Access**. That’s expected; the tool logs failure cleanly.
* **Lock down logs**:

  ```bash
  chmod 600 script.log readPass.log
  ```
* Treat any viewed/used secrets as **compromised** and **rotate** or **expire** them promptly.
* Operate under your organization’s **legal/ethical** policies; this tool is for authorized testing and IR workflows.

---

## 4) Your manual flow — mapped 1:1

**Manual commands you use:**

```bash
# 1) Login as a service principal
az login --service-principal --username "<appId>" --password "<password>" --tenant "<tenantId>"

# 2) List secret names in a vault
az keyvault secret list --vault-name "<vault>" --query "[].name" -o tsv

# 3) Fetch a secret value
az keyvault secret show --vault-name "<vault>" --name "<secretName>" --query "value" -o tsv
```

**Script behavior (reference)**:

* Prompts for SP AppID, password, and tenant, then runs the same `az login` you use.
* Lets you pick a subscription (optional).
* Lists vaults → pick a vault.
* Lists secret **names** (`--query "[].name" -o tsv`) → pick a secret.
* Options per secret:

  1. show **metadata only**,
  2. **fetch value** (confirm first; shows on-screen),
  3. **fetch value and attempt login** as another account (`az login -u <user> -p <secret_value>`).
* When a password is extracted/used, the **username is written** to `readPass.log`.

---

## 5) Interactive terminal UX (menu map)

**Main Menu**

1. **SP Login** (service-principal)
2. **Choose subscription** (optional)
3. **List vaults & inspect secrets**
4. **Show logs** (tail)
5. **Exit**

**Per-vault → Secret selection**

* Choose a secret by number, or fetch **all values** (dangerous—requires explicit confirmation).

**Per-secret → Actions**

1. **Metadata only** (no value)
2. **Fetch VALUE** (prints on-screen; optional mark to `readPass.log`)
3. **Fetch VALUE + attempt login** (prompts for target username/UPN/appId; on success, mark username in `readPass.log`)
4. Back

---

## 6) Logging model

* `script.log` (basic operational log)

  * Starts/stops, login attempts, vault/secret selections, errors.
  * **Default**: does **not** include secret values.
  * Can be configured to include values (not recommended).
* `readPass.log` (rotation/remediation list)

  * Appends: timestamp, **username**, source vault/secret.
  * Purpose: Post-ops follow-up to **change credentials** for any account whose password was extracted/used.

**Example `readPass.log` entry:**

```
2025-10-23 12:34:56 - jdoe@contoso.com - password_extracted_from:db-admin-pass - vault:kv-prod
```

---

## 7) Permissions & role tips

* To **list** vaults: subscription-level Reader or equivalent.
* To **read secrets**: on each vault, grant SP role like **Key Vault Secrets User** or an access policy (if using **Vault access policies** rather than **Azure RBAC**).
* In environments with **RBAC for Key Vault**, ensure the SP is assigned a role at the **vault scope**.
* Cross-subscription usage: set the active subscription before vault enumeration.

---

## 8) Troubleshooting checklist

* **Login fails (SP)**: verify AppID, secret, and tenant; confirm SP not disabled; confirm correct tenant.
* **Cannot list vaults**: check subscription context and SP permissions.
* **Cannot list secrets**: confirm RBAC or access policies are set for the SP on the vault.
* **Cannot fetch value**: secret may be disabled or you lack `secrets/get` permission.
* **Login as user with secret value fails**: likely MFA/Conditional Access; try a **service principal** target or use device login for humans.

---

## 9) Safe operating procedure (SOP)

**Before**

* Confirm written authorization and scope.
* Ensure SP scopes/roles are correct and minimal.
* Set a secure working directory and restrict log file permissions.

**During**

* Prefer viewing **metadata**; fetch values **only as needed**.
* If you fetch a value and use it for login, **mark the username** (auto via `readPass.log`).
* Avoid bulk “fetch all values” unless explicitly approved.

**After**

* **Rotate** any credentials that were viewed/used.
* Archive or securely destroy logs per policy.
* Create a short **remediation ticket list** from `readPass.log`.

---

## 10) Extensibility & future enhancements

* **Automation mode** (CLI flags/ENV): supply SP creds, vault, secret, and target user non-interactively for pipelines.
* **CSV reporting**: export vault → secret name inventory (no values) for audits.
* **PowerShell port**: parity for Windows-native environments.
* **Notifications**: send `readPass.log` entries to ticketing/Slack for follow-up.
* **Redaction**: hard-block value printing entirely unless a `--show-values` flag is passed.
* **Rate limits & backoff**: add retry wrappers around `az` calls.

---

## 11) Reference command snippets (for quick use)

```bash
# Login (Service Principal)
az login --service-principal \
  --username "<appId>" \
  --password "<password>" \
  --tenant   "<tenantId>"

# Set subscription (optional)
az account set --subscription "<subscriptionId>"

# List Key Vaults in current subscription
az keyvault list -o table

# List secret names in a chosen vault
az keyvault secret list --vault-name "<vaultName>" --query "[].name" -o tsv

# Get a specific secret's value
az keyvault secret show --vault-name "<vaultName>" --name "<secretName>" --query "value" -o tsv

# Try logging in as another principal using a fetched value as password
az login -u "<username-or-appId>" -p "<fetched_secret_value>"
```

> **Use the script as your interactive wrapper.** It coordinates these commands, handles selection menus, asks for confirmations, and writes logs consistently.

---

## 12) Operational caveats

* **MFA / CA** blocks password-only logins for many human accounts (expected).
* **Secret names** may not map 1:1 to the **account usernames**; the script prompts you to **associate** the username when you know it (e.g., from Azure Portal).
* **Bulk fetch** is powerful and risky; keep it disabled unless you explicitly confirm and have approval.

---

## 13) What to do with `readPass.log`

* Treat it as your **remediation queue**:

  * Change passwords / rotate secrets for every username listed.
  * Document rotations in your ticketing system.
  * Close out entries once rotated and verified.

---

### Final note

Keep using the **Service Principal-first** flow you established. The script (referenced above) mirrors your manual process, adds interactivity and safeguards, and leaves a clean paper trail for remediation. If you want a **no-value-logging hard mode**, or a **CSV audit** output, those are straightforward additions.
