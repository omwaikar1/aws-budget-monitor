import json
import os
import urllib.request
from datetime import date, timedelta

import boto3

ce_client = boto3.client("ce", region_name="us-east-1")
dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
state_table = dynamodb.Table("budget-monitor-state")


def get_month_to_date_spend():
    today = date.today()
    start_of_month = today.replace(day=1)
    # Cost Explorer's End date is EXCLUSIVE, so add a day to include today's spend.
    end_exclusive = today + timedelta(days=1)

    response = ce_client.get_cost_and_usage(
        TimePeriod={
            "Start": start_of_month.isoformat(),
            "End": end_exclusive.isoformat(),
        },
        Granularity="MONTHLY",
        Metrics=["UnblendedCost"],
    )

    amount_str = response["ResultsByTime"][0]["Total"]["UnblendedCost"]["Amount"]
    return float(amount_str)


def already_alerted_this_month(month_key):
    response = state_table.get_item(Key={"month": month_key})
    return response.get("Item", {}).get("alerted", False)


def mark_alerted(month_key):
    state_table.put_item(Item={"month": month_key, "alerted": True})


def post_to_slack(webhook_url, message):
    payload = json.dumps({"text": message}).encode("utf-8")
    req = urllib.request.Request(
        webhook_url,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req) as response:
        return response.status


def handler(event, context):
    budget = float(os.environ["MONTHLY_BUDGET_USD"])
    webhook_url = os.environ["SLACK_WEBHOOK_URL"]
    threshold_pct = float(os.environ.get("ALERT_THRESHOLD_PCT", "80"))

    spend = get_month_to_date_spend()
    pct_used = (spend / budget) * 100
    month_key = date.today().strftime("%Y-%m")

    print(f"Month-to-date spend: ${spend:.2f} / ${budget:.2f} budget ({pct_used:.1f}%)")

    alerted = False
    if pct_used >= threshold_pct:
        if already_alerted_this_month(month_key):
            print(f"Already alerted for {month_key}, skipping duplicate Slack message.")
        else:
            message = (
                f":warning: *AWS Budget Alert*\n"
                f"Month-to-date spend is *${spend:.2f}* — "
                f"*{pct_used:.1f}%* of your ${budget:.2f} monthly budget."
            )
            status = post_to_slack(webhook_url, message)
            mark_alerted(month_key)
            alerted = True
            print(f"Slack notified, status={status}")
    else:
        print("Under threshold, no alert sent.")

    return {
        "spend": spend,
        "budget": budget,
        "pct_used": round(pct_used, 1),
        "alerted": alerted,
    }
