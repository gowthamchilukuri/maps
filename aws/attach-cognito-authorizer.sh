#!/usr/bin/env bash
# Attach Cognito JWT authorizer to sigeo-map-http API Gateway routes.
# Run after: npx ampx sandbox --once (in ui/) and ./aws/deploy-control.sh
set -euo pipefail
export AWS_PAGER=""

REGION="${AWS_REGION:-eu-central-1}"
API_NAME="${API_NAME:-sigeo-map-http}"
USER_POOL_ID="${USER_POOL_ID:?Set USER_POOL_ID from amplify_outputs.json auth.user_pool_id}"
CLIENT_ID="${CLIENT_ID:?Set CLIENT_ID from amplify_outputs.json auth.user_pool_client_id}"

API_ID="$(aws apigatewayv2 get-apis --region "$REGION" \
  --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text)"
if [[ -z "$API_ID" || "$API_ID" == "None" ]]; then
  echo "ERROR: HTTP API named $API_NAME not found. Deploy control API first." >&2
  exit 1
fi
echo "API_ID=$API_ID"

EXISTING="$(aws apigatewayv2 get-authorizers --api-id "$API_ID" --region "$REGION" \
  --query "Items[?Name=='cognito-jwt'].AuthorizerId | [0]" --output text)"
if [[ -n "$EXISTING" && "$EXISTING" != "None" ]]; then
  AUTH_ID="$EXISTING"
  echo "Using existing authorizer $AUTH_ID"
else
  AUTH_ID="$(aws apigatewayv2 create-authorizer \
    --api-id "$API_ID" --region "$REGION" \
    --name cognito-jwt \
    --authorizer-type JWT \
    --identity-source '$request.header.Authorization' \
    --jwt-configuration "Audience=${CLIENT_ID},Issuer=https://cognito-idp.${REGION}.amazonaws.com/${USER_POOL_ID}" \
    --query AuthorizerId --output text)"
  echo "Created authorizer $AUTH_ID"
fi

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

echo
echo "Done. Unauthenticated curl to the API should now fail; Amplify UI sends Bearer idToken."
echo "Optional: leave GET /api/health public by creating a separate route without the authorizer."
