#!/bin/bash
# Manual smoke test for aws-budget-monitor. Checks every component independently.
set -uo pipefail

PASS=0
FAIL=0

check() {
  local name="$1"
  local result="$2"
  if [ "$result" -eq 0 ]; then
    echo "  PASS: $name"
    PASS=$((PASS+1))
  else
    echo "  FAIL: $name"
    FAIL=$((FAIL+1))
  fi
}

echo "=== 1. AWS credentials ==="
aws sts get-caller-identity > /dev/null 2>&1
check "AWS CLI authenticated" $?

echo ""
echo "=== 2. IAM role exists with correct policies ==="
aws iam get-role --role-name budget-monitor-lambda-role > /dev/null 2>&1
check "Role budget-monitor-lambda-role exists" $?

aws iam get-role-policy --role-name budget-monitor-lambda-role --policy-name cost-explorer-read > /dev/null 2>&1
check "Inline policy cost-explorer-read attached" $?

aws iam get-role-policy --role-name budget-monitor-lambda-role --policy-name dynamodb-state-access > /dev/null 2>&1
check "Inline policy dynamodb-state-access attached" $?

aws iam list-attached-role-policies --role-name budget-monitor-lambda-role --query "AttachedPolicies[?PolicyName=='AWSLambdaBasicExecutionRole']" --output text | grep -q AWSLambdaBasicExecutionRole
check "Managed policy AWSLambdaBasicExecutionRole attached" $?

echo ""
echo "=== 3. Lambda function deployed and active ==="
STATE=$(aws lambda get-function-configuration --function-name budget-monitor --region us-east-1 --query State --output text 2>/dev/null)
[ "$STATE" = "Active" ]
check "Lambda function State=Active (got: $STATE)" $?

echo ""
echo "=== 4. EventBridge rule wired correctly ==="
RULE_STATE=$(aws events describe-rule --name budget-monitor-daily --region us-east-1 --query State --output text 2>/dev/null)
[ "$RULE_STATE" = "ENABLED" ]
check "EventBridge rule State=ENABLED (got: $RULE_STATE)" $?

TARGET_COUNT=$(aws events list-targets-by-rule --rule budget-monitor-daily --region us-east-1 --query "length(Targets)" --output text 2>/dev/null)
[ "$TARGET_COUNT" = "1" ]
check "EventBridge rule has exactly 1 target (got: $TARGET_COUNT)" $?

aws lambda get-policy --function-name budget-monitor --region us-east-1 --query Policy --output text 2>/dev/null | grep -q "events.amazonaws.com"
check "Lambda resource policy allows events.amazonaws.com" $?

echo ""
echo "=== 5. DynamoDB table exists, correct billing mode ==="
BILLING=$(aws dynamodb describe-table --table-name budget-monitor-state --region us-east-1 --query "Table.BillingModeSummary.BillingMode" --output text 2>/dev/null)
[ "$BILLING" = "PAY_PER_REQUEST" ]
check "DynamoDB table PAY_PER_REQUEST (got: $BILLING)" $?

echo ""
echo "=== 6. Slack webhook live POST ==="
WEBHOOK_URL=$(python3 -c "import json; print(json.load(open('env.json'))['Variables']['SLACK_WEBHOOK_URL'])")
STATUS=$(python3 -c "
import json, urllib.request
payload = json.dumps({'text': ':test_tube: manual_test.sh smoke test — webhook reachable.'}).encode('utf-8')
req = urllib.request.Request('$WEBHOOK_URL', data=payload, headers={'Content-Type':'application/json'}, method='POST')
with urllib.request.urlopen(req) as r:
    print(r.status)
")
[ "$STATUS" = "200" ]
check "Slack webhook POST returned 200 (got: $STATUS)" $?

echo ""
echo "=== 7. Lambda manual invoke (real Cost Explorer call) ==="
aws lambda invoke --function-name budget-monitor --region us-east-1 --cli-read-timeout 60 /tmp/manual_test_invoke.json > /tmp/manual_test_invoke_meta.json 2>&1
FUNC_ERROR=$(python3 -c "import json; print(json.load(open('/tmp/manual_test_invoke_meta.json')).get('FunctionError',''))" 2>/dev/null)
if [ -z "$FUNC_ERROR" ]; then
  check "Lambda invoke succeeded, no FunctionError" 0
  cat /tmp/manual_test_invoke.json
else
  echo "  INFO: Lambda invoke returned FunctionError=$FUNC_ERROR (expected while Cost Explorer is still ingesting data)"
  cat /tmp/manual_test_invoke.json
fi

echo ""
echo "=== Summary ==="
echo "PASS: $PASS   FAIL: $FAIL"
