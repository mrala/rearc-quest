#!/usr/bin/env bash
# One-time ADMIN bootstrap: creates the scoped IAM user that Terraform runs as.
# Run once with admin (or root) credentials, never as quest-deployer itself.
# Re-running updates the policy in place.
#
#   infra/aws/bootstrap/bootstrap.sh          create or update
#   infra/aws/bootstrap/bootstrap.sh destroy  remove the user and policy
set -euo pipefail

USER_NAME="quest-deployer"
POLICY_NAME="QuestDeployer"
SIGNIN_POLICY="arn:aws:iam::aws:policy/SignInLocalDevelopmentAccess"
HERE="$(cd "$(dirname "$0")" && pwd)"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
echo "account=${ACCOUNT_ID} caller=${CALLER_ARN}"

if [[ "${1:-}" == "destroy" ]]; then
  aws iam detach-user-policy --user-name "$USER_NAME" --policy-arn "$POLICY_ARN" 2>/dev/null || true
  aws iam detach-user-policy --user-name "$USER_NAME" --policy-arn "$SIGNIN_POLICY" 2>/dev/null || true
  aws iam delete-login-profile --user-name "$USER_NAME" 2>/dev/null || true
  aws iam delete-user --user-name "$USER_NAME" 2>/dev/null || true
  for v in $(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
      --query 'Versions[?!IsDefaultVersion].VersionId' --output text 2>/dev/null); do
    aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$v"
  done
  aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null || true
  echo "removed ${USER_NAME} and ${POLICY_NAME}"
  exit 0
fi

DOC="$(mktemp)"
trap 'rm -f "$DOC"' EXIT
sed "s/ACCOUNT_ID/${ACCOUNT_ID}/g" "$HERE/quest-deployer-policy.json" > "$DOC"

# Fail on any ERROR finding (warnings and suggestions are printed, not fatal).
FINDINGS="$(aws accessanalyzer validate-policy --policy-type IDENTITY_POLICY \
  --policy-document "file://$DOC" --query 'findings[].[findingType,issueCode,findingDetails]' --output text)"
[[ -n "$FINDINGS" ]] && echo "policy validation findings:" && echo "$FINDINGS"
if aws accessanalyzer validate-policy --policy-type IDENTITY_POLICY --policy-document "file://$DOC" \
    --query "findings[?findingType=='ERROR']" --output text | grep -q .; then
  echo "policy has ERROR findings; aborting" >&2; exit 1
fi

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  # A managed policy keeps at most 5 versions; drop old non-default ones first.
  for v in $(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
      --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$v"
  done
  aws iam create-policy-version --policy-arn "$POLICY_ARN" \
    --policy-document "file://$DOC" --set-as-default >/dev/null
  echo "updated policy ${POLICY_NAME}"
else
  aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "file://$DOC" \
    --tags Key=project,Value=quest >/dev/null
  echo "created policy ${POLICY_NAME}"
fi

if ! aws iam get-user --user-name "$USER_NAME" >/dev/null 2>&1; then
  aws iam create-user --user-name "$USER_NAME" --tags Key=project,Value=quest >/dev/null
  echo "created user ${USER_NAME}"
fi
aws iam attach-user-policy --user-name "$USER_NAME" --policy-arn "$POLICY_ARN"
aws iam attach-user-policy --user-name "$USER_NAME" --policy-arn "$SIGNIN_POLICY"

cat <<EOF

Next (manual, needs the console):
  1. IAM > Users > ${USER_NAME} > Security credentials: enable console access and set a password; add an MFA device.
  2. aws login --profile ${USER_NAME} --region us-east-1
       (sign in as an IAM user: account ID ${ACCOUNT_ID}, username ${USER_NAME})
  3. aws sts get-caller-identity --profile ${USER_NAME}   # expect .../user/${USER_NAME}
EOF
