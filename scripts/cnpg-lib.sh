#!/usr/bin/env bash
# shellcheck shell=bash
# Shared functions for CNPG restore scripts.
# Source this file — do not execute it directly.
#
# Expects caller to set before sourcing:
#   NAMESPACE    — Kubernetes namespace (e.g., "cnpg-cluster")
#   CLUSTER_NAME — CNPG cluster name (e.g., "cnpg-cluster")
#   CHART_PATH   — path to the Helm chart (e.g., "cluster/apps/cnpg-cluster")

cnpg_get_db_name() {
  yq '.initdb.database' "$CHART_PATH/values.yaml"
}

# cnpg_preflight [pitr_target]
# Validates backups exist and PITR target is within recovery window.
# Sets globals: BACKUP_COUNT, LATEST_BACKUP, FIRST_RECOVERABLE
# Exits 1 on fatal errors (no backups, PITR out of range).
cnpg_preflight() {
  local pitr_target="${1:-}"

  echo "Running pre-flight checks..."

  COMPLETED_BACKUPS=$(kubectl get backups.postgresql.cnpg.io -n "$NAMESPACE" \
    -o jsonpath='{.items[?(@.status.phase=="completed")].metadata.name}')
  if [ -z "$COMPLETED_BACKUPS" ]; then
    echo "ERROR: No completed backups found. Cannot restore."
    exit 1
  fi
  BACKUP_COUNT=$(echo "$COMPLETED_BACKUPS" | wc -w | tr -d ' ')
  LATEST_BACKUP=$(echo "$COMPLETED_BACKUPS" | tr ' ' '\n' | tail -1)
  echo "  Backups: $BACKUP_COUNT completed"
  echo "  Latest: $LATEST_BACKUP"

  local cluster_phase
  cluster_phase=$(kubectl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
  if [ "$cluster_phase" != "Cluster in healthy state" ]; then
    echo "  WARNING: Cluster is not healthy (phase: $cluster_phase)"
  fi

  FIRST_RECOVERABLE=$(kubectl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.firstRecoverabilityPoint}' 2>/dev/null || echo "")
  if [ -n "$FIRST_RECOVERABLE" ]; then
    echo "  Recovery window: $FIRST_RECOVERABLE → now"
  else
    echo "  WARNING: No recovery window information. PITR may not work."
  fi

  if [ -n "$pitr_target" ]; then
    echo "  PITR target: $pitr_target"
    if [ -n "$FIRST_RECOVERABLE" ] && [[ "$pitr_target" < "$FIRST_RECOVERABLE" ]]; then
      echo "ERROR: PITR target ($pitr_target) is before first recoverability point ($FIRST_RECOVERABLE)."
      exit 1
    fi
  fi
}

# cnpg_generate_recovery_manifest [pitr_target]
# Outputs base recovery Cluster YAML to stdout.
# Caller can pipe through additional yq transforms.
# Exits 1 if helm template or yq fails.
cnpg_generate_recovery_manifest() {
  local pitr_target="${1:-}"

  local yq_expr='select(.kind == "Cluster")
    | .spec.bootstrap = {"recovery": {"source": "cnpg-cluster-backup"}}
    | .spec.externalClusters = [{"name": "cnpg-cluster-backup", "plugin": {"name": "barman-cloud.cloudnative-pg.io", "parameters": {"barmanObjectName": "cnpg-cluster-backup", "serverName": "cnpg-cluster"}}}]
    | del(.spec.plugins)'

  if [ -n "$pitr_target" ]; then
    yq_expr="$yq_expr | .spec.bootstrap.recovery.recoveryTarget.targetTime = \"$pitr_target\""
  fi

  local manifest
  manifest=$(helm template cnpg-cluster "$CHART_PATH" --namespace "$NAMESPACE" | yq "$yq_expr")
  if [ -z "$manifest" ]; then
    echo "ERROR: Failed to generate recovery manifest." >&2
    exit 1
  fi
  echo "$manifest"
}

# cnpg_wait_for_healthy cluster_name timeout_seconds
# Polls until the cluster has at least one Running pod and reports healthy.
# Exits 1 on timeout.
cnpg_wait_for_healthy() {
  local cluster="$1"
  local timeout="$2"
  local start_wait
  start_wait=$(date +%s)

  until [ "$(kubectl get pods -n "$NAMESPACE" -l "cnpg.io/cluster=$cluster" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')" -ge "1" ]; do
    if [ $(($(date +%s) - start_wait)) -ge "$timeout" ]; then
      echo "ERROR: Timed out waiting for pods."
      echo "Debug: kubectl get pods -n $NAMESPACE -l cnpg.io/cluster=$cluster"
      exit 1
    fi
    sleep 5
  done
  echo "At least one pod is running."

  until [ "$(kubectl get cluster "$cluster" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Cluster in healthy state" ]; do
    if [ $(($(date +%s) - start_wait)) -ge "$timeout" ]; then
      echo "ERROR: Timed out waiting for healthy state."
      echo "Debug: kubectl cnpg status $cluster -n $NAMESPACE"
      exit 1
    fi
    sleep 5
  done
  echo "Cluster is healthy."
}

# cnpg_validate_db cluster_name db_name [timeout_seconds]
# Retries psql connectivity check until success or timeout (default 30s).
# Exits 1 on timeout.
cnpg_validate_db() {
  local cluster="$1"
  local db="$2"
  local timeout="${3:-60}"
  local start_wait
  start_wait=$(date +%s)

  local output
  until output=$(kubectl cnpg psql "$cluster" -n "$NAMESPACE" -- -d "$db" -c "SELECT 1" 2>&1) || echo "$output" | grep -q "(1 row)"; do
    if [ $(($(date +%s) - start_wait)) -ge "$timeout" ]; then
      echo ""
      echo "Restore test FAILED: Could not connect to database '$db'."
      echo "Last error: $output"
      exit 1
    fi
    sleep 2
  done
  echo "Database '$db' is accessible."
}
