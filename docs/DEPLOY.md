# Deploy guide — local, AWS, GitLab

This doc covers **what you run by hand once**, **what GitLab can automate later**, and **which jobs stay manual**.

---

## Overview

| Layer | What | Who does it |
|-------|------|-------------|
| Postgres (RDS or Docker) | Store `planet_osm_*` + `control.*` | **Manual** (first time) |
| Secrets Manager | DB credentials for Lambda/ECS | **Manual** (first time) |
| ECR importer image | Docker image that downloads Geofabrik + runs osm2pgsql | **GitLab only** — job `build-importer` |
| ECS Fargate task | Runs the importer on AWS | **Manual** once via `cloudshell-setup.sh` |
| Lambda + API Gateway + EventBridge | Control API + hourly scheduler | GitLab `deploy-control` **or** `deploy-control.sh` |
| OSM import run | Actually load an extract into the DB | **Manual** (UI / GitLab `import` / `aws ecs run-task`) |
| Admin UI | Browser console | Local `serve` or S3 (optional) |

**Important:** The hourly EventBridge rule already starts imports when settings allow it. Do **not** also enable a GitLab schedule on the `import` job unless you turn the EventBridge rule off — you would get double imports.

---

## 1. Local (Docker) — no AWS

```bash
cd Sigeo-map-service
cp .env.example .env
# edit POSTGRES_PASSWORD
docker compose up -d --build
```

| URL / endpoint | Value |
|----------------|-------|
| Admin UI + API | http://localhost:8092 |
| Postgres | `localhost:5433` · db `gis` · user `_renderd` |

Import from UI (**Run now**) or CLI:

```bash
OSM_AREA=monaco FORCE=true docker compose run --rm importer
```

Stop:

```bash
docker compose down          # keep volume
docker compose down -v       # wipe DB
```

---

## 2. AWS — one-time manual setup

Do these **once per account/environment**. GitLab does not create RDS or the first IAM/ECS wiring.

### Checklist (manual)

- [ ] Create RDS PostgreSQL with PostGIS (or Aurora PostgreSQL + PostGIS)
- [ ] Create database `gis` and app user `_renderd`
- [ ] Run `db/init/aws-bootstrap.sql` as master
- [ ] Create Secrets Manager secret `sigeo-map/db`
- [ ] ECR: set GitLab vars (`ECR_REGISTRY`, AWS keys, `AWS_DEFAULT_REGION=eu-south-1`); first push via Play `build-importer` (no laptop docker push)
- [ ] Note `ECS_SUBNETS` and `ECS_SECURITY_GROUPS`
- [ ] Run `./aws/cloudshell-setup.sh` (after at least one ECR image exists)
- [ ] Run `./aws/deploy-control.sh` (or let GitLab do this after CI vars exist)
- [ ] Point UI at API Gateway URL

### 2.1 RDS + SQL bootstrap

**Example (Aurora, IAM master login, `eu-south-1`):**

```bash
export RDSHOST="database-2.cluster-cdeqmke44b69.eu-south-1.rds.amazonaws.com"
export AWS_REGION=eu-south-1
export RENDERD_PASSWORD='choose-a-strong-password'

# Optional: open a master shell with IAM token (same as your command)
psql "host=$RDSHOST port=5432 dbname=postgres user=postgres sslmode=require password=$(
  aws rds generate-db-auth-token --hostname $RDSHOST --port 5432 --username postgres --region eu-south-1
)"

# Or run the full bootstrap (creates gis, _renderd, PostGIS, control.*, Secrets Manager):
./aws/bootstrap-rds.sh
```

What `bootstrap-rds.sh` does:

1. Connects as `postgres` with an **IAM auth token** (like your `psql` line).
2. Creates DB `gis` and role `_renderd` with a **normal password** (`RENDERD_PASSWORD`).
3. Enables PostGIS / hstore and applies `db/init/aws-bootstrap.sql`.
4. Upserts Secrets Manager secret **`sigeo-map/db`** in `$AWS_REGION`.

**Why two auth modes?** Master IAM is fine for one-off admin. Lambda, ECS importer, and `osm2pgsql` use the password in Secrets Manager — they do not call `generate-db-auth-token`.

