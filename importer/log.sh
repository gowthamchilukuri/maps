#!/usr/bin/env bash
# Append a log line to control.job_logs when JOB_ID is set.
set -euo pipefail

LEVEL="${1:-info}"
shift || true
MSG="$*"

echo "[$LEVEL] $MSG"

if [[ -z "${JOB_ID:-}" ]]; then
  exit 0
fi

export PGPASSWORD="${PGPASSWORD:-}"
psql -h "${PGHOST}" -p "${PGPORT:-5432}" -U "${PGUSER}" -d "${PGDATABASE}" -v ON_ERROR_STOP=1 \
  -c "INSERT INTO control.job_logs (job_id, level, message) VALUES ('${JOB_ID}'::uuid, '${LEVEL}', \$msg\$${MSG}\$msg\$);" \
  >/dev/null
