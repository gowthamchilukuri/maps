# Amplify Hosting + Cognito UI

Monorepo app root: **`ui`**. Root `amplify.yml` runs Gen2 backend (`ampx pipeline-deploy`) then Vite.

Control API (account `663505294123`):

`https://lfvy5sv7gj.execute-api.eu-south-1.amazonaws.com`

---

## Env (Amplify Console)

| Name | Value |
|------|--------|
| `VITE_SIGEO_MAP_API_BASE` | `https://lfvy5sv7gj.execute-api.eu-south-1.amazonaws.com` |

---

## Lock API with Cognito JWT (CloudShell)

Run in the **API account** (`663505294123`), region `eu-south-1`.

1. Amplify Console → Backend / Authentication → copy **User pool ID** and **App client ID**  
   (or from build artifact `amplify_outputs.json`: `auth.user_pool_id`, `auth.user_pool_client_id`).

2. Upload `aws/attach-cognito-authorizer.sh` to CloudShell (or clone the repo), then:

```bash
export AWS_REGION=eu-south-1
export USER_POOL_ID='eu-south-1_XXXXXXXX'   # paste
export CLIENT_ID='xxxxxxxxxxxxxxxxxxxxxxxxxx'  # paste
# If Cognito is in another account but same region, still fine — JWT validates by issuer URL.
# export COGNITO_REGION=eu-south-1

chmod +x attach-cognito-authorizer.sh
./attach-cognito-authorizer.sh
```

3. Verify:

```bash
# 200 — public
curl -sS -o /dev/null -w '%{http_code}\n' \
  https://lfvy5sv7gj.execute-api.eu-south-1.amazonaws.com/api/health

# 401 — locked
curl -sS -o /dev/null -w '%{http_code}\n' \
  https://lfvy5sv7gj.execute-api.eu-south-1.amazonaws.com/api/areas
```

Signed-in Amplify UI should still work (it sends the Bearer id token).

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| UI 401 after lock | Confirm UI redeployed with real `amplify_outputs` + Authenticator; browser sends `Authorization` |
| curl health 401 | Re-run attach script (creates public `GET /api/health`) |
| Authorizer wrong pool | Re-run script with correct `USER_POOL_ID` / `CLIENT_ID` (script updates existing authorizer) |
| Cognito vs API account differ | OK for JWT; issuer uses pool id from Cognito’s region |
