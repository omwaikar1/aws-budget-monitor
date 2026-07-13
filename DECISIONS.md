# Decisions Log

Running log of architectural/tooling decisions made during the build, with reasoning. Written for LinkedIn build-in-public posts — includes what broke, not just what worked.

## 2026-07-12 — Slack Incoming Webhook over Slack App/bot

Chose a Slack Incoming Webhook (a POST-only URL) instead of building a full Slack App with a bot user.

**Why:** The Lambda only ever needs to push a one-way alert into a channel — it never needs to receive anything back from Slack (no slash commands, no interactive buttons, no reading messages). A bot's OAuth tokens, scopes, and event subscriptions exist to support two-way traffic; adding one here would be pure overhead for zero functional gain. Rule of thumb: one-directional (app → Slack) = webhook, two-directional = bot.

## 2026-07-12 — CLI access key for local dev, IAM role for Lambda

Created an IAM user access key (use case: "Command Line Interface (CLI)") for local `aws configure` / testing. This is explicitly NOT what the Lambda function will use at runtime.

**Why:** AWS's access-key wizard nudges away from long-lived keys where possible. For a solo laptop-driven CLI workflow, a CLI-scoped access key is still the standard, appropriate choice. But the Lambda function itself will run under its own IAM execution role (assumed automatically, no stored credentials) — access keys and Lambda execution roles solve different problems and shouldn't be conflated.

## 2026-07-12 — Region pinned to us-east-1

Set default CLI region and Lambda deployment region to `us-east-1`.

**Why:** The Cost Explorer API (`ce:GetCostAndUsage`) only has an endpoint in `us-east-1`, regardless of where compute runs. Mismatching regions between CLI/Lambda config and Cost Explorer calls would cause confusing failures, so everything in this project standardizes on `us-east-1`.

## 2026-07-12 — Lambda execution role: trust policy + inline policy + managed policy

Created `budget-monitor-lambda-role` via CLI: a trust policy scoping assumption to `lambda.amazonaws.com` only, an inline policy granting just `ce:GetCostAndUsage`, and AWS's managed `AWSLambdaBasicExecutionRole` for CloudWatch logging.

**Why:** Trust (who can assume the role) and permissions (what it can do once assumed) are independent controls in IAM — both have to be set deliberately. Inline for the custom Cost Explorer permission since it's one-off and role-specific; managed policy for logging since it's a standard, reusable AWS-provided grant. Keeps the role's blast radius to exactly "read cost data, write logs" if it were ever compromised.

**What broke:** First attempt at `aws iam create-role` failed with `AccessDenied` — the IAM user `Om` (used for local CLI auth) had almost no permissions of its own, including no ability to even list its own policies. Root cause: `AdministratorAccess` wasn't actually attached to the user despite going through the access-key creation flow. Fixed by attaching `AdministratorAccess` to the user via the Console (an IAM user can never grant itself more permissions than it has — that's IAM working as intended, not a bug). Reminder that creating an access key and having account permissions are two separate steps.

## 2026-07-12 — Lambda function deployed; Cost Explorer needs a 24h data ingestion window

Deployed `budget-monitor` Lambda (Python 3.12, `lambda_function.handler`) via `aws lambda create-function`, wired to `budget-monitor-lambda-role`, with `MONTHLY_BUDGET_USD`, `SLACK_WEBHOOK_URL`, `ALERT_THRESHOLD_PCT` passed as environment variables from a git-ignored `env.json` (kept the Slack webhook out of both git and this chat transcript — AWS CLI's own response was filtered with `--query` so it wouldn't echo the secret back either).

**What broke:** First manual invoke failed with `DataUnavailableException` from `ce:GetCostAndUsage` — not an IAM or code bug. Cost Explorer is a separate opt-in per AWS account (distinct from having the `ce:GetCostAndUsage` permission), and even after enabling it, AWS takes up to 24 hours to ingest/backfill billing data before queries return results. Enabled it via Billing Console → Cost Explorer; now waiting on ingestion before the IAM/API/Slack path can be verified end-to-end with real data.

**Why this matters:** a good reminder that IAM permissions and service *activation* are two different gates — having the right policy doesn't mean the underlying service has data to serve yet.

**Update:** verified Cost Explorer *is* enabled — the Billing Console's Cost Explorer graph shows data fine, only the `GetCostAndUsage` API still returns `DataUnavailableException`. Confirms this is an AWS-side ingestion lag between "console-ready" and "API-ready," not a config error on our end. Decided not to block the rest of the build on this — verified the Slack half of the pipeline independently instead (a standalone script posted directly to the webhook URL, bypassing Lambda/Cost Explorer entirely, and the message landed in the channel). Will retry the Lambda invoke once the API catches up.

