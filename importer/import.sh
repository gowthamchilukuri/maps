#!/usr/bin/env bash
# Download an OSM extract and load it into PostGIS. Skip if remote MD5 unchanged.
set -euo pipefail

log() { /app/log.sh "$@"; }

PGHOST="${PGHOST:-postgis}"
PGPORT="${PGPORT:-5432}"
PGDATABASE="${PGDATABASE:-gis}"
PGUSER="${PGUSER:-_renderd}"
export PGPASSWORD="${PGPASSWORD:?PGPASSWORD is required}"

AREA="${OSM_AREA:-monaco}"
CACHE_MB="${CACHE_MB:-2048}"
FORCE="${FORCE:-false}"
JOB_ID="${JOB_ID:-}"
PBF_DIR="${PBF_DIR:-/pbf}"
FLAT_NODES="${FLAT_NODES:-}"
PROCESSES="${OSM2PGSQL_PROCESSES:-$(nproc 2>/dev/null || echo 2)}"

mkdir -p "$PBF_DIR" /tmp/osm2pgsql

# Area → download URL + local filename
resolve_area() {
  case "$1" in
    monaco)
      URL="https://download.geofabrik.de/europe/monaco-latest.osm.pbf"
      FILE="monaco-latest.osm.pbf"
      ;;
    rome|centro)
      URL="https://download.geofabrik.de/europe/italy/centro-latest.osm.pbf"
      FILE="centro-latest.osm.pbf"
      ;;
    italy)
      URL="https://download.geofabrik.de/europe/italy-latest.osm.pbf"
      FILE="italy-latest.osm.pbf"
      ;;
    isole)
      URL="https://download.openstreetmap.fr/extracts/europe/italy/isole-latest.osm.pbf"
      FILE="isole-latest.osm.pbf"
      ;;
    nord-est)
      URL="https://download.geofabrik.de/europe/italy/nord-est-latest.osm.pbf"
      FILE="nord-est-latest.osm.pbf"
      ;;
    nord-ovest)
      URL="https://download.geofabrik.de/europe/italy/nord-ovest-latest.osm.pbf"
      FILE="nord-ovest-latest.osm.pbf"
      ;;
    sud)
      URL="https://download.geofabrik.de/europe/italy/sud-latest.osm.pbf"
      FILE="sud-latest.osm.pbf"
      ;;
    *)
      # Treat as Geofabrik path, e.g. europe/italy/centro
      URL="https://download.geofabrik.de/${1}-latest.osm.pbf"
      FILE="$(basename "$1")-latest.osm.pbf"
      ;;
  esac
}

mark_job() {
  local status="$1"
  local err="${2:-}"
  [[ -z "$JOB_ID" ]] && return 0
  if [[ -n "$err" ]]; then
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 \
      -c "UPDATE control.jobs SET status='${status}', finished_at=now(), error=\$e\$${err}\$e\$ WHERE id='${JOB_ID}'::uuid;" >/dev/null
  else
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 \
      -c "UPDATE control.jobs SET status='${status}', finished_at=now() WHERE id='${JOB_ID}'::uuid;" >/dev/null
  fi
}

on_error() {
  local code=$?
  log error "Importer failed (exit $code)"
  mark_job failed "importer exit $code"
  exit "$code"
}
trap on_error ERR

resolve_area "$AREA"
PBF_PATH="${PBF_DIR}/${FILE}"
MD5_URL="${URL}.md5"

log info "Area=${AREA} url=${URL}"
if [[ -n "$JOB_ID" ]]; then
  psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 \
    -c "UPDATE control.jobs SET status='running', started_at=now() WHERE id='${JOB_ID}'::uuid;" >/dev/null
fi

# Remote MD5 (Geofabrik publishes companion .md5 files)
REMOTE_MD5=""
if curl -fsSL -A "sigeo-map-importer/1.0" -o /tmp/remote.md5 "$MD5_URL"; then
  REMOTE_MD5="$(awk '{print $1}' /tmp/remote.md5 | head -1)"
  log info "Remote MD5=${REMOTE_MD5}"
else
  log info "No remote .md5 available; will always download"
fi

LOCAL_MD5=""
if [[ -n "$JOB_ID" && -n "$REMOTE_MD5" ]]; then
  psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 \
    -c "UPDATE control.jobs SET remote_md5='${REMOTE_MD5}' WHERE id='${JOB_ID}'::uuid;" >/dev/null
fi

PREV_MD5="$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -At \
  -c "SELECT md5 FROM control.area_state WHERE area='${AREA}' LIMIT 1;" || true)"

if [[ "$FORCE" != "true" && -n "$REMOTE_MD5" && "$REMOTE_MD5" == "$PREV_MD5" ]]; then
  log info "Extract unchanged (md5=${REMOTE_MD5}) — skipping import"
  mark_job skipped
  exit 0
fi

log info "Downloading ${FILE}…"
curl -fL --retry 3 -A "sigeo-map-importer/1.0" -o "${PBF_PATH}.partial" "$URL"
mv "${PBF_PATH}.partial" "$PBF_PATH"
LOCAL_MD5="$(md5sum "$PBF_PATH" | awk '{print $1}')"
log info "Downloaded md5=${LOCAL_MD5} size=$(du -h "$PBF_PATH" | awk '{print $1}')"

if [[ -n "$JOB_ID" ]]; then
  psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 \
    -c "UPDATE control.jobs SET local_md5='${LOCAL_MD5}' WHERE id='${JOB_ID}'::uuid;" >/dev/null
fi

FLAT_ARGS=()
if [[ "${FLAT_NODES}" == "1" || "${FLAT_NODES}" == "true" ]]; then
  FLAT_ARGS+=(--flat-nodes /tmp/osm2pgsql/flat-nodes.bin)
fi

log info "Running osm2pgsql (cache=${CACHE_MB}MB processes=${PROCESSES} flat_nodes=${FLAT_NODES:-false})…"
# osm2pgsql is noisy — keep full log on disk, only push a short tail to job_logs on failure.
OSM_LOG=/tmp/osm2pgsql-run.log
set +e
osm2pgsql \
  -H "$PGHOST" -P "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
  --create --slim -G --hstore \
  --tag-transform-script /openstreetmap-carto/openstreetmap-carto.lua \
  -C "$CACHE_MB" \
  --number-processes "$PROCESSES" \
  -S /openstreetmap-carto/openstreetmap-carto.style \
  "${FLAT_ARGS[@]}" \
  "$PBF_PATH" >"$OSM_LOG" 2>&1
OSM_RC=$?
set -e
if [[ "$OSM_RC" -ne 0 ]]; then
  log error "osm2pgsql exited ${OSM_RC}"
  # Last lines usually contain the real reason (OOM, disk, SQL, SSL, …)
  tail -n 40 "$OSM_LOG" | while IFS= read -r line || [[ -n "$line" ]]; do
    log error "osm2pgsql: ${line:0:900}"
  done
  exit "$OSM_RC"
fi
log info "osm2pgsql finished OK"

log info "Applying carto indexes + functions…"
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 \
  -f /openstreetmap-carto/indexes.sql
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 \
  -f /openstreetmap-carto/functions.sql

STORE_MD5="${REMOTE_MD5:-$LOCAL_MD5}"
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 \
  -c "INSERT INTO control.area_state (area, md5, updated_at) VALUES ('${AREA}', '${STORE_MD5}', now())
      ON CONFLICT (area) DO UPDATE SET md5=EXCLUDED.md5, updated_at=now();" >/dev/null

log info "Import complete for ${AREA}"
mark_job success
