#!/usr/bin/env bash
###############################################################################
# failover_test.sh — Simulate primary-region failure & measure RTO / RPO
#
# Usage:  chmod +x failover_test.sh && bash failover_test.sh
#

###############################################################################
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
RESOURCE_GROUP="mysql-multiregion-rg"
TM_PROFILE="tm-wordpress-mahmoud"
PRIMARY_ENDPOINT_NAME="primary-endpoint"
SECONDARY_ENDPOINT_NAME="secondary-endpoint"

PRIMARY_CLUSTER="production-cluster"
SECONDARY_CLUSTER="secondary-cluster"
PRIMARY_NAMESPACE="primary"
SECONDARY_NAMESPACE="secondary"
DEPLOYMENT_NAME="prod-deployment"

MYSQL_PRIMARY="mysql-primary-mahmoud123"
MYSQL_REPLICA="mysql-secondary-mahmoud123"

SECONDARY_IP="20.200.48.130"
PRIMARY_IP="4.246.11.226"

AUTOMATION_ACCOUNT="aa-failover-wordpress"
RUNBOOK_NAME="failover-runbook"

POLL_INTERVAL=5          
MAX_WAIT=600             
ALERT_WAIT=180           


RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' 

# ── Helper functions ──────────────────────────────────────────────────────────
log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
fail() { echo -e "${RED}[✗]${NC} $*"; }
hr()   { echo -e "${BOLD}$(printf '═%.0s' {1..70})${NC}"; }

