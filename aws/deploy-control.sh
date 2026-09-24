#!/usr/bin/env bash
# Deploy control plane: Lambda (API + scheduler) + HTTP API Gateway + EventBridge.
# Prerequisites: Secrets Manager secret sigeo-map/db, ECS cluster/task from cloudshell-setup.sh
set -euo pipefail
export AWS_PAGER=""

REGION="${AWS_REGION:-eu-central-1}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
CLUSTER="${ECS_CLUSTER:-sigeo-map}"
TASK_DEF="${ECS_TASK_DEFINITION:-sigeo-map-importer}"
SECRET_NAME="${DB_SECRET_NAME:-sigeo-map/db}"
LAMBDA_ROLE="sigeo-map-lambda"
LAMBDA_API="sigeo-map-control"
LAMBDA_SCHED="sigeo-map-scheduler"
API_NAME="sigeo-map-http"
SUBNET_CSV="${ECS_SUBNETS:?Set ECS_SUBNETS=subnet-aaa,subnet-bbb}"
SG_ID="${ECS_SECURITY_GROUPS:?Set ECS_SECURITY_GROUPS=sg-xxx}"
export ACCOUNT

ROOT="$(cd "$(dirname "$0")" && pwd)"
API_DIR="${API_DIR:-}"
if [[ -z "$API_DIR" ]]; then
  if [[ -f "${ROOT}/../api/package.json" ]]; then
    API_DIR="$(cd "${ROOT}/../api" && pwd)"
  elif [[ -f "${PWD}/api/package.json" ]]; then
    API_DIR="$(cd "${PWD}/api" && pwd)"
  fi
fi
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "== Account $ACCOUNT region $REGION =="
[[ -f "${API_DIR}/package.json" && -f "${API_DIR}/index.js" ]] || {
  echo "ERROR: set API_DIR to the api/ folder" >&2
  exit 1
}
echo "API_DIR=$API_DIR"

SECRET_ARN="$(aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" --query ARN --output text)"
EXEC_ROLE_ARN="$(aws iam get-role --role-name sigeo-map-ecs-execution --query Role.Arn --output text)"
TASK_ROLE_ARN="$(aws iam get-role --role-name sigeo-map-ecs-task --query Role.Arn --output text 2>/dev/null || echo "")"

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
if ! aws iam get-role --role-name "$LAMBDA_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$LAMBDA_ROLE" --assume-role-policy-document "$TRUST" >/dev/null
fi
aws iam attach-role-policy --role-name "$LAMBDA_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

PASS_RESOURCES="\"${EXEC_ROLE_ARN}\""
[[ -n "$TASK_ROLE_ARN" ]] && PASS_RESOURCES="\"${EXEC_ROLE_ARN}\", \"${TASK_ROLE_ARN}\""

