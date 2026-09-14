#!/usr/bin/env bash
# Attach Cognito JWT authorizer to sigeo-map-http API Gateway routes.
# Run in CloudShell in the API account (663505294123), region eu-south-1.
#
# Cognito may live in another account; JWT only needs pool id + client id + region.
#
# Usage:
#   export USER_POOL_ID=eu-south-1_XXXXXXXX
#   export CLIENT_ID=xxxxxxxxxxxxxxxxxxxxxxxxxx
#   # optional if Cognito region differs:
#   # export COGNITO_REGION=eu-south-1
#   ./aws/attach-cognito-authorizer.sh
set -euo pipefail
export AWS_PAGER=""

REGION="${AWS_REGION:-eu-south-1}"
COGNITO_REGION="${COGNITO_REGION:-$REGION}"
API_NAME="${API_NAME:-sigeo-map-http}"
USER_POOL_ID="${USER_POOL_ID:?Set USER_POOL_ID from Amplify / amplify_outputs.json auth.user_pool_id}"
CLIENT_ID="${CLIENT_ID:?Set CLIENT_ID from Amplify / amplify_outputs.json auth.user_pool_client_id}"
ISSUER="https://cognito-idp.${COGNITO_REGION}.amazonaws.com/${USER_POOL_ID}"

API_ID="$(aws apigatewayv2 get-apis --region "$REGION" \
  --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text)"
if [[ -z "$API_ID" || "$API_ID" == "None" ]]; then
  echo "ERROR: HTTP API named $API_NAME not found. Deploy control API first." >&2
  exit 1
fi
echo "API_ID=$API_ID"
echo "Issuer=$ISSUER"
echo "Audience=$CLIENT_ID"

# Ensure API-level CORS (needed so 401 from JWT still has ACAO headers in the browser)
aws apigatewayv2 update-api --api-id "$API_ID" --region "$REGION" \
  --cors-configuration '{
    "AllowOrigins":["*"],
    "AllowMethods":["GET","POST","PUT","OPTIONS","DELETE","PATCH","HEAD"],
    "AllowHeaders":["content-type","authorization","x-requested-with"],
    "MaxAge":300
  }' >/dev/null
echo "Updated API CORS"

EXISTING="$(aws apigatewayv2 get-authorizers --api-id "$API_ID" --region "$REGION" \
  --query "Items[?Name=='cognito-jwt'].AuthorizerId | [0]" --output text)"
if [[ -n "$EXISTING" && "$EXISTING" != "None" ]]; then
  AUTH_ID="$EXISTING"
  aws apigatewayv2 update-authorizer \
    --api-id "$API_ID" --region "$REGION" \
    --authorizer-id "$AUTH_ID" \
    --identity-source '$request.header.Authorization' \
    --jwt-configuration "Audience=${CLIENT_ID},Issuer=${ISSUER}" >/dev/null
  echo "Updated authorizer $AUTH_ID"
else
  AUTH_ID="$(aws apigatewayv2 create-authorizer \
    --api-id "$API_ID" --region "$REGION" \
    --name cognito-jwt \
    --authorizer-type JWT \
    --identity-source '$request.header.Authorization' \
    --jwt-configuration "Audience=${CLIENT_ID},Issuer=${ISSUER}" \
    --query AuthorizerId --output text)"
  echo "Created authorizer $AUTH_ID"
fi

INTEGRATION_ID="$(aws apigatewayv2 get-integrations --api-id "$API_ID" --region "$REGION" \
  --query "Items[0].IntegrationId" --output text)"

# Lock catch-all proxy routes
for ROUTE_KEY in 'ANY /{proxy+}' 'ANY /'; do
  ROUTE_ID="$(aws apigatewayv2 get-routes --api-id "$API_ID" --region "$REGION" \
    --query "Items[?RouteKey=='${ROUTE_KEY}'].RouteId | [0]" --output text)"
  if [[ -z "$ROUTE_ID" || "$ROUTE_ID" == "None" ]]; then
    echo "Skip missing route $ROUTE_KEY"
    continue
  fi
  aws apigatewayv2 update-route --api-id "$API_ID" --region "$REGION" \
    --route-id "$ROUTE_ID" \
    --authorization-type JWT \
    --authorizer-id "$AUTH_ID" >/dev/null
  echo "JWT required on $ROUTE_KEY"
done

# Public OPTIONS so browser preflight is not blocked by JWT (ANY /{proxy+} would catch it)
ensure_public_route() {
  local ROUTE_KEY="$1"
  local TARGET="${2:-}"
  local ROUTE_ID
  ROUTE_ID="$(aws apigatewayv2 get-routes --api-id "$API_ID" --region "$REGION" \
    --query "Items[?RouteKey=='${ROUTE_KEY}'].RouteId | [0]" --output text)"
  if [[ -z "$ROUTE_ID" || "$ROUTE_ID" == "None" ]]; then
    local ARGS=(--api-id "$API_ID" --region "$REGION" --route-key "$ROUTE_KEY" --authorization-type NONE)
    if [[ -n "$TARGET" ]]; then
      ARGS+=(--target "$TARGET")
    fi
    aws apigatewayv2 create-route "${ARGS[@]}" >/dev/null
    echo "Created public $ROUTE_KEY"
  else
    aws apigatewayv2 update-route --api-id "$API_ID" --region "$REGION" \
      --route-id "$ROUTE_ID" \
      --authorization-type NONE >/dev/null
    echo "Public $ROUTE_KEY"
  fi
}

# For HTTP API with CORS configured, OPTIONS can be a no-integration route;
# still create explicit public OPTIONS so JWT on ANY does not block preflight.
ensure_public_route 'OPTIONS /{proxy+}'
ensure_public_route 'OPTIONS /'
ensure_public_route 'GET /api/health' "integrations/${INTEGRATION_ID}"

echo
echo "Done. Unauthenticated calls to /api/* (except health) should return 401."
echo "Amplify UI already sends Authorization: Bearer <idToken>."
echo
echo "Quick checks:"
echo "  curl -sS -o /dev/null -w '%{http_code}\n' -X OPTIONS https://lfvy5sv7gj.execute-api.${REGION}.amazonaws.com/api/areas -H 'Origin: https://example.amplifyapp.com' -H 'Access-Control-Request-Method: GET'"
echo "  curl -sS -o /dev/null -w '%{http_code}\n' https://lfvy5sv7gj.execute-api.${REGION}.amazonaws.com/api/health"
echo "  curl -sS -o /dev/null -w '%{http_code}\n' https://lfvy5sv7gj.execute-api.${REGION}.amazonaws.com/api/areas"
