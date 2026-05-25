import { randomUUID } from 'node:crypto';
import type { InvokeDataAutomationAsyncCommandInput } from '@aws-sdk/client-bedrock-data-automation-runtime';
import type { Env } from './app.env.js';
import type { SubmissionTrigger } from './app.schema.js';

export function buildJobId(key: string): string {
  // Bedrock InvokeDataAutomationAsync clientToken pattern: [a-zA-Z0-9](-*[a-zA-Z0-9]){1,256}
  // — only alphanumerics and hyphens, must start with alphanumeric, no runs of hyphens.
  const base = key
    .replace(/[^a-zA-Z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 80);
  return `${base || 'job'}-${randomUUID()}`;
}

export function buildInvokeParams(
  env: Env,
  trigger: SubmissionTrigger,
  jobId: string
): InvokeDataAutomationAsyncCommandInput {
  return {
    inputConfiguration: {
      s3Uri: `s3://${trigger.bucket}/${trigger.key}`,
    },
    outputConfiguration: {
      s3Uri: `s3://${env.OUTPUT_BUCKET}/${env.OUTPUT_PREFIX}/${jobId}/`,
    },
    dataAutomationConfiguration: {
      dataAutomationProjectArn: env.BDA_PROJECT_ARN,
      stage: 'LIVE',
    },
    dataAutomationProfileArn: env.BDA_PROFILE_ARN,
    notificationConfiguration: undefined,
    clientToken: jobId,
  };
}
