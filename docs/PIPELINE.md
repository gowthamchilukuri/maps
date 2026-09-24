# Post-import pipeline: osm2pgsql + Planetiler→S3 + Nominatim **DB**

After one Geofabrik download (same local PBF):

```
PBF (on task disk)
 ├─ ENABLE_OSM2PGSQL=true   → osm2pgsql → RDS `gis` (planet_osm_*)
 ├─ ENABLE_PLANETILER=true  → Planetiler → s3://$BUCKET/mbtiles/{area}.mbtiles
 └─ ENABLE_NOMINATIM=true   → nominatim import → RDS `nominatim` (same PBF, no S3)
```

| In scope | Out of scope |
|----------|----------------|
| Fill **Nominatim database** | Nominatim HTTP/API service |
| MBTiles on S3 (Planetiler only) | S3 for Nominatim |

---

## Env flags

| Variable | Default | Meaning |
|----------|---------|---------|
| `ENABLE_OSM2PGSQL` | `true` | Map PostGIS load |
| `ENABLE_PLANETILER` | `false` | MBTiles → S3 |
| `ENABLE_NOMINATIM` | `false` | Nominatim DB import from local PBF |
| `MBTILES_S3_BUCKET` | setup default | S3 for **MBTiles only** |
| `NOMINATIM_PGHOST` | same as map RDS | Nominatim DB host |
| `NOMINATIM_PGUSER` | `nominatim` | |
| `NOMINATIM_PGPASSWORD` | (required if enabled) | |
| `NOMINATIM_PGDATABASE` | `nominatim` | Dedicated DB — not `gis` |
| `PLANETILER_JAVA_OPTS` | `-Xmx4g` | |

---

## Admin / one-time

1. RDS: databases `gis` (map) and `nominatim` (geocode data), users accordingly.
2. S3 bucket **only if** Planetiler is enabled.
3. Rebuild importer image (`build-importer`) — image includes Nominatim CLI + Planetiler.
4. Set Lambda/ECS env: `ENABLE_NOMINATIM=true`, `NOMINATIM_PGPASSWORD=…`, optionally `ENABLE_PLANETILER=true`.

```sql
CREATE USER nominatim WITH PASSWORD '…' CREATEDB;
CREATE DATABASE nominatim OWNER nominatim;
```

---

## Outputs

| Artifact | Where |
|----------|--------|
| Map tables | RDS `gis` → `planet_osm_*` |
| MBTiles | S3 `mbtiles/{area}.mbtiles` (if Planetiler on) |
| Nominatim data | RDS `nominatim` (if Nominatim on) |
