import boto3, json

client = boto3.client("bedrock-agentcore", region_name="us-east-1")
response = client.invoke_agent_runtime(
    agentRuntimeArn="arn:aws:bedrock-agentcore:us-east-1:339712707840:runtime/llm_router_dev_router-shG00WEkcb",
    payload=json.dumps({"prompt": "hello"}).encode("utf-8"),
    contentType="application/json"
)
print(response)
