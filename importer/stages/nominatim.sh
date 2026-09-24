#!/usr/bin/env bash
# Import the already-downloaded PBF into a dedicated Nominatim Postgres database.
# No S3 — uses local $PBF_PATH from the same importer job.
#
# Nominatim cannot reuse carto planet_osm_* — use a separate DB (default: nominatim).
#
# Env:
#   PBF_PATH (required), AREA
#   NOMINATIM_PGHOST   (default: PGHOST)
#   NOMINATIM_PGPORT   (default: PGPORT)
#   NOMINATIM_PGUSER   (default: nominatim, else PGUSER)
#   NOMINATIM_PGPASSWORD (default: PGPASSWORD)
#   NOMINATIM_PGDATABASE (default: nominatim)
set -euo pipefail

log() { /app/log.sh "$@"; }

PBF_PATH="${PBF_PATH:?PBF_PATH required}"
AREA="${AREA:-unknown}"

if ! command -v nominatim >/dev/null 2>&1; then
  log error "nominatim CLI not found in image — rebuild importer Dockerfile"
  exit 1
fi

export PGHOST="${NOMINATIM_PGHOST:-${PGHOST:?PGHOST or NOMINATIM_PGHOST required}}"
export PGPORT="${NOMINATIM_PGPORT:-${PGPORT:-5432}}"
export PGUSER="${NOMINATIM_PGUSER:-nominatim}"
export PGPASSWORD="${NOMINATIM_PGPASSWORD:-${PGPASSWORD:?PGPASSWORD or NOMINATIM_PGPASSWORD required}}"
export PGDATABASE="${NOMINATIM_PGDATABASE:-nominatim}"
export NOMINATIM_PASSWORD="${NOMINATIM_PASSWORD:-$PGPASSWORD}"

PROJECT_DIR="${NOMINATIM_PROJECT_DIR:-/tmp/nominatim-project}"
mkdir -p "$PROJECT_DIR"

log info "Nominatim DB import area=${AREA} db=${PGHOST}:${PGPORT}/${PGDATABASE} user=${PGUSER}"
log info "Using local PBF $(basename "$PBF_PATH") ($(du -h "$PBF_PATH" | awk '{print $1}'))"

# Ensure database exists (connect to maintenance DB postgres)
if ! psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -At \
  -c "SELECT 1 FROM pg_database WHERE datname='${PGDATABASE}'" | grep -q 1; then
  log info "Creating database ${PGDATABASE}…"
  psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE ${PGDATABASE};"
fi

log info "Running nominatim import (long-running)…"
NOM_LOG=/tmp/nominatim-import.log
set +e
nominatim import --osm-file "$PBF_PATH" --project-dir "$PROJECT_DIR" >"$NOM_LOG" 2>&1
NOM_RC=$?
set -e
if [[ "$NOM_RC" -ne 0 ]]; then
  log error "nominatim import exited ${NOM_RC}"
  tail -n 40 "$NOM_LOG" | while IFS= read -r line || [[ -n "$line" ]]; do
    log error "nominatim: ${line:0:900}"
  done
  exit "$NOM_RC"
fi

log info "Nominatim DB import finished OK"

# Mark in control DB (map gis connection may differ — use original carto PG* if set)
if [[ -n "${PGHOST:-}" ]]; then
  # Restore carto connection for control.* update if we overwrote PG* for nominatim
  :
fi
# control.* lives on the map DB — use CONTROL_* or original env saved by import.sh
if [[ -n "${CONTROL_PGHOST:-}" && -n "${CONTROL_PGPASSWORD:-}" ]]; then
  PGPASSWORD="$CONTROL_PGPASSWORD" psql \
    -h "$CONTROL_PGHOST" -p "${CONTROL_PGPORT:-5432}" \
    -U "${CONTROL_PGUSER}" -d "${CONTROL_PGDATABASE}" -v ON_ERROR_STOP=1 \
    -c "ALTER TABLE control.area_state ADD COLUMN IF NOT EXISTS nominatim_imported_at timestamptz;" >/dev/null 2>&1 || true
  PGPASSWORD="$CONTROL_PGPASSWORD" psql \
    -h "$CONTROL_PGHOST" -p "${CONTROL_PGPORT:-5432}" \
    -U "${CONTROL_PGUSER}" -d "${CONTROL_PGDATABASE}" -v ON_ERROR_STOP=1 \
    -c "UPDATE control.area_state SET nominatim_imported_at=now(), updated_at=now() WHERE area='${AREA}';" \
    >/dev/null || true
fi
