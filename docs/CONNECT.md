# Connect

Point map / geocode / analysis apps at this PostGIS instance. Do not write to `control.*`.

| Setting | Local Compose | AWS |
|---------|---------------|-----|
| Host | `localhost` (or `postgis` on `sigeo-map-net`) | RDS endpoint |
| Port | `5433` | `5432` |
| Database | `gis` | `gis` |
| User | `_renderd` | `_renderd` |
| Password | `.env` | Secrets Manager |

Tables: `planet_osm_point`, `planet_osm_line`, `planet_osm_polygon`, `planet_osm_roads`.  
Geometry column: `way` · SRID **3857**.