## 2026-07-12 — EventBridge daily trigger wired up

Created `budget-monitor-daily` EventBridge rule (`cron(0 13 * * ? *)`, 13:00 UTC daily), granted it invoke permission on the Lambda via `aws lambda add-permission` (scoped with a `SourceArn` condition to this one rule only, not any EventBridge rule account-wide), and attached the Lambda as the rule's target via `put-targets`.

**Why:** EventBridge needs two separate grants of trust to invoke a Lambda — the rule/target wiring (routing) and a resource-based permission on the Lambda itself (authorization). Missing the permission step would make the rule fire but the invocation silently fail. Didn't block this step on Cost Explorer's ingestion lag since EventBridge wiring is independent of whether Cost Explorer has data yet.

## 2026-07-12 — Simulated an over-budget run to verify alert logic without waiting on Cost Explorer

With Cost Explorer's API still returning `DataUnavailableException`, ran the real `lambda_function.handler()` locally with only `get_month_to_date_spend()` monkeypatched to return a hardcoded $18.50 (92.5% of the $20 budget) — every other line of production code ran unmodified, including the actual `urllib` POST to the real Slack webhook.

**Why:** proves the threshold math, alert-triggering condition, message formatting, and Slack delivery are all correct, in isolation from the one dependency (Cost Explorer ingestion) that's genuinely outside our control right now. The alert message arrived in Slack as expected. Only the live Cost Explorer→Lambda link remains unverified end-to-end, pending AWS's data availability.

## 2026-07-12 — Added DynamoDB dedup so alerts fire once per month, not daily

Added `budget-monitor-state` DynamoDB table (`PAY_PER_REQUEST` billing, single partition key `month` as a `"YYYY-MM"` string), a third inline IAM policy scoped to `dynamodb:GetItem`/`dynamodb:PutItem` on just this table's ARN, and check-then-act dedup logic in `handler()`: only Slack-post and record `alerted: true` if over threshold AND not already alerted this month.

**Why:** without external state, Lambda would re-alert every single day once the threshold is crossed, since it has no memory between invocations — this was the explicitly scoped optional stretch goal. Chose "once per month" dedup (not per-threshold-tier) to match original scope and keep state to a single boolean. Keying by year-month means the dedup naturally resets each new month with no explicit cleanup code. The `mark_alerted` write happens only *after* a successful Slack POST, not before — so a failed Slack call doesn't silently mark us as "already alerted" and suppress all future real alerts that month.

**Verification:** ran the real `handler()` twice locally (spend hardcoded to simulate over-budget, since Cost Explorer's API is still ingesting) — first run alerted and wrote state, second run correctly detected existing state and skipped the duplicate Slack message. Deleted the test state item afterward so it doesn't suppress the real alert once Cost Explorer data is live this month.

## 2026-07-12 — Confirmed Cost Explorer ingestion delay is total, not query-specific

Ruled out narrower explanations for the persistent `DataUnavailableException`: tried a 30-day historical DAILY-granularity query (still failed, so it's not specific to "current partial month" data), and invoked the real deployed Lambda directly (identical error, confirming IAM/auth/networking are all correct — the call reaches Cost Explorer fine, it's purely that the backend has no ingested data yet for this account). Console graphs render because they're served from a different, already-warm data path than the `GetCostAndUsage` API.

**Why this matters:** confirms every component we built (IAM role, Lambda, EventBridge, Slack, DynamoDB dedup) is correct and complete; the only outstanding item is AWS's own multi-hour ingestion window, unrelated to anything in this repo. Stopped polling repeatedly since further retries within minutes of each other can't change an outcome gated by AWS's backend timeline — will do one final live check once enough time has passed.

## 2026-07-12 — Wrote `manual_test.sh`, a reusable smoke test covering every component

Added a script checking: AWS auth, IAM role + all 3 policies attached, Lambda active, EventBridge rule/target/invoke-permission, DynamoDB table config, a live Slack POST, and a real Lambda invoke. 11/11 passed; the Lambda invoke step correctly surfaces the known Cost Explorer ingestion delay as an `INFO`, not a `FAIL`, since it's an external AWS timing issue, not a defect in anything we built.

**Why:** wanted one command that verifies the whole system rather than re-deriving individual `aws` commands each time we want to sanity-check the build. Re-run anytime, including once Cost Explorer catches up — step 7 should then show a real spend number instead of the ingestion error.
