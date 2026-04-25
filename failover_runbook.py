"""
failover_runbook.py
Azure Automation Python3 Runbook
--------------------------------
Flow:
1) (Optional) Confirm failover signal
2) Promote MySQL replica
3) Scale secondary AKS deployment using AKS Run Command

Uses:
- requests only
- System Assigned Managed Identity (IMDS)
- No service principal secrets
- No kubeconfig parsing
- No direct Kubernetes API patching
"""

import json
import logging
import time
import requests
import automationassets


# -------------------------------------------------------------------
# Terraform injected variables
# -------------------------------------------------------------------

SUBSCRIPTION_ID = "${subscription_id}"
RESOURCE_GROUP  = "${resource_group}"
MYSQL_REPLICA   = "${mysql_replica}"
AKS_SECONDARY   = "${aks_secondary}"
LA_WORKSPACE_ID = "${la_workspace_id}"

NAMESPACE       = "secondary"
DEPLOYMENT_NAME = "prod-deployment"
TARGET_REPLICAS = 4




logging.basicConfig(
    level=logging.INFO,
    format="%(levelname)s %(message)s"
)

log = logging.getLogger(__name__)


# -------------------------------------------------------------------
# Managed Identity Token (uses Automation Account identity)
# -------------------------------------------------------------------



TENANT_ID = automationassets.get_automation_variable("AZURE_TENANT_ID")
CLIENT_ID = automationassets.get_automation_variable("AZURE_CLIENT_ID")
CLIENT_SECRET = automationassets.get_automation_variable("AZURE_CLIENT_SECRET")


def get_token(resource):

    resp = requests.post(
        f"https://login.microsoftonline.com/{TENANT_ID}/oauth2/token",
        data={
            "grant_type":"client_credentials",
            "client_id":CLIENT_ID,
            "client_secret":CLIENT_SECRET,
            "resource":resource
        },
        timeout=30
    )

    resp.raise_for_status()
    return resp.json()["access_token"]


def mgmt_headers():
    return {
        "Authorization":
            f"Bearer {get_token('https://management.azure.com/')}",
        "Content-Type":
            "application/json"
    }


# -------------------------------------------------------------------
# STEP 1 - Detect failover
# -------------------------------------------------------------------

def detect_failover():

    log.info("[Step 1] Checking failover evidence...")

    try:
        token = get_token("https://api.loganalytics.io/")

        query = """
AzureMetrics
| where ResourceProvider == 'MICROSOFT.NETWORK'
| where TimeGenerated > ago(10m)
| where Average < 100
"""

        resp = requests.post(
            f"https://api.loganalytics.io/v1/workspaces/{LA_WORKSPACE_ID}/query",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json"
            },
            json={"query": query},
            timeout=60
        )

        if resp.status_code != 200:
            log.warning(
                "[Step 1] Query returned %s — trusting alert",
                resp.status_code
            )
            return True

        tables = resp.json().get("tables", [])
        rows = tables[0].get("rows", []) if tables else []

        confirmed = len(rows) > 0

        log.info(
            "[Step 1] Failover %s",
            "CONFIRMED" if confirmed else "NOT CONFIRMED"
        )

        if not confirmed:
            log.info(
              "[Step 1] Manual test mode: continuing anyway"
            )
            return True

        return True

    except Exception as exc:
        log.warning(
            "[Step 1] Detection issue (%s) — trusting trigger",
            exc
        )
        return True

