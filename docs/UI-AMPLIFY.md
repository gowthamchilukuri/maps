# Amplify Hosting (Console + CloudShell only — no laptop)

Use this when you do **not** want `npm` / `ampx sandbox` on your Mac.

Your control API is already live:

`https://lfvy5sv7gj.execute-api.eu-south-1.amazonaws.com`

---

## 1. Push latest `amplify.yml` (once)

From wherever you push code (GitLab web editor is fine if you have no local git):

- Ensure repo root has `amplify.yml` with `appRoot: ui` and a **backend** `ampx pipeline-deploy` step.
- Ensure `ui/amplify/` (auth) is in the repo (already committed).

---

## 2. Create the Amplify app (Console)

1. Open **AWS Amplify** in region **`eu-south-1`** (same as your API).
2. **Create new app** → **Host web app**.
3. Provider: **GitLab** → authorize → pick `g.chilukuri/sigeo-map-service`.
4. Branch: **`main`**.
5. Monorepo / app root: **`ui`**  
   (If asked for build settings, use the repo `amplify.yml`.)
6. **Environment variables** (for the branch):

   | Name | Value |
   |------|--------|
   | `VITE_SIGEO_MAP_API_BASE` | `https://lfvy5sv7gj.execute-api.eu-south-1.amazonaws.com` |

7. Save and **deploy**.

Amplify will:

- create **Cognito** (from `ui/amplify`)
- build the React app
- host it on an `https://….amplifyapp.com` URL

Wait until the deploy is **green**. Open the Amplify URL → **Create account** (email/password) → sign in → control panel (**Run now**, jobs, logs).

Until step 3, the API still accepts calls without checking the JWT (UI already sends the token).

---

## 3. Lock API Gateway to Cognito (CloudShell, once)

After a successful Amplify deploy, get pool + client IDs:

**Option A — Amplify Console**

App → **Backend** / **Authentication** → copy User pool ID and App client ID.

**Option B — CloudShell**

```bash
export AWS_REGION=eu-south-1

# List user pools; pick the Amplify one (name often contains amplify / sigeo)
aws cognito-idp list-user-pools --max-results 20 --region $AWS_REGION \
  --query 'UserPools[].[Id,Name]' --output table
```

Then:

```bash
export AWS_REGION=eu-south-1
export USER_POOL_ID='eu-south-1_XXXXXXXX'
export CLIENT_ID='xxxxxxxxxxxxxxxxxxxxxxxxxx'

# Upload attach-cognito-authorizer.sh if needed (Actions → Upload)
chmod +x attach-cognito-authorizer.sh
# or from unzipped aws/ folder:
# chmod +x aws/attach-cognito-authorizer.sh && ./aws/attach-cognito-authorizer.sh

./attach-cognito-authorizer.sh
```

After this, bare `curl` to the API without a token fails; the Amplify UI keeps working.

---

## 4. Day-to-day

| Action | Where |
|--------|--------|
| Open console | Amplify app URL |
| Sign up / sign in | Cognito via Amplify Authenticator |
| Change area / schedule | Settings in UI |
| Start import | **Run now** |
| Watch logs | Same page (polls API) |
| Redeploy UI | Push to `main` on GitLab (Amplify auto-builds) |

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Amplify build fails on `ampx pipeline-deploy` | Confirm app root is `ui`, branch is `main`, and Amplify service role can deploy Cognito/CDK |
| UI loads but API errors | Check `VITE_SIGEO_MAP_API_BASE` (no trailing slash issues; rebuild after changing env) |
| Sign-up email never arrives | Cognito console → User pool → confirm users manually for lab |
| GitLab not listed in Amplify | Use Amplify’s GitLab OAuth; or mirror repo to GitHub and connect that |

No laptop `npm install` / `ampx sandbox` required for this path.