# ── Step 0: Pre-flight checks ────────────────────────────────────────────────
preflight() {
    hr
    echo -e "${BOLD}  FAILOVER TEST — Pre-flight Checks${NC}"
    hr

    # Azure CLI logged in?
    log "Checking Azure CLI login..."
    if ! az account show &>/dev/null; then
        fail "Not logged into Azure CLI. Run: az login"
        exit 1
    fi
    ok "Azure CLI authenticated ($(az account show --query name -o tsv))"

    # Primary AKS reachable?
    log "Checking primary AKS cluster..."
    if az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$PRIMARY_CLUSTER" --overwrite-existing --admin &>/dev/null; then
        PRIMARY_REPLICAS=$(kubectl --context "${PRIMARY_CLUSTER}-admin" get deployment "$DEPLOYMENT_NAME" -n "$PRIMARY_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "N/A")
        ok "Primary AKS reachable — $DEPLOYMENT_NAME replicas: $PRIMARY_REPLICAS"
    else
        warn "Could not get primary AKS credentials (may already be down)"
        PRIMARY_REPLICAS="N/A"
    fi

    
    log "Checking secondary AKS cluster..."
    if az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$SECONDARY_CLUSTER" --overwrite-existing --admin &>/dev/null; then
        SECONDARY_REPLICAS=$(kubectl --context "${SECONDARY_CLUSTER}-admin" get deployment "$DEPLOYMENT_NAME" -n "$SECONDARY_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "N/A")
        ok "Secondary AKS reachable — $DEPLOYMENT_NAME replicas: $SECONDARY_REPLICAS"
    else
        fail "Cannot reach secondary AKS cluster"
        exit 1
    fi

    
    log "Checking Traffic Manager profile..."
    TM_STATUS=$(az network traffic-manager endpoint show \
        --resource-group "$RESOURCE_GROUP" \
        --profile-name "$TM_PROFILE" \
        --name "$PRIMARY_ENDPOINT_NAME" \
        --type externalEndpoints \
        --query "endpointStatus" -o tsv 2>/dev/null || echo "Unknown")
    ok "Primary TM endpoint status: $TM_STATUS"

    
    log "Checking MySQL primary..."
    MYSQL_PRIMARY_STATUS=$(az mysql flexible-server show \
        --name "$MYSQL_PRIMARY" \
        --resource-group "$RESOURCE_GROUP" \
        --query "state" -o tsv 2>/dev/null || echo "Unknown")
    ok "MySQL primary status: $MYSQL_PRIMARY_STATUS"

    log "Checking MySQL replica..."
    MYSQL_REPLICA_ROLE=$(az mysql flexible-server show \
        --name "$MYSQL_REPLICA" \
        --resource-group "$RESOURCE_GROUP" \
        --query "replicationRole" -o tsv 2>/dev/null || echo "Unknown")
    ok "MySQL replica role: $MYSQL_REPLICA_ROLE"

    echo ""
}

# ── Step 1: Measure RPO baseline ─────────────────────────────────────────────
measure_rpo() {
    hr
    echo -e "${BOLD}  STEP 1 — Measuring RPO (Replication Lag)${NC}"
    hr

    log "Querying MySQL replica replication status..."

    # Get replication lag via Azure metrics (Seconds_Behind_Source)
    RPO_SECONDS=$(az monitor metrics list \
        --resource "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.DBforMySQL/flexibleServers/$MYSQL_REPLICA" \
        --metric "seconds_behind_master" \
        --interval PT1M \
        --aggregation Average \
        --query "value[0].timeseries[0].data[-1].average" \
        -o tsv 2>/dev/null || echo "N/A")

    if [[ "$RPO_SECONDS" == "N/A" || -z "$RPO_SECONDS" ]]; then
        warn "Could not retrieve replication lag from Azure Monitor"
        warn "RPO will be estimated based on async replication (typically 0-2 seconds)"
        RPO_SECONDS="<2 (estimated)"
    else
        ok "Replication lag (Seconds_Behind_Source): ${RPO_SECONDS}s"
    fi

    echo ""
    echo -e "  ${BOLD}RPO = ${CYAN}${RPO_SECONDS}s${NC} ${BOLD}of potential data loss${NC}"
    echo ""
}

# ── Step 2: Simulate primary failure ─────────────────────────────────────────
simulate_failure() {
    hr
    echo -e "${BOLD}  STEP 2 — Simulating Primary Region Failure${NC}"
    hr

    # Start RTO timer
    T0=$(date +%s)
    log "RTO timer started at $(date -d @"$T0" '+%Y-%m-%d %H:%M:%S')"

    
    log "Disabling primary Traffic Manager endpoint..."
    az network traffic-manager endpoint update \
        --resource-group "$RESOURCE_GROUP" \
        --profile-name "$TM_PROFILE" \
        --name "$PRIMARY_ENDPOINT_NAME" \
        --type externalEndpoints \
        --endpoint-status Disabled \
        -o none
    ok "Primary TM endpoint DISABLED"

    log "Scaling primary AKS deployment to 0 replicas..."
    kubectl --context "${PRIMARY_CLUSTER}-admin" scale deployment "$DEPLOYMENT_NAME" \
        -n "$PRIMARY_NAMESPACE" --replicas=0 2>/dev/null || warn "Could not scale primary (may be expected)"
    ok "Primary deployment scaled to 0"

    echo ""
    echo -e "  ${RED}╔══════════════════════════════════════════╗${NC}"
    echo -e "  ${RED}║   PRIMARY REGION IS NOW SIMULATED DOWN   ║${NC}"
    echo -e "  ${RED}╚══════════════════════════════════════════╝${NC}"
    echo ""
}

# ── Step 3: Trigger failover  ──────────────────────
trigger_failover() {
    hr
    echo -e "${BOLD}  STEP 3 — Triggering Failover Runbook${NC}"
    hr

    echo ""
    echo "  Choose trigger method:"
    echo "    1) Manual — start runbook directly via Azure CLI (faster for testing)"
    echo "    2) Auto   — wait for Traffic Manager alert pipeline (~2-3 min)"
    echo ""
    read -rp "  Enter option [1/2]: " trigger_choice

    case "$trigger_choice" in
        1)
            log "Manually triggering failover runbook..."
            JOB_ID=$(az automation runbook start \
                --automation-account-name "$AUTOMATION_ACCOUNT" \
                --resource-group "$RESOURCE_GROUP" \
                --name "$RUNBOOK_NAME" \
                --query "jobId" -o tsv 2>/dev/null || echo "")
            if [[ -n "$JOB_ID" ]]; then
                ok "Runbook job started: $JOB_ID"
                log "Waiting for runbook to complete..."
                wait_for_runbook "$JOB_ID"
            else
                warn "Could not start runbook — will monitor secondary directly"
            fi
            wait_for_mysql_promotion       
            restart_secondary_deployment
            
            ;;
        2)
            log "Waiting for alert pipeline to fire (up to ${ALERT_WAIT}s)..."
            log "Traffic Manager checks every 30s, tolerates 3 failures = ~90s detection"
            sleep "$ALERT_WAIT"
            ok "Alert wait period complete — checking secondary status"
            ;;
        *)
            warn "Invalid choice, defaulting to manual trigger"
            trigger_failover
            return
            ;;
    esac
    echo ""
}
wait_for_mysql_promotion() {
    hr
    echo -e "${BOLD}  STEP 3b — Waiting for MySQL Promotion${NC}"
    hr

    local elapsed=0
    log "Polling MySQL replica role until promoted (role = None)..."

    while [[ $elapsed -lt $MAX_WAIT ]]; do
        ROLE=$(az mysql flexible-server show \
            --name "$MYSQL_REPLICA" \
            --resource-group "$RESOURCE_GROUP" \
            --query "replicationRole" -o tsv 2>/dev/null || echo "Unknown")

        log "  MySQL role: $ROLE (${elapsed}s elapsed)"

        if [[ "$ROLE" == "None" || "$ROLE" == "none" ]]; then
            ok "MySQL replica promoted to standalone"
            return 0
        fi

        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done

    fail "Timeout: MySQL replica never promoted within ${MAX_WAIT}s"
    exit 1
}

