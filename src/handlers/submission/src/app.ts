import {
  BedrockDataAutomationRuntimeClient,
  InvokeDataAutomationAsyncCommand,
} from '@aws-sdk/client-bedrock-data-automation-runtime';
import { createLogger } from '@voice-insights/shared';
import type { Context, SQSBatchResponse, SQSBatchItemFailure } from 'aws-lambda';
import { getEnv } from './app.env.js';
import { buildInvokeParams, buildJobId } from './app.params.js';
import { SubmissionValidationError, validateEvent } from './app.schema.js';

const logger = createLogger('voice-insights-submission');

let _client: BedrockDataAutomationRuntimeClient | undefined;
function getClient(region: string): BedrockDataAutomationRuntimeClient {
  if (!_client) {
    _client = new BedrockDataAutomationRuntimeClient({ region });
  }
  return _client;
}

export function _resetClientForTests(): void {
  _client = undefined;
}

export async function handler(event: unknown, _context: Context): Promise<SQSBatchResponse> {
  const env = getEnv();
  const client = getClient(env.AWS_REGION);
  const batchItemFailures: SQSBatchItemFailure[] = [];

  let triggers;
  try {
    triggers = validateEvent(event);
  } catch (err) {
    if (err instanceof SubmissionValidationError) {
      logger.error('Validation failed', { attempts: err.attempts });
    } else {
      logger.error('Unexpected validation error', { err });
    }
    throw err;
  }

  logger.info('Processing triggers', { count: triggers.length });

  for (const trigger of triggers) {
    const jobId = buildJobId(trigger.key);
    const params = buildInvokeParams(env, trigger, jobId);

    try {
      const response = await client.send(new InvokeDataAutomationAsyncCommand(params));
      logger.info('BDA invocation submitted', {
        jobId,
        bucket: trigger.bucket,
        key: trigger.key,
        invocationArn: response.invocationArn,
      });
    } catch (err) {
      logger.error('BDA invocation failed', {
        jobId,
        bucket: trigger.bucket,
        key: trigger.key,
        err,
      });
      if (trigger.messageId) {
        batchItemFailures.push({ itemIdentifier: trigger.messageId });
      } else {
        throw err;
      }
    }
  }

  return { batchItemFailures };
}
