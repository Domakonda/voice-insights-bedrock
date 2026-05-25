import { mockClient } from 'aws-sdk-client-mock';
import {
  BedrockDataAutomationRuntimeClient,
  InvokeDataAutomationAsyncCommand,
} from '@aws-sdk/client-bedrock-data-automation-runtime';
import type { Context } from 'aws-lambda';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { _resetClientForTests, handler } from './app.js';
import { resetEnvForTests } from './app.env.js';
import { SubmissionValidationError, validateEvent } from './app.schema.js';

const bdaMock = mockClient(BedrockDataAutomationRuntimeClient);

const baseEnv = {
  BDA_PROJECT_ARN: 'arn:aws:bedrock:us-east-1:111122223333:data-automation-project/test',
  BDA_PROFILE_ARN: 'arn:aws:bedrock:us-east-1:111122223333:data-automation-profile/us.test',
  OUTPUT_BUCKET: 'voice-insights-output-test',
  OUTPUT_PREFIX: 'transcripts',
  AWS_REGION: 'us-east-1',
};

const ctx = {} as Context;

beforeEach(() => {
  bdaMock.reset();
  resetEnvForTests();
  _resetClientForTests();
  for (const [k, v] of Object.entries(baseEnv)) {
    process.env[k] = v;
  }
});

afterEach(() => {
  for (const k of Object.keys(baseEnv)) {
    delete process.env[k];
  }
});

describe('validateEvent', () => {
  it('accepts SQS event wrapping S3 ObjectCreated', () => {
    const event = {
      Records: [
        {
          messageId: 'm1',
          receiptHandle: 'r1',
          body: JSON.stringify({
            Records: [
              {
                eventSource: 'aws:s3',
                eventName: 'ObjectCreated:Put',
                s3: { bucket: { name: 'in' }, object: { key: 'audio/file.mp3', size: 100 } },
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
    const triggers = validateEvent(event);
    expect(triggers).toEqual([
      { bucket: 'in', key: 'audio/file.mp3', source: 'sqs', messageId: 'm1' },
    ]);
  });

  it('accepts direct S3 event', () => {
    const event = {
      Records: [
        {
          eventSource: 'aws:s3',
          eventName: 'ObjectCreated:Put',
          s3: { bucket: { name: 'in' }, object: { key: 'audio/x.mp3' } },
        },
      ],
    };
    const triggers = validateEvent(event);
    expect(triggers).toEqual([{ bucket: 'in', key: 'audio/x.mp3', source: 's3-direct' }]);
  });

  it('accepts shorthand', () => {
    const triggers = validateEvent({ bucket: 'in', key: 'audio/x.mp3' });
    expect(triggers).toEqual([{ bucket: 'in', key: 'audio/x.mp3', source: 'shorthand' }]);
  });

  it('url-decodes S3 keys with spaces', () => {
    const triggers = validateEvent({
      Records: [
        {
          eventSource: 'aws:s3',
          eventName: 'ObjectCreated:Put',
          s3: { bucket: { name: 'in' }, object: { key: 'audio/my+file.mp3' } },
        },
      ],
    });
    expect(triggers[0]?.key).toBe('audio/my file.mp3');
  });

  it('throws SubmissionValidationError on unknown shape', () => {
    expect(() => validateEvent({ foo: 'bar' })).toThrow(SubmissionValidationError);
  });
});

describe('handler', () => {
  it('invokes BDA for shorthand event and returns empty failures', async () => {
    bdaMock.on(InvokeDataAutomationAsyncCommand).resolves({
      invocationArn: 'arn:aws:bedrock:us-east-1:111122223333:invocation/abc',
    });

    const res = await handler({ bucket: 'in', key: 'audio/x.mp3' }, ctx);
    expect(res.batchItemFailures).toEqual([]);
    expect(bdaMock.commandCalls(InvokeDataAutomationAsyncCommand)).toHaveLength(1);
  });

  it('reports SQS messageId in batchItemFailures on BDA error', async () => {
    bdaMock.on(InvokeDataAutomationAsyncCommand).rejects(new Error('throttled'));

    const event = {
      Records: [
        {
          messageId: 'msg-failing',
          receiptHandle: 'r1',
          body: JSON.stringify({
            Records: [
              {
                eventSource: 'aws:s3',
                eventName: 'ObjectCreated:Put',
                s3: { bucket: { name: 'in' }, object: { key: 'audio/x.mp3' } },
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
    expect(res.batchItemFailures).toEqual([{ itemIdentifier: 'msg-failing' }]);
  });

  it('rethrows when shorthand path fails (no messageId to fail back to)', async () => {
    bdaMock.on(InvokeDataAutomationAsyncCommand).rejects(new Error('throttled'));
    await expect(handler({ bucket: 'in', key: 'audio/x.mp3' }, ctx)).rejects.toThrow('throttled');
  });
});