# ── Wait for runbook job to complete ──────────────────────────────────────────
wait_for_runbook() {
    local job_id=$1
    local elapsed=0

    while [[ $elapsed -lt $MAX_WAIT ]]; do
        JOB_STATUS=$(az automation job show \
            --automation-account-name "$AUTOMATION_ACCOUNT" \
            --resource-group "$RESOURCE_GROUP" \
            --name "$job_id" \
            --query "status" -o tsv 2>/dev/null || echo "Unknown")

        case "$JOB_STATUS" in
            Completed)
                ok "Runbook job completed successfully"
                return 0
                ;;
            Failed|Stopped|Suspended)
                fail "Runbook job ended with status: $JOB_STATUS"
                return 1
                ;;
            *)
                log "  Job status: $JOB_STATUS (${elapsed}s elapsed)..."
                sleep "$POLL_INTERVAL"
                elapsed=$((elapsed + POLL_INTERVAL))
                ;;
        esac
    done

    warn "Timeout waiting for runbook (${MAX_WAIT}s)"
    return 1
}

restart_secondary_deployment() {
    log "Restarting secondary deployment to pick up promoted MySQL..."
    kubectl --context "${SECONDARY_CLUSTER}-admin" \
        rollout restart deployment/"$DEPLOYMENT_NAME" \
        -n "$SECONDARY_NAMESPACE"
    ok "Rollout restart triggered"
}

