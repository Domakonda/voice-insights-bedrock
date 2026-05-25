import { Readable } from 'node:stream';
import { sdkStreamMixin } from '@smithy/util-stream';
import { mockClient } from 'aws-sdk-client-mock';
import { GetObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { DynamoDBDocumentClient, PutCommand } from '@aws-sdk/lib-dynamodb';
import type { Context } from 'aws-lambda';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { _resetClientsForTests, handler } from './app.js';
import { resetEnvForTests } from './app.env.js';
import { extractJobIdFromKey, normalizeBdaResult } from './app.params.js';
import { BdaResultSchema, NormalizationValidationError, validateEvent } from './app.schema.js';

const s3Mock = mockClient(S3Client);
const ddbMock = mockClient(DynamoDBDocumentClient);

const baseEnv = {
  TRANSCRIPTS_TABLE: 'voice-insights-transcripts-test',
  AWS_REGION: 'us-east-1',
};
const ctx = {} as Context;

function makeStreamBody(payload: unknown) {
  return sdkStreamMixin(Readable.from(Buffer.from(JSON.stringify(payload))));
}

const sampleBda = {
  metadata: {
    asset_id: 'asset-1',
    duration_millis: 12345,
    dominant_asset_language: 'EN',
  },
  audio: {
    summary: 'Customer greeting.',
    transcript: {
      representation: { text: 'Hello world.' },
    },
  },
  audio_segments: [
    { speaker: 'spk_0', start_timestamp_millis: 0, end_timestamp_millis: 1000, text: 'Hello' },
    { speaker: 'spk_0', start_timestamp_millis: 1000, end_timestamp_millis: 2000, text: 'world.' },
  ],
  topics: [{ topic_index: 0, summary: 'greeting' }],
};

beforeEach(() => {
  s3Mock.reset();
  ddbMock.reset();
  resetEnvForTests();
  _resetClientsForTests();
  for (const [k, v] of Object.entries(baseEnv)) process.env[k] = v;
});

afterEach(() => {
  for (const k of Object.keys(baseEnv)) delete process.env[k];
});

describe('validateEvent', () => {
  it('accepts SQS event wrapping S3 ObjectCreated', () => {
    const event = {
      Records: [
        {
          messageId: 'm1',
          receiptHandle: 'r',
          body: JSON.stringify({
            Records: [
              {
                eventSource: 'aws:s3',
                eventName: 'ObjectCreated:Put',
                s3: { bucket: { name: 'out' }, object: { key: 'transcripts/abc/result.json' } },
              },
            ],
          }),
          attributes: {},
          messageAttributes: {},
          md5OfBody: '',
          eventSource: 'aws:sqs',
          eventSourceARN: 'arn:aws:sqs:us-east-1:111122223333:q',
          awsRegion: 'us-east-1',
        },
      ],
    };
    expect(validateEvent(event)).toEqual([
      { bucket: 'out', key: 'transcripts/abc/result.json', source: 'sqs', messageId: 'm1' },
    ]);
  });

  it('throws on unknown shape', () => {
    expect(() => validateEvent({ nope: true })).toThrow(NormalizationValidationError);
  });
});

describe('extractJobIdFromKey', () => {
  it('pulls id after transcripts/ segment', () => {
    expect(extractJobIdFromKey('transcripts/job-abc/result.json')).toBe('job-abc');
  });
  it('pulls id after standard_output/ segment', () => {
    expect(extractJobIdFromKey('out/0/standard_output/JOB_X/result.json')).toBe('JOB_X');
  });
  it('falls back to filename without extension', () => {
    expect(extractJobIdFromKey('result.json')).toBe('result');
  });
});

describe('normalizeBdaResult', () => {
  it('shapes BDA payload into TranscriptResult', () => {
    const parsed = BdaResultSchema.parse(sampleBda);
    const out = normalizeBdaResult(parsed, 'job-1', 'transcripts/job-1/result.json');
    expect(out.jobId).toBe('job-1');
    expect(out.transcript).toBe('Hello world.');
    expect(out.segments).toHaveLength(2);
    expect(out.segments[0]?.startMs).toBe(0);
    expect(out.topics).toEqual(['greeting']);
    expect(out.sentiment).toBe('neutral');
  });
});

describe('handler', () => {
  it('reads S3 object, normalizes, writes DDB', async () => {
    s3Mock.on(GetObjectCommand).resolves({ Body: makeStreamBody(sampleBda) as never });
    ddbMock.on(PutCommand).resolves({});

    const res = await handler(
      { bucket: 'out', key: 'transcripts/job-1/result.json' },
      ctx
    );
    expect(res.batchItemFailures).toEqual([]);
    expect(ddbMock.commandCalls(PutCommand)).toHaveLength(1);
    const call = ddbMock.commandCalls(PutCommand)[0]!;
    expect(call.args[0].input.Item).toMatchObject({ jobId: 'job-1', transcript: 'Hello world.' });
  });

  it('records messageId in failures on parse error (SQS path)', async () => {
    s3Mock.on(GetObjectCommand).resolves({ Body: makeStreamBody({ invalid: true }) as never });

    const event = {
      Records: [
        {
          messageId: 'msg-bad',
          receiptHandle: 'r',
          body: JSON.stringify({
            Records: [
              {
                eventSource: 'aws:s3',
                eventName: 'ObjectCreated:Put',
                s3: { bucket: { name: 'out' }, object: { key: 'transcripts/x/result.json' } },
              },
            ],
          }),
          attributes: {},
          messageAttributes: {},
          md5OfBody: '',
          eventSource: 'aws:sqs',
          eventSourceARN: 'arn:aws:sqs:us-east-1:111122223333:q',
          awsRegion: 'us-east-1',
        },
      ],
    };
    const res = await handler(event, ctx);
    expect(res.batchItemFailures).toEqual([{ itemIdentifier: 'msg-bad' }]);
  });
});
