#!/usr/bin/env bash
# Build vector MBTiles with Planetiler and upload to S3.
set -euo pipefail

log() { /app/log.sh "$@"; }

PBF_PATH="${PBF_PATH:?PBF_PATH required}"
AREA="${AREA:-unknown}"
BUCKET="${MBTILES_S3_BUCKET:-}"
PREFIX="${MBTILES_S3_PREFIX:-mbtiles}"
JAVA_OPTS="${PLANETILER_JAVA_OPTS:--Xmx4g}"
OUT_DIR="${PLANETILER_OUT_DIR:-/tmp/planetiler}"
UPLOAD="${ENABLE_PLANETILER_UPLOAD:-true}"

mkdir -p "$OUT_DIR"
MBTILES="${OUT_DIR}/${AREA}.mbtiles"
rm -f "$MBTILES"

log info "Planetiler: building ${MBTILES} from $(basename "$PBF_PATH")…"
# shellcheck disable=SC2086
java $JAVA_OPTS -jar /opt/planetiler/planetiler.jar \
  --osm_path="$PBF_PATH" \
  --output="$MBTILES"

SIZE="$(du -h "$MBTILES" | awk '{print $1}')"
log info "Planetiler OK size=${SIZE}"

if [[ "$UPLOAD" != "true" ]]; then
  log info "Planetiler upload skipped (ENABLE_PLANETILER_UPLOAD=${UPLOAD})"
  echo "$MBTILES"
  exit 0
fi

if [[ -z "$BUCKET" ]]; then
  log error "MBTILES_S3_BUCKET is required when ENABLE_PLANETILER_UPLOAD=true"
  exit 1
fi

KEY="${PREFIX%/}/${AREA}.mbtiles"
URI="s3://${BUCKET}/${KEY}"
log info "Uploading MBTiles → ${URI}"
aws s3 cp "$MBTILES" "$URI" --only-show-errors
log info "MBTiles uploaded ${URI}"

if [[ -n "${PGHOST:-}" && -n "${PGPASSWORD:-}" ]]; then
  psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "${PGUSER}" -d "${PGDATABASE}" -v ON_ERROR_STOP=1 \
    -c "ALTER TABLE control.area_state ADD COLUMN IF NOT EXISTS mbtiles_s3_uri text;" >/dev/null 2>&1 || true
  psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "${PGUSER}" -d "${PGDATABASE}" -v ON_ERROR_STOP=1 \
    -c "INSERT INTO control.area_state (area, md5, updated_at, mbtiles_s3_uri)
        VALUES ('${AREA}', COALESCE(
          (SELECT md5 FROM control.area_state WHERE area='${AREA}'), ''), now(), '${URI}')
        ON CONFLICT (area) DO UPDATE SET mbtiles_s3_uri=EXCLUDED.mbtiles_s3_uri, updated_at=now();" \
    >/dev/null || log info "Could not store mbtiles_s3_uri in area_state (non-fatal)"
fi

echo "$URI"
