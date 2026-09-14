#!/usr/bin/env bash
# One-shot AWS setup: IAM roles, ECS cluster, Fargate task definition, security group.
# Requires: RDSHOST, existing Secrets Manager secret sigeo-map/db, ECR image pushed.
set -euo pipefail
export AWS_PAGER=""

REGION="${AWS_REGION:-eu-central-1}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
RDSHOST="${RDSHOST:?Set RDSHOST=your-rds-endpoint}"
SECRET_NAME="${SECRET_NAME:-sigeo-map/db}"
CLUSTER="${CLUSTER:-sigeo-map}"
TASK_FAMILY="${TASK_FAMILY:-sigeo-map-importer}"
IMAGE="${IMAGE:-${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/sigeo-map-importer:latest}"
EXEC_ROLE_NAME="sigeo-map-ecs-execution"
TASK_ROLE_NAME="sigeo-map-ecs-task"
LOG_GROUP="/ecs/sigeo-map-importer"
SG_NAME="sigeo-map-fargate"

echo "== Account $ACCOUNT region $REGION =="
SECRET_ARN="$(aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" --query ARN --output text)"

# --- Execution role (pull ECR + logs + secrets) ---
TRUST_ECS='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
if ! aws iam get-role --role-name "$EXEC_ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$EXEC_ROLE_NAME" --assume-role-policy-document "$TRUST_ECS" >/dev/null
fi
aws iam attach-role-policy --role-name "$EXEC_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
aws iam put-role-policy --role-name "$EXEC_ROLE_NAME" --policy-name sigeo-map-secrets \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"secretsmanager:GetSecretValue\"],\"Resource\":[\"${SECRET_ARN}\",\"${SECRET_ARN}*\"]}]}"

if ! aws iam get-role --role-name "$TASK_ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$TASK_ROLE_NAME" --assume-role-policy-document "$TRUST_ECS" >/dev/null
fi
aws iam put-role-policy --role-name "$TASK_ROLE_NAME" --policy-name sigeo-map-secrets \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"secretsmanager:GetSecretValue\"],\"Resource\":[\"${SECRET_ARN}\",\"${SECRET_ARN}*\"]}]}"

EXEC_ROLE_ARN="$(aws iam get-role --role-name "$EXEC_ROLE_NAME" --query Role.Arn --output text)"
TASK_ROLE_ARN="$(aws iam get-role --role-name "$TASK_ROLE_NAME" --query Role.Arn --output text)"

aws logs create-log-group --log-group-name "$LOG_GROUP" --region "$REGION" 2>/dev/null || true

if ! aws ecs describe-clusters --clusters "$CLUSTER" --region "$REGION" \
  --query "clusters[?status=='ACTIVE'].clusterName" --output text | grep -q "$CLUSTER"; then
  aws ecs create-cluster --cluster-name "$CLUSTER" --region "$REGION" >/dev/null
  echo "Created cluster $CLUSTER"
fi

# Discover VPC / RDS SG from RDSHOST
RDS_SG="$(aws rds describe-db-instances --region "$REGION" \
  --query "DBInstances[?Endpoint.Address=='${RDSHOST}'].VpcSecurityGroups[0].VpcSecurityGroupId" \
  --output text)"
VPC_ID="$(aws ec2 describe-security-groups --group-ids "$RDS_SG" --region "$REGION" \
  --query "SecurityGroups[0].VpcId" --output text)"

EXISTING_SG="$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query "SecurityGroups[0].GroupId" --output text)"
if [[ -z "$EXISTING_SG" || "$EXISTING_SG" == "None" ]]; then
  SG_ID="$(aws ec2 create-security-group --region "$REGION" \
    --group-name "$SG_NAME" --description "sigeo-map Fargate importer" \
    --vpc-id "$VPC_ID" --query GroupId --output text)"
  aws ec2 authorize-security-group-egress --region "$REGION" --group-id "$SG_ID" \
    --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' 2>/dev/null || true
else
  SG_ID="$EXISTING_SG"
fi

# Allow Fargate → RDS:5432
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$RDS_SG" \
  --protocol tcp --port 5432 --source-group "$SG_ID" 2>/dev/null || true

SUBNETS="$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query "Subnets[*].SubnetId" --output text | tr '\t' ',')"

# Resolve DB secret fields for task env (host/user/db); password via secret injection optional
# Task uses plaintext env from secret JSON resolved at register time for simplicity in lab:
SECRET_JSON="$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --region "$REGION" --query SecretString --output text)"
read -r PGUSER PGPASSWORD PGDATABASE < <(python3 -c 'import json,sys; s=json.load(sys.stdin); print(s["username"], s["password"], s.get("dbname","gis"))' <<<"$SECRET_JSON")

TASK_DEF="$(cat <<EOF
{
  "family": "${TASK_FAMILY}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "2048",
  "memory": "8192",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "taskRoleArn": "${TASK_ROLE_ARN}",
  "containerDefinitions": [{
    "name": "importer",
    "image": "${IMAGE}",
    "essential": true,
    "environment": [
      {"name": "PGHOST", "value": "${RDSHOST}"},
      {"name": "PGPORT", "value": "5432"},
      {"name": "PGDATABASE", "value": "${PGDATABASE}"},
      {"name": "PGUSER", "value": "${PGUSER}"},
      {"name": "PGPASSWORD", "value": "${PGPASSWORD}"},
      {"name": "PGSSLMODE", "value": "require"},
      {"name": "OSM_AREA", "value": "monaco"},
      {"name": "CACHE_MB", "value": "2048"}
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "${LOG_GROUP}",
        "awslogs-region": "${REGION}",
        "awslogs-stream-prefix": "importer"
      }
    }
  }]
}
EOF
)"

echo "$TASK_DEF" > /tmp/sigeo-map-task-def.json
aws ecs register-task-definition --region "$REGION" \
  --cli-input-json file:///tmp/sigeo-map-task-def.json >/dev/null

echo
echo "=== Setup complete ==="
echo "Cluster:          $CLUSTER"
echo "Task definition:  $TASK_FAMILY"
echo "Fargate SG:       $SG_ID"
echo "Suggested subnets:$SUBNETS"
echo
echo "Next:"
echo "  export ECS_SUBNETS=<pick-2-subnets>"
echo "  export ECS_SECURITY_GROUPS=$SG_ID"
echo "  ./aws/deploy-control.sh"