update_wordpress_url() {
    log "Updating WordPress siteurl and home to secondary IP..."
    kubectl --context "${SECONDARY_CLUSTER}-admin" exec -n "$SECONDARY_NAMESPACE" \
        deployment/"$DEPLOYMENT_NAME" -- php -r "
require '/var/www/html/wp-load.php';
update_option('siteurl', 'http://${SECONDARY_IP}');
update_option('home', 'http://${SECONDARY_IP}');
echo 'Done';
"
    ok "WordPress URL updated to http://${SECONDARY_IP}"
}
wait_for_secondary_ready() {
    hr
    echo -e "${BOLD}  STEP 4 — Waiting For Secondary Scale-Up${NC}"
    hr

    local elapsed=0

    while [[ $elapsed -lt $MAX_WAIT ]]; do

        REPLICAS=$(kubectl --context "${SECONDARY_CLUSTER}-admin" \
            get deployment "$DEPLOYMENT_NAME" \
            -n "$SECONDARY_NAMESPACE" \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

        REPLICAS=${REPLICAS:-0}

        log "Ready replicas: $REPLICAS / 4"

        if [[ "$REPLICAS" -ge 4 ]]; then
            ok "Secondary scaled successfully"

            log "Waiting for rollout completion..."
            kubectl --context "${SECONDARY_CLUSTER}-admin" \
              rollout status deployment/"$DEPLOYMENT_NAME" \
              -n "$SECONDARY_NAMESPACE" \
              --timeout=300s

            ok "Secondary deployment healthy"

            log "Checking service endpoints..."
            kubectl --context "${SECONDARY_CLUSTER}-admin" \
                get endpoints prod-service \
                -n "$SECONDARY_NAMESPACE"

            return 0
        fi

        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done

    fail "Secondary never reached 4 replicas"
    exit 1
}

poll_secondary() {
    hr
    echo -e "${BOLD}  STEP 4 — Polling Secondary Endpoint${NC}"
    hr

    log "Polling http://${SECONDARY_IP}/ every ${POLL_INTERVAL}s (timeout ${MAX_WAIT}s)..."

    local elapsed=0
    while [[ $elapsed -lt $MAX_WAIT ]]; do
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://${SECONDARY_IP}/" 2>/dev/null || echo "000")

        if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "302" || "$HTTP_CODE" == "301" ]]; then
            T1=$(date +%s)
            RTO=$((T1 - T0))
            echo ""
            ok "Secondary is responding! (HTTP $HTTP_CODE)"
            echo ""
            echo -e "  ${BOLD}${GREEN}╔══════════════════════════════════════════╗${NC}"
            echo -e "  ${BOLD}${GREEN}║   SECONDARY REGION IS NOW SERVING        ║${NC}"
            echo -e "  ${BOLD}${GREEN}║   RTO = ${RTO} seconds                        ║${NC}"
            echo -e "  ${BOLD}${GREEN}╚══════════════════════════════════════════╝${NC}"
            echo ""
            return 0
        fi

        log "  HTTP ${HTTP_CODE} — not ready yet (${elapsed}s elapsed)"
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done

    T1=$(date +%s)
    RTO=$((T1 - T0))
    fail "Timeout: secondary did not respond within ${MAX_WAIT}s"
    return 1
}


verify_failover() {
    hr
    echo -e "${BOLD}  STEP 5 — Verifying Failover Results${NC}"
    hr

  
    log "Checking MySQL replica replication role..."
    FINAL_ROLE=$(az mysql flexible-server show \
        --name "$MYSQL_REPLICA" \
        --resource-group "$RESOURCE_GROUP" \
        --query "replicationRole" -o tsv 2>/dev/null || echo "Unknown")

    if [[ "$FINAL_ROLE" == "None" || "$FINAL_ROLE" == "none" ]]; then
        ok "MySQL replica PROMOTED to standalone (role: $FINAL_ROLE)"
        DB_PROMOTED="PASS"
    else
        warn "MySQL replica role: $FINAL_ROLE (expected: None)"
        DB_PROMOTED="FAIL"
    fi

    log "Checking secondary AKS deployment replicas..."
    FINAL_REPLICAS=$(kubectl --context "${SECONDARY_CLUSTER}-admin" get deployment "$DEPLOYMENT_NAME" \
        -n "$SECONDARY_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

    if [[ "$FINAL_REPLICAS" -ge 4 ]]; then
        ok "Secondary deployment scaled to $FINAL_REPLICAS replicas"
        AKS_SCALED="PASS"
    else
        warn "Secondary deployment replicas: $FINAL_REPLICAS (expected: >= 4)"
        AKS_SCALED="FAIL"
    fi

  
    log "Checking Traffic Manager routing..."
    SEC_TM_STATUS=$(az network traffic-manager endpoint show \
        --resource-group "$RESOURCE_GROUP" \
        --profile-name "$TM_PROFILE" \
        --name "$SECONDARY_ENDPOINT_NAME" \
        --type externalEndpoints \
        --query "endpointStatus" -o tsv 2>/dev/null || echo "Unknown")
    ok "Secondary TM endpoint status: $SEC_TM_STATUS"

    echo ""
}

# ── Step 6: Print final report ────────────────────────────────────────────────
print_report() {
    hr
    echo ""
    echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}  ║              FAILOVER TEST REPORT                        ║${NC}"
    echo -e "${BOLD}${CYAN}  ╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}${CYAN}  ║                                                          ║${NC}"
    echo -e "${BOLD}${CYAN}  ║${NC}  Test Time:       $(date '+%Y-%m-%d %H:%M:%S')                  ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}  ║${NC}                                                          ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}  ║${NC}  ${BOLD}RPO (Recovery Point Objective):${NC}                       ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}  ║${NC}    Replication Lag: ${YELLOW}${RPO_SECONDS}s${NC}                            ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}  ║${NC}    (max data loss window)                                ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}  ║${NC}                                                          ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}  ║${NC}  ${BOLD}RTO (Recovery Time Objective):${NC}                        ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}  ║${NC}    Time to recover: ${YELLOW}${RTO:-N/A}s${NC}                            ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}  ║${NC}    (primary down → secondary serving)                     ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}  ║${NC}                                                          ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}  ║${NC}  ${BOLD}Checks:${NC}                                                ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}  ║${NC}    MySQL promoted:     $(status_badge "$DB_PROMOTED")                       ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}  ║${NC}    AKS scaled (>=4):   $(status_badge "$AKS_SCALED")                       ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}  ║${NC}                                                          ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    hr
    echo ""
    warn "ROLLBACK: Don't forget to restore the primary after testing!"
    echo "  bash failover_test.sh --rollback"
    echo ""
}

