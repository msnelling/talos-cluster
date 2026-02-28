#!/usr/bin/env bash
# shellcheck shell=bash
# One-off script to migrate a PostgreSQL database from TrueNAS to CNPG.
# Usage: ./scripts/cnpg-migrate.sh <database> [<owner>]
# Owner defaults to database name. Delete this script after migration.
set -euo pipefail

DB_NAME="${1:?Usage: $0 <database> [<owner>]}"
OWNER="${2:-$DB_NAME}"
NAMESPACE="cnpg-cluster"
CLUSTER_NAME="cnpg-cluster"
VARS_FILE="$(cd "$(dirname "$0")/.." && pwd)/vars.yaml"

# --- Read config from vars.yaml ---
if [ ! -f "$VARS_FILE" ]; then
  echo "ERROR: $VARS_FILE not found."
  exit 1
fi

TRUENAS_HOST=$(yq '.truenas_postgres_host' "$VARS_FILE")

if [ -z "$TRUENAS_HOST" ] || [ "$TRUENAS_HOST" = "null" ]; then
  echo "ERROR: truenas_postgres_host not set in vars.yaml"
  exit 1
fi

# --- Find CNPG primary pod ---
PRIMARY_POD=$(kubectl get pods -n "$NAMESPACE" \
  -l "cnpg.io/cluster=$CLUSTER_NAME,role=primary" \
  -o jsonpath='{.items[0].metadata.name}')
if [ -z "$PRIMARY_POD" ]; then
  echo "ERROR: Could not find CNPG primary pod."
  exit 1
fi
echo "CNPG primary pod: $PRIMARY_POD"

# --- Preflight: verify TrueNAS connectivity ---
echo ""
echo "Checking TrueNAS connectivity ($TRUENAS_HOST:5432)..."
if ! pg_isready -h "$TRUENAS_HOST" -p 5432 -U postgres -q -t 5; then
  echo "ERROR: Cannot reach PostgreSQL on $TRUENAS_HOST:5432"
  exit 1
fi
echo "TrueNAS PostgreSQL is reachable."

# Suppress password prompts for TrueNAS (trust auth)
export PGPASSWORD=""

# --- Import role with encrypted password from TrueNAS ---
echo ""
echo "Importing role '$OWNER' from TrueNAS..."
ENCRYPTED_PASSWORD=$(psql -h "$TRUENAS_HOST" -p 5432 -U postgres -tAc \
  "SELECT rolpassword FROM pg_authid WHERE rolname = '${OWNER}'")
if [ -z "$ENCRYPTED_PASSWORD" ]; then
  echo "ERROR: Role '$OWNER' not found on TrueNAS."
  exit 1
fi
kubectl exec -i "$PRIMARY_POD" -n "$NAMESPACE" -c postgres -- \
  psql -U postgres -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  CREATE ROLE ${OWNER} WITH LOGIN PASSWORD '${ENCRYPTED_PASSWORD}';
  RAISE NOTICE 'Role created: ${OWNER}';
EXCEPTION WHEN duplicate_object THEN
  ALTER ROLE ${OWNER} WITH PASSWORD '${ENCRYPTED_PASSWORD}';
  RAISE NOTICE 'Role already exists, password updated: ${OWNER}';
END
\$\$;
SQL

# --- Create database (if not exists) ---
echo ""
echo "Creating database '$DB_NAME' owned by '$OWNER'..."
DB_EXISTS=$(kubectl exec -i "$PRIMARY_POD" -n "$NAMESPACE" -c postgres -- \
  psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'")
if [ "$DB_EXISTS" = "1" ]; then
  echo "Database '$DB_NAME' already exists, skipping creation."
else
  kubectl exec -i "$PRIMARY_POD" -n "$NAMESPACE" -c postgres -- \
    psql -U postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${DB_NAME} OWNER ${OWNER}"
  echo "Database created."
fi

# --- Count source tables ---
echo ""
SOURCE_TABLES=$(psql -h "$TRUENAS_HOST" -p 5432 -U postgres -d "$DB_NAME" -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'")
echo "Source tables (public schema): $SOURCE_TABLES"

# --- Dump and restore ---
echo ""
echo "Migrating '$DB_NAME' from TrueNAS → CNPG..."
pg_dump -h "$TRUENAS_HOST" -p 5432 -U postgres --no-acl --no-owner "$DB_NAME" \
  | kubectl exec -i "$PRIMARY_POD" -n "$NAMESPACE" -c postgres -- \
    psql -U postgres -d "$DB_NAME" --single-transaction -v ON_ERROR_STOP=1

# --- Fix ownership (tables, sequences, views in public schema) ---
echo ""
echo "Reassigning object ownership to '$OWNER'..."
kubectl exec -i "$PRIMARY_POD" -n "$NAMESPACE" -c postgres -- \
  psql -U postgres -d "$DB_NAME" -v ON_ERROR_STOP=1 <<SQL
DO \$\$
DECLARE
  obj record;
BEGIN
  FOR obj IN SELECT tablename AS name, 'TABLE' AS type FROM pg_tables WHERE schemaname = 'public'
    UNION ALL SELECT sequencename, 'SEQUENCE' FROM pg_sequences WHERE schemaname = 'public'
    UNION ALL SELECT viewname, 'VIEW' FROM pg_views WHERE schemaname = 'public'
  LOOP
    EXECUTE format('ALTER %s public.%I OWNER TO %I', obj.type, obj.name, '${OWNER}');
  END LOOP;
END
\$\$;
SQL

# --- Verify table count ---
echo ""
TARGET_TABLES=$(kubectl exec -i "$PRIMARY_POD" -n "$NAMESPACE" -c postgres -- \
  psql -U postgres -d "$DB_NAME" -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'")
echo "Target tables (public schema): $TARGET_TABLES"

if [ "$SOURCE_TABLES" = "$TARGET_TABLES" ]; then
  echo "Table count matches ($SOURCE_TABLES). Migration successful."
else
  echo "WARNING: Table count mismatch! Source=$SOURCE_TABLES, Target=$TARGET_TABLES"
  echo "Investigate manually before proceeding."
  exit 1
fi
