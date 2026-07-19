#!/usr/bin/env python3
"""
View routing audit log records in human-readable format.
Usage:
  python3 scripts/view-audit-log.py              # Show last 5 records
  python3 scripts/view-audit-log.py 10           # Show last 10 records
  python3 scripts/view-audit-log.py --full       # Show all fields
"""

import sys
import json
import boto3
from datetime import datetime

REGION = "us-east-1"
TABLE_NAME = "llm-router-dev-routing-audit-log"

dynamodb = boto3.resource("dynamodb", region_name=REGION)
table = dynamodb.Table(TABLE_NAME)


def main():
    limit = 5
    full = False

    for arg in sys.argv[1:]:
        if arg == "--full":
            full = True
        elif arg.isdigit():
            limit = int(arg)

    print(f"Scanning {TABLE_NAME} (last {limit} records)...\n")

    response = table.scan(Limit=limit)
    items = response.get("Items", [])

    if not items:
        print("No records found.")
        return

    # Sort by timestamp descending
    items.sort(key=lambda x: x.get("timestamp", 0), reverse=True)

    for i, item in enumerate(items):
        ts = item.get("timestamp", 0)
        dt = datetime.fromtimestamp(int(ts)).strftime("%Y-%m-%d %H:%M:%S") if ts else "unknown"

        print(f"{'='*60}")
        print(f"  Record {i+1}")
        print(f"{'='*60}")
        print(f"  Request ID:   {item.get('request_id', 'N/A')}")
        print(f"  Timestamp:    {dt}")
        print(f"  User ID:      {item.get('user_id', 'N/A')}")
        print(f"  Session:      {item.get('session_id', 'N/A')}")
        print()
        print(f"  --- What ---")
        print(f"  Model:        {item.get('model_id', 'N/A')}")
        print(f"  Provider:     {item.get('provider', 'N/A')}")
        print(f"  Prompt Hash:  {item.get('prompt_hash', 'N/A')}")
        print(f"  Prompt Len:   {item.get('prompt_length', 'N/A')} chars")
        print(f"  In Tokens:    {item.get('input_tokens', 'N/A')}")
        print(f"  Out Tokens:   {item.get('output_tokens', 'N/A')}")
        print()
        print(f"  --- Why ---")
        print(f"  Complexity:   {item.get('complexity', 'N/A')}")
        print(f"  Classified By:{item.get('classification_method', 'N/A')}")
        print(f"  Policy:       {item.get('policy_id', 'N/A')}")
        candidates = item.get("candidates_considered", [])
        print(f"  Candidates:   {', '.join(candidates) if candidates else 'N/A'}")
        print()
        print(f"  --- How ---")
        print(f"  Strategy:     {item.get('routing_strategy', 'N/A')}")
        print(f"  Async:        {item.get('is_async', False)}")
        print(f"  Escalated:    {item.get('escalated', False)}")
        print(f"  Latency:      {item.get('latency_ms', 'N/A')}ms")
        print(f"  Est. Cost:    ${item.get('estimated_cost', 'N/A')}")
        print()
        print(f"  --- Where ---")
        print(f"  Residency:    {item.get('data_residency', 'N/A')}")
        print(f"  External:     {item.get('external_provider', False)}")
        print(f"  PII Detected: {item.get('pii_detected', False)}")

        provenance = item.get("model_provenance", {})
        if provenance:
            print()
            print(f"  --- Model Provenance ---")
            print(f"  Provider:     {provenance.get('provider_name', 'N/A')}")
            print(f"  Family:       {provenance.get('model_family', 'N/A')}")
            print(f"  Profile:      {provenance.get('inference_profile', 'N/A')}")
            print(f"  Retention:    {provenance.get('data_retention', 'N/A')}")

        if full:
            scores = item.get("model_scores", {})
            if scores:
                print()
                print(f"  --- Model Scores ---")
                for model, score in scores.items():
                    print(f"    {model}: {score}")

            config_state = item.get("appconfig_state", {})
            if config_state:
                print()
                print(f"  --- AppConfig State ---")
                print(f"    System Active:  {config_state.get('system_active', 'N/A')}")
                print(f"    Model Enabled:  {config_state.get('model_enabled', 'N/A')}")

        print()

    print(f"Total: {len(items)} records shown")
    print(f"Tip: Use --full for all fields, or pass a number for more records")


if __name__ == "__main__":
    main()