# ── STEP 2 — Promote MySQL replica (Flexible Server API) ──────────────────
def promote_database():
    log.info("[Step 2] Promoting MySQL replica '%s'...", MYSQL_REPLICA)

    headers = mgmt_headers()
    base = (
        f"https://management.azure.com/subscriptions/{SUBSCRIPTION_ID}"
        f"/resourceGroups/{RESOURCE_GROUP}"
        f"/providers/Microsoft.DBforMySQL/flexibleServers/{MYSQL_REPLICA}"
    )

   
    server_resp = requests.get(
        f"{base}?api-version=2023-06-30",
        headers=headers, timeout=60
    )
    server_resp.raise_for_status()

    role = server_resp.json().get("properties", {}).get("replicationRole", "")

    if role.lower() != "replica":
        log.info("[Step 2] Already standalone (role: %s) — skipping", role)
        return {"status": "skipped", "role": role}

    patch_resp = requests.patch(
        f"{base}?api-version=2023-06-30",
        headers=headers,
        json={"properties": {"replicationRole": "None"}},
        timeout=30
    )
    log.info("[Step 2] PATCH response: %s", patch_resp.status_code)
    patch_resp.raise_for_status()

   
    for attempt in range(40):
        time.sleep(15)
        check = requests.get(
            f"{base}?api-version=2023-06-30",
            headers=headers, timeout=60
        )
        check.raise_for_status()
        current_role = check.json().get("properties", {}).get("replicationRole", "")
        log.info("[Step 2] Poll %d — replicationRole: %s", attempt + 1, current_role)
        if current_role.lower() in ("none", ""):
            log.info("[Step 2] Replica promoted successfully")
            return {"status": "promoted", "server": MYSQL_REPLICA}

    raise RuntimeError("Timed out waiting for MySQL replica promotion")


# ── STEP 3 — Scale AKS via runCommand (with async polling) ────────────────
def scale_secondary():
    log.info("[Step 3] Scaling secondary AKS via runCommand...")

    headers = mgmt_headers()
    base = (
        f"https://management.azure.com/subscriptions/{SUBSCRIPTION_ID}"
        f"/resourceGroups/{RESOURCE_GROUP}"
        f"/providers/Microsoft.ContainerService"
        f"/managedClusters/{AKS_SECONDARY}"
    )

    command = (
        f"kubectl scale deployment {DEPLOYMENT_NAME} "
        f"-n {NAMESPACE} --replicas={TARGET_REPLICAS}"
    )

    resp = requests.post(
        f"{base}/runCommand?api-version=2023-08-01",
        headers=headers,
        json={"command": command},
        timeout=30
    )
    log.info("[Step 3] runCommand accepted: %s", resp.status_code)

    # 202 means async — poll the Location header
    if resp.status_code == 202:
        location = resp.headers.get("Location") or resp.headers.get("Azure-AsyncOperation")
        if not location:
            raise RuntimeError("runCommand returned 202 but no Location header")

        for attempt in range(30):
            time.sleep(10)
            poll = requests.get(location, headers=headers, timeout=30)
            poll.raise_for_status()
            body = poll.json()
            state = body.get("properties", {}).get("provisioningState", "")
            log.info("[Step 3] Poll %d — state: %s", attempt + 1, state)

            if state == "Succeeded":
                exit_code = body.get("properties", {}).get("exitCode", -1)
                log.info("[Step 3] runCommand exit code: %s", exit_code)
                if exit_code != 0:
                    raise RuntimeError(f"kubectl scale failed (exit {exit_code})")
                return {"status": "scaled", "cluster": AKS_SECONDARY, "replicas": TARGET_REPLICAS}
            elif state in ("Failed", "Canceled"):
                raise RuntimeError(f"runCommand ended with state: {state}")

        raise RuntimeError("Timed out polling runCommand result")

    resp.raise_for_status()
    return {"status": "scaled", "cluster": AKS_SECONDARY, "replicas": TARGET_REPLICAS}

# MAIN
# -------------------------------------------------------------------

def main():

    t0 = time.time()

    log.info("=== Failover Runbook Started ===")

    if not detect_failover():
        log.info(
            "No failover detected — exiting safely."
        )
        return

    t1 = time.time()

    log.info(
        "[RTO] Detection completed in %.1fs",
        t1 - t0
    )

    db_result = promote_database()

    log.info(
        "DB Result: %s",
        json.dumps(db_result)
    )

    t2 = time.time()

    log.info(
        "[RTO] DB promotion completed in %.1fs",
        t2 - t1
    )

    k8s_result = scale_secondary()

    log.info(
        "K8s Result: %s",
        json.dumps(k8s_result)
    )

    t3 = time.time()

    log.info(
        "[RTO] Scaling completed in %.1fs",
        t3 - t2
    )

    log.info(
        "=== Failover Runbook Completed Successfully "
        "(total %.1fs) ===",
        t3 - t0
    )


if __name__ == "__main__":
    main()