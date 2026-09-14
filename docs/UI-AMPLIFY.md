# Amplify Hosting (static UI — no Cognito yet)

Console + Git only. No Amplify Gen2 backend / `ampx` / CDK bootstrap required.

Your control API:

`https://lfvy5sv7gj.execute-api.eu-south-1.amazonaws.com`

---

## 1. Push latest build config

Ensure the repo has root `amplify.yml` with `appRoot: ui` and **frontend-only** build (`npm install` + `npm run build`). No `ampx pipeline-deploy`.

---

## 2. Create / update the Amplify app

1. **AWS Amplify** → Host web app (any account/region is fine for static hosting).
2. Connect GitLab/GitHub → branch **`main`**.
3. App root: **`ui`**.
4. Environment variable:

   | Name | Value |
   |------|--------|
   | `VITE_SIGEO_MAP_API_BASE` | `https://lfvy5sv7gj.execute-api.eu-south-1.amazonaws.com` |

5. Deploy. Open the Amplify URL → control panel (settings, Run now, jobs, logs).

The API currently accepts unauthenticated calls. Auth (Cognito) can be added later.

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Build still runs `ampx` | Push the new `amplify.yml` (no `backend:` section); in Console, confirm build settings match repo |
| UI loads but API errors | Check `VITE_SIGEO_MAP_API_BASE` (rebuild after changing env); CORS on API |
| Wrong AWS account | Static hosting does not need CDK bootstrap; ignore older Cognito/SSM errors |
