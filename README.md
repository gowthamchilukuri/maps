# Sigeo map service

Fresh **Geofabrik / OSM → PostGIS** stack with a control API that runs locally in Docker and on AWS as Lambda.

Downloads regional OSM extracts, loads them with `osm2pgsql`, tracks jobs in Postgres. Does **not** render tiles.

---

## Quick start (local)

```bash
cp .env.example .env          # set POSTGRES_PASSWORD
docker compose up -d --build
```

API: **http://localhost:8092** · Postgres: **localhost:5433** (`gis` / `_renderd`)

### Admin UI (React + Amplify Cognito)

```bash
cd ui
cp .env.example .env
cp amplify_outputs.example.json amplify_outputs.json
npm install
npx ampx sandbox --once          # Cognito (needs AWS creds)
npm run dev                      # http://localhost:5173
```

Sign in → pick **monaco** → **Run now**. Full Amplify Hosting steps: [docs/UI-AMPLIFY.md](docs/UI-AMPLIFY.md).

Manual import:

```bash
OSM_AREA=monaco FORCE=true docker compose run --rm importer
```

Stop:

```bash
docker compose down       # keep data
docker compose down -v    # wipe DB
```

---

## What you get

```text
Admin UI  →  Control API (Docker / Lambda)
                 │
                 ├─ settings, jobs, logs in Postgres (control.*)
                 └─ starts importer
                        │
                        ▼
              Download Geofabrik PBF
                        │
                        ▼
              osm2pgsql → planet_osm_*
```

### API

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/health` | DB ping |
| GET/PUT | `/api/settings` | Area + schedule |
| GET | `/api/areas` | Presets |
| POST | `/api/jobs/run` | Start import |
| GET | `/api/jobs`, `/api/jobs/latest`, `/api/jobs/{id}` | Job status |
| GET | `/api/jobs/{id}/logs` | Log tail |
| GET | `/api/db/info` | Table counts |

### Lambda (`api/index.js`)

| Handler | Trigger |
|---------|---------|
| `handler` | API Gateway HTTP API |
| `schedulerHandler` | EventBridge `rate(1 hour)` |

---

## Layout

```text
Sigeo-map-service/
  docker-compose.yml   PostGIS + API (+ importer profile)
  api/                 Control API (local server.js + Lambda index.js)
  ui/                  React Vite console + Amplify Gen2 auth
  amplify.yml          Amplify Hosting (app root = ui)
  importer/            Download PBF + osm2pgsql
  db/init/             PostGIS extensions + control schema
  aws/                 ECS/Lambda scripts + Cognito authorizer
  docs/                Deploy + Amplify UI notes
```

---

## Deploy (AWS + GitLab + Amplify)

| Guide | Contents |
|-------|----------|
| **[docs/DEPLOY.md](docs/DEPLOY.md)** | RDS, ECS, Lambda, GitLab — what is manual vs CI |
| **[docs/UI-AMPLIFY.md](docs/UI-AMPLIFY.md)** | React Vite UI, Cognito sandbox, Amplify Hosting, JWT on API |

Short version:

1. **Manual once:** RDS + secret + ECR + `cloudshell-setup.sh` + `deploy-control.sh`
2. **UI:** Amplify Hosting on `ui/` + `attach-cognito-authorizer.sh`
3. **GitLab:** auto `build-importer` / `deploy-control`; **manual Play** for `import`

---

## License / data

© OpenStreetMap contributors, [ODbL](https://opendatacommons.org/licenses/odbl/). Extracts from [Geofabrik](https://download.geofabrik.de/) / [OSM.fr](https://download.openstreetmap.fr/).