Manual SQL equivalent (if you prefer not to use the script): see older steps below — create `gis` / `_renderd`, then `\c gis` and run `db/init/aws-bootstrap.sql`, then create the secret JSON yourself.

1. Create an RDS/Aurora instance that can run PostGIS (enable the extension).
2. As master user create `gis` + `_renderd`, then run `db/init/aws-bootstrap.sql`.
3. Put credentials in Secrets Manager as `sigeo-map/db` (host/port/dbname/username/password).

Or from a machine that can reach RDS:

```bash
psql "host=YOUR_RDS_HOST dbname=gis user=postgres sslmode=require" \
  -f db/init/aws-bootstrap.sql
```

Ensure `_renderd` can read/write `public` (for osm2pgsql) and `control` (for jobs).

**Region:** this lab uses **`eu-south-1`**. Export `AWS_REGION=eu-south-1` (or `AWS_DEFAULT_REGION`) for all `aws/` scripts — they default to `eu-central-1` if unset.

### 2.2 Secrets Manager

Secret name: **`sigeo-map/db`**

```json
{
  "host": "YOUR_RDS_ENDPOINT.eu-central-1.rds.amazonaws.com",
  "port": 5432,
  "dbname": "gis",
  "username": "_renderd",
  "password": "…"
}
```

Never put this password in GitLab CI variables or in git.

### 2.3 ECR — create empty repo once; **pushes only from GitLab**

Do **not** `docker push` from your laptop. GitLab job `build-importer` builds and pushes.

**One-time (optional):** create the empty repository (CI can also create it on first run):

```bash
REGION=eu-south-1   # match your Aurora region
aws ecr create-repository \
  --repository-name sigeo-map-importer \
  --region $REGION \
  --image-scanning-configuration scanOnPush=true
```

**GitLab CI/CD variables** (Settings → CI/CD → Variables):

| Variable | Example |
|----------|---------|
| `AWS_DEFAULT_REGION` | `eu-south-1` |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | IAM user that can push ECR |
| `ECR_REGISTRY` | `123456789012.dkr.ecr.eu-south-1.amazonaws.com` |