status_badge() {
    if [[ "$1" == "PASS" ]]; then
        echo -e "${GREEN}PASS${NC}"
    else
        echo -e "${RED}FAIL${NC}"
    fi
}

rollback() {
    hr
    echo -e "${BOLD}  ROLLBACK — Restoring Primary Region${NC}"
    hr

    log "Re-enabling primary Traffic Manager endpoint..."
    az network traffic-manager endpoint update \
        --resource-group "$RESOURCE_GROUP" \
        --profile-name "$TM_PROFILE" \
        --name "$PRIMARY_ENDPOINT_NAME" \
        --type externalEndpoints \
        --endpoint-status Enabled \
        -o none
    ok "Primary TM endpoint re-enabled"

    # Scale primary back to 4
    log "Scaling primary AKS deployment back to 4 replicas..."
    kubectl --context "${PRIMARY_CLUSTER}-admin" scale deployment "$DEPLOYMENT_NAME" \
        -n "$PRIMARY_NAMESPACE" --replicas=4
    ok "Primary deployment scaled to 4"

    # Scale secondary back to 0
    log "Scaling secondary AKS deployment back to 0 replicas..."
    kubectl --context "${SECONDARY_CLUSTER}-admin" scale deployment "$DEPLOYMENT_NAME" \
        -n "$SECONDARY_NAMESPACE" --replicas=0
    ok "Secondary deployment scaled to 0"

    echo ""
    warn "MySQL replication must be restored manually:"
    echo "  Option A: terraform destroy + terraform apply the MySQL resources"
    echo "  Option B: az mysql flexible-server replica create \\"
    echo "            --resource-group $RESOURCE_GROUP \\"
    echo "            --name $MYSQL_REPLICA \\"
    echo "            --source-server $MYSQL_PRIMARY"
    echo ""
    ok "Rollback complete (except MySQL replication)"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BOLD}${CYAN}"
    echo "  ███████╗ █████╗ ██╗██╗      ██████╗ ██╗   ██╗███████╗██████╗ "
    echo "  ██╔════╝██╔══██╗██║██║     ██╔═══██╗██║   ██║██╔════╝██╔══██╗"
    echo "  █████╗  ███████║██║██║     ██║   ██║██║   ██║█████╗  ██████╔╝"
    echo "  ██╔══╝  ██╔══██║██║██║     ██║   ██║╚██╗ ██╔╝██╔══╝  ██╔══██╗"
    echo "  ██║     ██║  ██║██║███████╗╚██████╔╝ ╚████╔╝ ███████╗██║  ██║"
    echo "  ╚═╝     ╚═╝  ╚═╝╚═╝╚══════╝ ╚═════╝   ╚═══╝  ╚══════╝╚═╝  ╚═╝"
    echo "                      T E S T   S U I T E                          "
    echo -e "${NC}"

    preflight
    measure_rpo
    simulate_failure
    trigger_failover
    wait_for_secondary_ready
    update_wordpress_url   
    poll_secondary
    verify_failover
    print_report
}

if [[ "${1:-}" == "--rollback" ]]; then
    rollback
else
    main
fi