aws iam put-role-policy --role-name "$LAMBDA_ROLE" --policy-name sigeo-map-lambda-inline \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {\"Effect\":\"Allow\",\"Action\":[\"secretsmanager:GetSecretValue\"],\"Resource\":[\"${SECRET_ARN}\",\"${SECRET_ARN}*\"]},
      {\"Effect\":\"Allow\",\"Action\":[\"ecs:RunTask\",\"ecs:StopTask\",\"ecs:DescribeTasks\",\"ecs:ListTasks\",\"ecs:TagResource\"],\"Resource\":\"*\"},
      {\"Effect\":\"Allow\",\"Action\":[\"iam:PassRole\"],\"Resource\":[${PASS_RESOURCES}]}
    ]
  }"

LAMBDA_ROLE_ARN="$(aws iam get-role --role-name "$LAMBDA_ROLE" --query Role.Arn --output text)"
sleep 8

echo "Building Lambda zip…"
mkdir -p "${BUILD_DIR}/pkg"
cp "${API_DIR}/package.json" "${BUILD_DIR}/pkg/"
[[ -f "${API_DIR}/package-lock.json" ]] && cp "${API_DIR}/package-lock.json" "${BUILD_DIR}/pkg/"
cp "${API_DIR}/index.js" "${BUILD_DIR}/pkg/"
cp -R "${API_DIR}/src" "${BUILD_DIR}/pkg/src"
(
  cd "${BUILD_DIR}/pkg"
  npm install --omit=dev --no-fund --no-audit
  zip -qr "${BUILD_DIR}/function.zip" index.js package.json src node_modules
)
ZIP="${BUILD_DIR}/function.zip"

ENV_FILE="${BUILD_DIR}/lambda-env.json"
SECRET_NAME="$SECRET_NAME" CLUSTER="$CLUSTER" TASK_DEF="$TASK_DEF" \
  SUBNET_CSV="$SUBNET_CSV" SG_ID="$SG_ID" \
  ENABLE_PLANETILER="${ENABLE_PLANETILER:-false}" \
  ENABLE_NOMINATIM="${ENABLE_NOMINATIM:-false}" \
  MBTILES_S3_BUCKET="${MBTILES_S3_BUCKET:-}" \
  NOMINATIM_PGHOST="${NOMINATIM_PGHOST:-}" \
  NOMINATIM_PGPASSWORD="${NOMINATIM_PGPASSWORD:-}" \
  python3 - "$ENV_FILE" <<'PY'
import json, os, sys
account = os.environ.get("ACCOUNT", "")
bucket = os.environ.get("MBTILES_S3_BUCKET") or (f"sigeo-map-{account}" if account else "")
env = {"Variables": {
  "IMPORT_BACKEND": "ecs",
  "DB_SECRET_NAME": os.environ["SECRET_NAME"],
  "ECS_CLUSTER": os.environ["CLUSTER"],
  "ECS_TASK_DEFINITION": os.environ["TASK_DEF"],
  "ECS_SUBNETS": os.environ["SUBNET_CSV"],
  "ECS_SECURITY_GROUPS": os.environ["SG_ID"],
  "ECS_ASSIGN_PUBLIC_IP": "ENABLED",
  "ECS_CONTAINER_NAME": "importer",
  "CACHE_MB": "1024",
  "DEFAULT_AREA": "monaco",
  "PGSSLMODE": "require",
  "ENABLE_OSM2PGSQL": "true",
  "ENABLE_PLANETILER": os.environ.get("ENABLE_PLANETILER", "false"),
  "ENABLE_NOMINATIM": os.environ.get("ENABLE_NOMINATIM", "false"),
  "MBTILES_S3_BUCKET": bucket,
  "MBTILES_S3_PREFIX": "mbtiles",
  "NOMINATIM_PGHOST": os.environ.get("NOMINATIM_PGHOST", ""),
  "NOMINATIM_PGUSER": "nominatim",
  "NOMINATIM_PGDATABASE": "nominatim",
  "NOMINATIM_PGPASSWORD": os.environ.get("NOMINATIM_PGPASSWORD", ""),
  "PLANETILER_JAVA_OPTS": "-Xmx4g",
}}
json.dump(env, open(sys.argv[1], "w"))
PY

create_or_update_lambda() {
  local name="$1" handler="$2"
  if aws lambda get-function --function-name "$name" --region "$REGION" >/dev/null 2>&1; then
    aws lambda update-function-code --function-name "$name" --region "$REGION" \
      --zip-file "fileb://${ZIP}" >/dev/null
    aws lambda wait function-updated --function-name "$name" --region "$REGION"
    aws lambda update-function-configuration --function-name "$name" --region "$REGION" \
      --runtime nodejs20.x --handler "$handler" --timeout 60 --memory-size 512 \
      --role "$LAMBDA_ROLE_ARN" --environment "file://${ENV_FILE}" >/dev/null
    aws lambda wait function-updated --function-name "$name" --region "$REGION"
    echo "Updated Lambda $name"
  else
    aws lambda create-function --function-name "$name" --region "$REGION" \
      --runtime nodejs20.x --handler "$handler" --role "$LAMBDA_ROLE_ARN" \
      --zip-file "fileb://${ZIP}" --timeout 60 --memory-size 512 \
      --environment "file://${ENV_FILE}" >/dev/null
    echo "Created Lambda $name"
  fi
}

create_or_update_lambda "$LAMBDA_API" "index.handler"
create_or_update_lambda "$LAMBDA_SCHED" "index.schedulerHandler"

API_ARN="$(aws lambda get-function --function-name "$LAMBDA_API" --region "$REGION" --query Configuration.FunctionArn --output text)"
SCHED_ARN="$(aws lambda get-function --function-name "$LAMBDA_SCHED" --region "$REGION" --query Configuration.FunctionArn --output text)"

API_ID="$(aws apigatewayv2 get-apis --region "$REGION" \
  --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text)"
if [[ -z "$API_ID" || "$API_ID" == "None" ]]; then
  API_ID="$(aws apigatewayv2 create-api --region "$REGION" --name "$API_NAME" \
    --protocol-type HTTP --cors-configuration '{
      "AllowOrigins":["*"],"AllowMethods":["GET","POST","PUT","OPTIONS","DELETE","PATCH","HEAD"],
      "AllowHeaders":["content-type","authorization","x-requested-with"],"MaxAge":300
    }' --query ApiId --output text)"
fi