IAM for that user (minimum for ECR push):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:CreateRepository",
        "ecr:DescribeRepositories",
        "ecr:BatchCheckLayerAvailability",
        "ecr:CompleteLayerUpload",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer"
      ],
      "Resource": "arn:aws:ecr:eu-south-1:ACCOUNT:repository/sigeo-map-importer"
    }
  ]
}
```

**How images get to ECR**

| Trigger | What happens |
|---------|----------------|
| Merge to default branch changing `importer/**` | `build-importer` runs automatically |
| **Build → Pipelines → Run pipeline** → Play `build-importer` | Manual rebuild / first push |

Tags pushed:

- `$ECR_REGISTRY/sigeo-map-importer:$CI_COMMIT_SHORT_SHA`
- `$ECR_REGISTRY/sigeo-map-importer:latest`

After the first successful push, continue with `cloudshell-setup.sh` (ECS task uses `:latest`).
### 2.4 ECS cluster + task + SG (manual script)

In CloudShell or a machine with AWS CLI:

```bash
export RDSHOST=YOUR_RDS_ENDPOINT.eu-central-1.rds.amazonaws.com
export AWS_REGION=eu-central-1
chmod +x aws/cloudshell-setup.sh
./aws/cloudshell-setup.sh
```

Script creates (if missing):

- IAM roles `sigeo-map-ecs-execution`, `sigeo-map-ecs-task`
- ECS cluster `sigeo-map`
- Task definition `sigeo-map-importer`
- Security group `sigeo-map-fargate` + ingress to RDS:5432
- CloudWatch log group `/ecs/sigeo-map-importer`

**Save from the script output:**

```bash
export ECS_SUBNETS=subnet-aaa,subnet-bbb
export ECS_SECURITY_GROUPS=sg-xxxxxxxx
```

You will paste the same values into GitLab CI/CD variables.

### 2.5 Lambda + HTTP API + EventBridge (manual or GitLab)

```bash
export ECS_SUBNETS=subnet-aaa,subnet-bbb
export ECS_SECURITY_GROUPS=sg-xxxxxxxx
export AWS_REGION=eu-central-1
chmod +x aws/deploy-control.sh
./aws/deploy-control.sh
```

Creates/updates:

| Resource | Name |
|----------|------|
| Lambda | `sigeo-map-control` (API) |
| Lambda | `sigeo-map-scheduler` (hourly) |
| HTTP API | `sigeo-map-http` |
| EventBridge rule | `sigeo-map-hourly` (`rate(1 hour)`) |

Script prints `API health: https://….execute-api.…amazonaws.com/api/health`.

### 2.6 Admin UI — Amplify (manual)

The console is **React + Vite** with **Cognito email/password** (Amplify Gen2). See **[UI-AMPLIFY.md](UI-AMPLIFY.md)** for the full flow.

Short path:

```bash
cd ui
npm install
npx ampx sandbox --once
# set VITE_SIGEO_MAP_API_BASE to API Gateway URL in .env / Amplify env
```

1. Connect repo to **Amplify Hosting** (app root `ui`, see root `amplify.yml`).
2. Set env `VITE_SIGEO_MAP_API_BASE` to the API Gateway URL.
3. Attach JWT authorizer (once):

```bash
export USER_POOL_ID=…   # from amplify_outputs.json
export CLIENT_ID=…
./aws/attach-cognito-authorizer.sh
```

### 2.7 First import on AWS (manual)

Pick one:

**A. Admin UI** — Save settings → **Run now** (API starts Fargate).

**B. AWS CLI:**

```bash
aws ecs run-task \
  --region eu-central-1 \
  --cluster sigeo-map \
  --launch-type FARGATE \
  --task-definition sigeo-map-importer \
  --network-configuration "awsvpcConfiguration={subnets=[$ECS_SUBNETS],securityGroups=[$ECS_SECURITY_GROUPS],assignPublicIp=ENABLED}" \
  --overrides '{"containerOverrides":[{"name":"importer","environment":[
    {"name":"OSM_AREA","value":"monaco"},
    {"name":"FORCE","value":"true"}
  ]}]}'
```

**C. GitLab** — run pipeline job `import` manually (see below). Start with `monaco`.

Logs: CloudWatch `/ecs/sigeo-map-importer`, or UI job logs after the importer writes to `control.job_logs`.

---

## 3. GitLab CI

File: [`.gitlab-ci.yml`](../.gitlab-ci.yml)

### 3.1 CI/CD variables (set manually in GitLab)

**Settings → CI/CD → Variables**

| Variable | Protected | Masked | Notes |
|----------|-----------|--------|-------|
| `AWS_DEFAULT_REGION` | optional | no | e.g. `eu-south-1` (must match ECR/RDS) |
| `AWS_ACCESS_KEY_ID` | yes | yes | Or use OIDC / assumed role instead |
| `AWS_SECRET_ACCESS_KEY` | yes | yes | |
| `ECR_REGISTRY` | yes | no | `ACCOUNT.dkr.ecr.eu-south-1.amazonaws.com` |
| `ECS_SUBNETS` | yes | no | `subnet-a,subnet-b` (no spaces) |
| `ECS_SECURITY_GROUPS` | yes | no | `sg-…` |

Do **not** store the DB password in GitLab. Runtime uses Secrets Manager.

IAM user/role for CI needs roughly:

- ECR push
- `ecs:RunTask`, `ecs:DescribeTasks`, `iam:PassRole` for importer roles
- Lambda update + API Gateway (same as `deploy-control.sh`)
- Secrets Manager `GetSecretValue` on `sigeo-map/db` (for deploy script ARN lookup)

### 3.2 Pipeline jobs

| Job | Stage | When it runs | Manual? |
|-----|-------|--------------|---------|
| `build-importer` | build | Default branch when `importer/**` changes; **or** manual Play on Run pipeline | **GitLab pushes to ECR** (creates repo if missing) |
| `deploy-control` | deploy | Default branch when `api/**` or `aws/deploy-control.sh` changes | **Automatic** (after one-time AWS setup) |
| `import` | import | Only when you start a pipeline from the UI (`web`) | **Manual** — click ▶ Play |

#### `build-importer` (ECR)

Creates ECR repo `sigeo-map-importer` if missing, builds `importer/`, pushes:

- `$ECR_REGISTRY/sigeo-map-importer:$CI_COMMIT_SHORT_SHA`
- `$ECR_REGISTRY/sigeo-map-importer:latest`

First time: **Build → Pipelines → Run pipeline** → Play **build-importer**.

#### `deploy-control`

Runs `aws/deploy-control.sh` inside the job (needs `ECS_SUBNETS` / `ECS_SECURITY_GROUPS` set).

#### `import` (manual)

Starts one Fargate task. Defaults in CI:

- `OSM_AREA=monaco` (override in **Run pipeline** → Variables)
- `FORCE=false`

How to run:

1. GitLab → **Build → Pipelines → Run pipeline**
2. Optional variables: `OSM_AREA=centro`, `FORCE=true`
3. After pipeline appears, open the `import` job → **Play**

Do **not** attach a GitLab schedule to `import` while EventBridge `sigeo-map-hourly` is enabled.

---

## 4. What stays manual forever (ops)

Even with GitLab working, these stay human decisions:

| Action | How |
|--------|-----|
| First RDS / secret / ECS setup | Section 2 (ECR images = GitLab only) |
| Choose large areas (`italy`, …) | UI settings or `OSM_AREA` on import |
| Force re-import | UI with force, or `FORCE=true` on import job |
| One-off import | UI **Run now**, GitLab `import` Play, or `aws ecs run-task` |
| Rotate DB password | Update Secrets Manager (+ re-run cloudshell-setup if task def embeds password) |
| Stop scheduled imports | UI: uncheck “Scheduled imports”, or disable EventBridge rule `sigeo-map-hourly` |
| Serve / host admin UI | Amplify Hosting (`ui/`) — see [UI-AMPLIFY.md](UI-AMPLIFY.md) |
| Cognito JWT on API Gateway | `./aws/attach-cognito-authorizer.sh` once |

---

## 5. Recommended order (new environment)

```text
1. Local smoke test (monaco)           ← optional but useful
2. RDS + bootstrap SQL                 ← MANUAL
3. Secrets Manager sigeo-map/db        ← MANUAL
4. GitLab CI vars + Play `build-importer` ← ECR push (no laptop `docker push`)
5. cloudshell-setup.sh                 ← MANUAL (needs image in ECR)
6. Set remaining GitLab vars (ECS_*)   ← MANUAL
7. deploy-control.sh OR merge api/     ← manual script or GitLab deploy-control
8. Amplify Hosting + Cognito authorizer← MANUAL (see UI-AMPLIFY.md)
9. First import (monaco)               ← MANUAL (UI / GitLab import / CLI)
10. Change settings to real area       ← MANUAL when ready
```

After that day-to-day:

- Change importer code → merge → `build-importer` pushes to ECR (re-register task def if you change CPU/memory in cloudshell script).
- Change API code → merge → `deploy-control` updates Lambdas.
- Imports → EventBridge hourly **or** manual UI / GitLab `import`.

---

## 6. Quick verification

```bash
# API (replace with your Gateway URL)
curl -s https://YOUR_API.execute-api.eu-central-1.amazonaws.com/api/health

# Settings
curl -s https://YOUR_API.execute-api.eu-central-1.amazonaws.com/api/settings

# Local
curl -s http://localhost:8092/api/health
```

Expect `{"status":"ok",...}`.

---

## 7. Resource name cheat sheet

| Kind | Name |
|------|------|
| Docker network (local) | `sigeo-map-net` |
| Secret | `sigeo-map/db` |
| ECR | `sigeo-map-importer` |
| ECS cluster | `sigeo-map` |
| ECS task | `sigeo-map-importer` |
| Lambda API | `sigeo-map-control` |
| Lambda scheduler | `sigeo-map-scheduler` |
| HTTP API | `sigeo-map-http` |
| EventBridge | `sigeo-map-hourly` |
| Fargate SG | `sigeo-map-fargate` |
