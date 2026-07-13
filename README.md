# AWS Budget Monitor

A small serverless pipeline that checks AWS spend daily and posts a Slack alert once month-to-date spend crosses 80% of a configured budget.

## Architecture

```
EventBridge (daily cron, 13:00 UTC)
      │
      ▼
Lambda (budget-monitor)
      │  ce:GetCostAndUsage → month-to-date spend
      │  compare to MONTHLY_BUDGET_USD threshold
      │  DynamoDB (budget-monitor-state) → skip if already alerted this month
      ▼
Slack Incoming Webhook → alert message
```

## Services used

- **Lambda** — Python 3.12, single-file handler, no third-party dependencies (`boto3` ships with the runtime, `urllib` is stdlib).
- **EventBridge** — scheduled rule (`cron(0 13 * * ? *)`) invoking the Lambda daily.
- **IAM** — one execution role (`budget-monitor-lambda-role`) scoped to exactly `ce:GetCostAndUsage`, `dynamodb:GetItem`/`PutItem` on one table, and basic CloudWatch Logs write access.
- **Cost Explorer API** — source of month-to-date spend.
- **DynamoDB** — single-item-per-month dedup state (`budget-monitor-state`), on-demand billing, so alerts fire once per month rather than every day the threshold stays crossed.
- **Slack Incoming Webhook** — one-way alert delivery; no bot/OAuth needed since the flow is entirely one-directional.

## Setup

1. **AWS CLI configured** — `aws configure` with a CLI-scoped access key, region `us-east-1` (Cost Explorer's API only has an endpoint there).
2. **Slack webhook** — create via api.slack.com/apps → Incoming Webhooks → Add to Workspace.
3. **IAM role** — created via the policy files in [`iam/`](./iam/):
   ```
   aws iam create-role --role-name budget-monitor-lambda-role --assume-role-policy-document file://iam/trust-policy.json
   aws iam put-role-policy --role-name budget-monitor-lambda-role --policy-name cost-explorer-read --policy-document file://iam/cost-explorer-policy.json
   aws iam put-role-policy --role-name budget-monitor-lambda-role --policy-name dynamodb-state-access --policy-document file://iam/dynamodb-policy.json
   aws iam attach-role-policy --role-name budget-monitor-lambda-role --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
   ```
4. **DynamoDB table**:
   ```
   aws dynamodb create-table --table-name budget-monitor-state \
     --attribute-definitions AttributeName=month,AttributeType=S \
     --key-schema AttributeName=month,KeyType=HASH \
     --billing-mode PAY_PER_REQUEST
   ```
5. **Environment config** — copy your own `env.json` (git-ignored — never commit this, it holds your Slack webhook URL):
   ```json
   {
     "Variables": {
       "MONTHLY_BUDGET_USD": "20",
       "ALERT_THRESHOLD_PCT": "80",
       "SLACK_WEBHOOK_URL": "<your webhook url>"
     }
   }
   ```
6. **Deploy Lambda**:
   ```
   zip function.zip lambda_function.py
   aws lambda create-function --function-name budget-monitor \
     --runtime python3.12 --handler lambda_function.handler \
     --role arn:aws:iam::<account-id>:role/budget-monitor-lambda-role \
     --zip-file fileb://function.zip --timeout 30 --environment file://env.json
   ```
7. **EventBridge trigger**:
   ```
   aws events put-rule --name budget-monitor-daily --schedule-expression "cron(0 13 * * ? *)" --state ENABLED
   aws lambda add-permission --function-name budget-monitor --statement-id AllowEventBridgeInvoke \
     --action lambda:InvokeFunction --principal events.amazonaws.com \
     --source-arn arn:aws:events:us-east-1:<account-id>:rule/budget-monitor-daily
   aws events put-targets --rule budget-monitor-daily \
     --targets "Id"="budget-monitor-target","Arn"="arn:aws:lambda:us-east-1:<account-id>:function:budget-monitor"
   ```

To redeploy after editing `lambda_function.py`:
```
zip function.zip lambda_function.py
aws lambda update-function-code --function-name budget-monitor --zip-file fileb://function.zip
```

## Testing

```
./manual_test.sh
```

Runs a full smoke test: AWS auth, IAM role + policies, Lambda active state, EventBridge rule/target/permission, DynamoDB table config, a live Slack POST, and a real Lambda invoke. See the script output for pass/fail on each.

## Cost

Roughly $0.30/month, almost entirely from Cost Explorer API request charges (the one service in this stack not covered by AWS's always-free tier at this usage volume).