# Always (re)apply CORS — Lambda responses do not set ACAO (avoids duplicate headers).
aws apigatewayv2 update-api --api-id "$API_ID" --region "$REGION" \
  --cors-configuration '{
    "AllowOrigins":["*"],
    "AllowMethods":["GET","POST","PUT","OPTIONS","DELETE","PATCH","HEAD"],
    "AllowHeaders":["content-type","authorization","x-requested-with"],
    "MaxAge":300
  }' >/dev/null

INTEGRATION_ID="$(aws apigatewayv2 get-integrations --api-id "$API_ID" --region "$REGION" \
  --query "Items[0].IntegrationId" --output text 2>/dev/null || true)"
if [[ -z "$INTEGRATION_ID" || "$INTEGRATION_ID" == "None" ]]; then
  INTEGRATION_ID="$(aws apigatewayv2 create-integration --api-id "$API_ID" --region "$REGION" \
    --integration-type AWS_PROXY --integration-uri "$API_ARN" \
    --payload-format-version 2.0 --query IntegrationId --output text)"
fi

EXISTING_ROUTE="$(aws apigatewayv2 get-routes --api-id "$API_ID" --region "$REGION" \
  --query "Items[?RouteKey=='ANY /{proxy+}'].RouteId | [0]" --output text)"
if [[ -z "$EXISTING_ROUTE" || "$EXISTING_ROUTE" == "None" ]]; then
  aws apigatewayv2 create-route --api-id "$API_ID" --region "$REGION" \
    --route-key 'ANY /{proxy+}' --target "integrations/${INTEGRATION_ID}" >/dev/null
  aws apigatewayv2 create-route --api-id "$API_ID" --region "$REGION" \
    --route-key 'ANY /' --target "integrations/${INTEGRATION_ID}" >/dev/null || true
fi

# Public OPTIONS so JWT on ANY /{proxy+} does not block browser preflight
for OPT_KEY in 'OPTIONS /{proxy+}' 'OPTIONS /'; do
  OPT_ID="$(aws apigatewayv2 get-routes --api-id "$API_ID" --region "$REGION" \
    --query "Items[?RouteKey=='${OPT_KEY}'].RouteId | [0]" --output text)"
  if [[ -z "$OPT_ID" || "$OPT_ID" == "None" ]]; then
    aws apigatewayv2 create-route --api-id "$API_ID" --region "$REGION" \
      --route-key "$OPT_KEY" --authorization-type NONE >/dev/null || true
  else
    aws apigatewayv2 update-route --api-id "$API_ID" --region "$REGION" \
      --route-id "$OPT_ID" --authorization-type NONE >/dev/null || true
  fi
done

# Keep health public
HEALTH_ID="$(aws apigatewayv2 get-routes --api-id "$API_ID" --region "$REGION" \
  --query "Items[?RouteKey=='GET /api/health'].RouteId | [0]" --output text)"
if [[ -z "$HEALTH_ID" || "$HEALTH_ID" == "None" ]]; then
  aws apigatewayv2 create-route --api-id "$API_ID" --region "$REGION" \
    --route-key 'GET /api/health' --target "integrations/${INTEGRATION_ID}" \
    --authorization-type NONE >/dev/null || true
else
  aws apigatewayv2 update-route --api-id "$API_ID" --region "$REGION" \
    --route-id "$HEALTH_ID" --authorization-type NONE >/dev/null || true
fi

STAGE="$(aws apigatewayv2 get-stages --api-id "$API_ID" --region "$REGION" \
  --query "Items[?StageName=='\$default'].StageName | [0]" --output text)"
if [[ -z "$STAGE" || "$STAGE" == "None" ]]; then
  aws apigatewayv2 create-stage --api-id "$API_ID" --region "$REGION" \
    --stage-name '$default' --auto-deploy >/dev/null
fi

aws lambda add-permission --function-name "$LAMBDA_API" --region "$REGION" \
  --statement-id apigw-invoke --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT}:${API_ID}/*" \
  2>/dev/null || true

API_ENDPOINT="$(aws apigatewayv2 get-api --api-id "$API_ID" --region "$REGION" --query ApiEndpoint --output text)"

RULE="sigeo-map-hourly"
aws events put-rule --region "$REGION" --name "$RULE" \
  --schedule-expression "rate(1 hour)" --state ENABLED >/dev/null
aws lambda add-permission --function-name "$LAMBDA_SCHED" --region "$REGION" \
  --statement-id events-hourly --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "arn:aws:events:${REGION}:${ACCOUNT}:rule/${RULE}" \
  2>/dev/null || true
aws events put-targets --region "$REGION" --rule "$RULE" --targets \
  "Id"="scheduler","Arn"="${SCHED_ARN}" >/dev/null

echo
echo "=== Deploy complete ==="
echo "API health: ${API_ENDPOINT}/api/health"
echo "UI: set window.SIGEO_MAP_API_BASE in ui/config.js then: npx --yes serve ui -p 8080"
