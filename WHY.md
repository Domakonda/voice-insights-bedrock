# Why this project exists

A learning + portfolio project to demonstrate end-to-end design of a serverless AI pipeline on AWS, using Bedrock Data Automation for audio understanding.

## What it shows

- **Event-driven serverless design** — S3 notifications → SQS (with DLQs and partial-batch-failure handling) → Lambda fan-out.
- **Schema-first input validation** — Powertools Parser + Zod 4 schemas with multiple accepted shapes per Lambda (SQS-wrapped, direct, shorthand) so the same code is testable from console, CLI, and production triggers.
- **Bedrock Data Automation** — used as a managed multi-modal extraction service rather than rolling separate Transcribe + Comprehend + LLM steps. Lets the architecture stay tight.
- **Typed end-to-end** — TypeScript strict mode, composite project references, no `any` in the hot path. Zod schemas are the source of truth and types are inferred from them.
- **Tested at the unit level** — Vitest + `aws-sdk-client-mock` for every Lambda. Validation paths, success paths, and DLQ-eligible failure paths are all covered.
- **Real IaC** — Terraform for everything: buckets, queues, IAM, Lambdas, API Gateway HTTP API, log groups.

## Design decisions worth flagging

1. **Three small Lambdas, not one monolith.** Each handler has a single responsibility (submit, normalize, retrieve), separate IAM role with least privilege, and its own SQS+DLQ.
2. **DynamoDB over RDS.** Read pattern is `GetItem` by `jobId`. Pay-per-request keeps idle cost at zero — this is a demo, not a production transactional system.
3. **HTTP API (v2), not REST API (v1).** Cheaper, faster cold start, and the payload format v2 has cleaner Lambda integration.
4. **No custom shared "framework" package.** The shared module only owns Zod schemas, a logger factory, and tiny types. Anything more would be premature.
5. **Tests use `aws-sdk-client-mock`.** Mocks the SDK client directly instead of hand-rolled stubs — way less ceremony, fewer wrong assertions.
6. **Bundling with esbuild → zip, externalize `@aws-sdk/*`.** The runtime ships a recent SDK; bundling it would just bloat the deployment.

## What's intentionally not here (yet)

- Auth on the retrieval API (would add Cognito or a Lambda authorizer for v0.2)
- Pagination on retrieval (single-item lookup only)
- CloudWatch dashboards / alarms (would add for prod)
- A UI (CLI + curl is enough to demo the pipeline)

## What I'd build next

- v0.2: Cognito-secured API, simple React upload page on CloudFront, EventBridge notification when a transcript is ready.
- v0.3: Multi-language support, structured query (search by topic / sentiment) backed by OpenSearch.

## License

MIT. Built by [Aravind Domakonda](https://github.com/Domakonda).
