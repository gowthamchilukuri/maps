# Admin UI (React + Vite + Amplify Cognito)

Email/password login via Amplify Gen2. Hosted on **Amplify Hosting**. Talks to the control API (Docker locally or Lambda + API Gateway on AWS).

## Layout

```text
ui/
  amplify/auth/resource.ts   # defineAuth (email)
  amplify/backend.ts
  src/                       # React console + JWT API client
  amplify_outputs.json       # from sandbox / Amplify build (gitignored)
  amplify.yml                # at repo root — Amplify Hosting monorepo root = ui
```

## 1. Install & Cognito sandbox

```bash
cd ui
cp .env.example .env
cp amplify_outputs.example.json amplify_outputs.json   # stub until sandbox
npm install

# needs AWS credentials
npx ampx sandbox --once
# regenerates amplify_outputs.json with real Cognito IDs
```

Create a user in the Authenticator **Create Account** UI (email confirm), or in the Cognito console.

Login method: **email + password** (`amplify/auth/resource.ts`).

## 2. Local UI + local or AWS API

```bash
# Terminal A — PostGIS + control API
cd .. && cp .env.example .env && docker compose up -d --build

# Terminal B — Vite UI
cd ui
# .env: VITE_SIGEO_MAP_API_BASE=http://localhost:8092
npm run dev
# http://localhost:5173
```

Signed-in requests send `Authorization: Bearer <Cognito idToken>` to `VITE_SIGEO_MAP_API_BASE`.

Until you attach the Cognito JWT authorizer to API Gateway, the Lambda API still accepts requests without verifying the token (header is ignored). Local Docker API never validates JWT.

## 3. Protect API Gateway (manual, once)

After sandbox, read `auth.user_pool_id` and `auth.user_pool_client_id` from `amplify_outputs.json`:

```bash
export REGION=eu-central-1
export USER_POOL_ID=eu-central-1_XXXX
export CLIENT_ID=xxxxxxxx
chmod +x aws/attach-cognito-authorizer.sh
./aws/attach-cognito-authorizer.sh
```

After this, unauthenticated `curl` fails; the Amplify UI works.

## 4. Amplify Hosting deploy (manual)

1. Push this repo to GitLab/GitHub (or connect Amplify to the repo).
2. Amplify Console → **Create app** → connect repo.
3. Set **monorepo app root** to `ui` (or use root `amplify.yml` which already sets `appRoot: ui`).
4. Enable **Amplify Gen2** backend build so Cognito is provisioned for the branch (or use sandbox outputs for a frontend-only deploy).
5. Branch env variable:
   - `VITE_SIGEO_MAP_API_BASE` = API Gateway URL from `./aws/deploy-control.sh`
6. Deploy. Open the Amplify URL → sign up / sign in → control panel.

### Amplify Console build settings (if not using root amplify.yml)

```yaml
version: 1
frontend:
  phases:
    preBuild:
      commands:
        - npm ci
    build:
      commands:
        - npm run build
  artifacts:
    baseDirectory: dist
    files:
      - "**/*"
```

App root: `ui`.

## 5. What stays manual

| Step | Manual? |
|------|---------|
| `npx ampx sandbox --once` (dev Cognito) | Yes (first time / when auth changes) |
| Amplify Hosting connect repo + env var | Yes (once) |
| `attach-cognito-authorizer.sh` | Yes (once per API) |
| Create first Cognito user | Yes (or self Sign up) |
| Control API / importer AWS setup | See [DEPLOY.md](DEPLOY.md) |
