# Postman / Newman tests

End-to-end smoke tests for the deployed retrieval API. The collection is environment-driven so the same file works against `dev`, `staging`, or `prod` once you swap the environment.

## Files

| File | Purpose |
|------|---------|
| `voice-insights.postman_collection.json` | Four requests with chai-style assertions (200 happy path + three negative cases). |
| `voice-insights.postman_environment.json` | `apiBaseUrl`, `jobId`, and `inputBucket` for the `dev` deploy in `us-east-1`. |

## Run with Newman (CI / local)

From the repo root:

```bash
yarn install
yarn test:api
```

That is a shortcut for:

```bash
npx newman run postman/voice-insights.postman_collection.json \
  -e postman/voice-insights.postman_environment.json \
  --reporters cli
```

Newman exits non-zero on any failed assertion, so it drops straight into a CI gate.

## Run interactively in Postman

1. **File → Import** both JSON files.
2. In the top-right environment selector, pick **`voice-insights dev (us-east-1)`**.
3. Open the collection, click **Run** to execute all four requests, or hit **Send** on any single one.

## Covered scenarios

| # | Request | Expected | Why it matters |
|---|---------|----------|----------------|
| 1 | `GET /transcripts/{jobId}` (known id) | `200` + canonical body | Happy path. Verifies BDA → DynamoDB → API plumbing end-to-end. |
| 2 | `GET /transcripts/{unknown}` | `404 not_found` | Confirms the retrieval Lambda distinguishes missing-record from server error. |
| 3 | `GET /transcripts/` (empty id) | `400 bad_request` | Confirms Zod input validation fires before DynamoDB is touched. |
| 4 | `POST /transcripts/{jobId}` | `4xx` | Confirms only `GET` is wired on the route. |

Assertion #1 also checks all canonical fields (`jobId`, `transcript`, `durationMs`, `language`, `segments`, `topics`, `actionItems`, `createdAt`) and validates monotonic `segments[].startMs` ordering.

## Point the collection at a different deploy

Edit `voice-insights.postman_environment.json` and replace `apiBaseUrl` + `jobId`:

```bash
API=$(terraform -chdir=../terraform output -raw api_endpoint)
echo "Set apiBaseUrl to: $API"

# Pick any seeded jobId from CloudWatch:
aws logs tail /aws/lambda/voice-insights-dev-submission \
  --since 1h --filter-pattern 'BDA invocation submitted'
```

## Seed a fresh `jobId`

If no transcripts are in the table yet:

```bash
INPUT=$(terraform -chdir=../terraform output -raw input_bucket)
aws s3 cp ./samples/hello.wav s3://$INPUT/samples/hello.wav
# wait ~30–60s, then pull the jobId from CloudWatch as above
```
