#!/usr/bin/env bash
# Bootstrap Aurora/RDS for Sigeo map service (eu-south-1 lab).
#
# You connect as master with IAM auth (generate-db-auth-token).
# The app user `_renderd` uses a normal password stored in Secrets Manager
# (Lambda/ECS/osm2pgsql do not use IAM DB tokens).
#
# Usage:
#   export RDSHOST="database-2.cluster-cdeqmke44b69.eu-south-1.rds.amazonaws.com"
#   export AWS_REGION=eu-south-1
#   export RENDERD_PASSWORD='choose-a-strong-password'
#   ./aws/bootstrap-rds.sh
#
set -euo pipefail
export AWS_PAGER=""

RDSHOST="${RDSHOST:?Set RDSHOST=your-cluster-endpoint}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-south-1}}"
MASTER_USER="${MASTER_USER:-postgres}"
APP_USER="${APP_USER:-_renderd}"
APP_DB="${APP_DB:-gis}"
SECRET_NAME="${SECRET_NAME:-sigeo-map/db}"
RENDERD_PASSWORD="${RENDERD_PASSWORD:?Set RENDERD_PASSWORD for the app DB user}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOOTSTRAP_SQL="${ROOT}/db/init/aws-bootstrap.sql"

echo "== Region $REGION host $RDSHOST =="

TOKEN="$(aws rds generate-db-auth-token \
  --hostname "$RDSHOST" \
  --port 5432 \
  --username "$MASTER_USER" \
  --region "$REGION")"

export PGPASSWORD="$TOKEN"
PSQL=(psql "host=${RDSHOST}" "port=5432" "dbname=postgres" "user=${MASTER_USER}" "sslmode=require")

echo "-- Creating database ${APP_DB} and role ${APP_USER} (idempotent)…"
"${PSQL[@]}" -v ON_ERROR_STOP=1 \
  -v app_user="$APP_USER" \
  -v app_db="$APP_DB" \
  -v app_password="$RENDERD_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'app_user')\gexec

SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'app_user', :'app_password')
WHERE EXISTS (SELECT FROM pg_roles WHERE rolname = :'app_user')\gexec

SELECT format('CREATE DATABASE %I OWNER %I', :'app_db', :'app_user')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'app_db')\gexec

SELECT format('GRANT ALL PRIVILEGES ON DATABASE %I TO %I', :'app_db', :'app_user')\gexec
SQL


echo "-- Enabling PostGIS + control schema on ${APP_DB}…"
psql "host=${RDSHOST}" "port=5432" "dbname=${APP_DB}" "user=${MASTER_USER}" "sslmode=require" \
  -v ON_ERROR_STOP=1 \
  -c "CREATE EXTENSION IF NOT EXISTS postgis;" \
  -c "CREATE EXTENSION IF NOT EXISTS hstore;" \
  -f "$BOOTSTRAP_SQL"

psql "host=${RDSHOST}" "port=5432" "dbname=${APP_DB}" "user=${MASTER_USER}" "sslmode=require" \
  -v ON_ERROR_STOP=1 <<SQL
GRANT USAGE, CREATE ON SCHEMA public TO ${APP_USER};
GRANT ALL ON SCHEMA control TO ${APP_USER};
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA control TO ${APP_USER};
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA control TO ${APP_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA control
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${APP_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA control
  GRANT USAGE, SELECT ON SEQUENCES TO ${APP_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${APP_USER};
ALTER TABLE IF EXISTS public.geometry_columns OWNER TO ${APP_USER};
ALTER TABLE IF EXISTS public.spatial_ref_sys OWNER TO ${APP_USER};
SQL

echo "-- Upserting Secrets Manager secret ${SECRET_NAME}…"
SECRET_JSON="$(python3 - <<PY
import json
print(json.dumps({
  "host": "${RDSHOST}",
  "port": 5432,
  "dbname": "${APP_DB}",
  "username": "${APP_USER}",
  "password": """${RENDERD_PASSWORD}""",
  "sslmode": "require",
}))
PY
)"

if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" >/dev/null 2>&1; then
  aws secretsmanager put-secret-value \
    --secret-id "$SECRET_NAME" \
    --region "$REGION" \
    --secret-string "$SECRET_JSON" >/dev/null
  echo "Updated secret $SECRET_NAME"
else
  aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --region "$REGION" \
    --secret-string "$SECRET_JSON" >/dev/null
  echo "Created secret $SECRET_NAME"
fi

echo
echo "=== Bootstrap complete ==="
echo "Test app user:"
echo "  PGPASSWORD='***' psql \"host=\$RDSHOST port=5432 dbname=${APP_DB} user=${APP_USER} sslmode=require\""
echo
echo "Next (same region ${REGION}):"
echo "  1) Build/push importer to ECR in ${REGION}"
echo "  2) RDSHOST=\$RDSHOST AWS_REGION=${REGION} ./aws/cloudshell-setup.sh"
echo "  3) ECS_SUBNETS=… ECS_SECURITY_GROUPS=… AWS_REGION=${REGION} ./aws/deploy-control.sh"
echo
echo "Note: keep using IAM token only for master admin. App/Lambda use secret ${SECRET_NAME}."
