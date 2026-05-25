import { GetObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, PutCommand } from '@aws-sdk/lib-dynamodb';
import { createLogger } from '@voice-insights/shared';
import type { Context, SQSBatchItemFailure, SQSBatchResponse } from 'aws-lambda';
import { getEnv } from './app.env.js';
import { extractJobIdFromKey, normalizeBdaResult } from './app.params.js';
import { BdaResultSchema, NormalizationValidationError, validateEvent } from './app.schema.js';

const logger = createLogger('voice-insights-normalization');

let _s3: S3Client | undefined;
let _ddb: DynamoDBDocumentClient | undefined;

function getS3(region: string): S3Client {
  if (!_s3) _s3 = new S3Client({ region });
  return _s3;
}
function getDdb(region: string): DynamoDBDocumentClient {
  if (!_ddb) _ddb = DynamoDBDocumentClient.from(new DynamoDBClient({ region }));
  return _ddb;
}
export function _resetClientsForTests(): void {
  _s3 = undefined;
  _ddb = undefined;
}

async function streamToString(stream: NodeJS.ReadableStream | undefined): Promise<string> {
  if (!stream) return '';
  const chunks: Buffer[] = [];
  for await (const chunk of stream) {
    chunks.push(typeof chunk === 'string' ? Buffer.from(chunk) : chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}

export async function handler(event: unknown, _context: Context): Promise<SQSBatchResponse> {
  const env = getEnv();
  const s3 = getS3(env.AWS_REGION);
  const ddb = getDdb(env.AWS_REGION);
  const batchItemFailures: SQSBatchItemFailure[] = [];

  let triggers;
  try {
    triggers = validateEvent(event);
  } catch (err) {
    if (err instanceof NormalizationValidationError) {
      logger.error('Validation failed', { attempts: err.attempts });
    } else {
      logger.error('Unexpected validation error', { err });
    }
    throw err;
  }

  for (const trigger of triggers) {
    try {
      const obj = await s3.send(new GetObjectCommand({ Bucket: trigger.bucket, Key: trigger.key }));
      const raw = await streamToString(obj.Body as NodeJS.ReadableStream | undefined);
      const parsed = BdaResultSchema.parse(JSON.parse(raw));
      const jobId = extractJobIdFromKey(trigger.key);
      const normalized = normalizeBdaResult(parsed, jobId, trigger.key);

      await ddb.send(
        new PutCommand({
          TableName: env.TRANSCRIPTS_TABLE,
          Item: normalized,
        })
      );

      logger.info('Transcript normalized and stored', {
        jobId,
        key: trigger.key,
        segments: normalized.segments.length,
      });
    } catch (err) {
      logger.error('Normalization failed', {
        bucket: trigger.bucket,
        key: trigger.key,
        err: err instanceof Error ? err.message : String(err),
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
