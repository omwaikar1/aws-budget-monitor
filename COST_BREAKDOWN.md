# Cost Breakdown

Estimated monthly cost of running this project itself (separate from whatever spend it's monitoring), based on 1 EventBridge-triggered Lambda invocation per day (~30/month).

| Service | Usage this project generates | Free tier | Estimated monthly cost |
|---|---|---|---|
| **Lambda** | ~30 invocations/month, 128MB memory, sub-second execution | 1M requests + 400,000 GB-seconds/month, always free | $0.00 |
| **EventBridge** (scheduled rule) | 1 rule, ~30 invocations/month, default event bus | Rule invocations to a Lambda target on the default bus are not separately billed | $0.00 |
| **Cost Explorer API** (`ce:GetCostAndUsage`) | ~30 API calls/month | **Not covered by a free tier** — Cost Explorer's *console* is free, but the API is billed per request | ~$0.30 (30 × $0.01/request) |
| **DynamoDB** (`budget-monitor-state`, on-demand) | ~30 GetItem + up to a few PutItem calls/month, <1KB item | 2.5M read request units + 1M write request units/month, always free | $0.00 |
| **CloudWatch Logs** | A few log lines per invocation | 5GB ingestion + storage/month, always free | $0.00 |
| **IAM** (roles, policies) | N/A | Always free | $0.00 |
| **Total** | | | **~$0.30/month** |

## Notes

- The **only line item with a real, non-free cost is the Cost Explorer API itself** — a detail that's easy to miss since the Cost Explorer *console* (the graphs you look at in the Billing dashboard) is free, but programmatic `GetCostAndUsage` calls are billed at $0.01/request regardless of account size. At one call/day this is ~$0.30/month; it would scale directly with how often the schedule fires (e.g. hourly instead of daily would be ~24x that).
- Every other service in this architecture — Lambda, EventBridge, DynamoDB at this volume, CloudWatch Logs, IAM — falls entirely within AWS's *always-free* tier (not a 12-month trial tier; these limits don't expire), so this project effectively costs about the price of a Cost Explorer API call per day, indefinitely.
- This estimate is for **running the monitor**, separate from whatever AWS spend it's actually watching — i.e., this is the cost of the alarm system, not the cost of the thing it alarms about.
