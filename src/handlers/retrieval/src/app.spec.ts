import { mockClient } from 'aws-sdk-client-mock';
import { DynamoDBDocumentClient, GetCommand } from '@aws-sdk/lib-dynamodb';
import type { APIGatewayProxyEventV2, Context } from 'aws-lambda';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { _resetClientsForTests, handler } from './app.js';
import { resetEnvForTests } from './app.env.js';

const ddbMock = mockClient(DynamoDBDocumentClient);

const baseEnv = {
  TRANSCRIPTS_TABLE: 'voice-insights-transcripts-test',
  AWS_REGION: 'us-east-1',
};
const ctx = {} as Context;

function apiEvent(pathParameters: Record<string, string> | undefined): APIGatewayProxyEventV2 {
  return {
    version: '2.0',
    routeKey: 'GET /transcripts/{jobId}',
    rawPath: '/transcripts/x',
    rawQueryString: '',
    headers: {},
    requestContext: {} as never,
    pathParameters,
    isBase64Encoded: false,
  } as APIGatewayProxyEventV2;
}

beforeEach(() => {
  ddbMock.reset();
  resetEnvForTests();
  _resetClientsForTests();
  for (const [k, v] of Object.entries(baseEnv)) process.env[k] = v;
});

afterEach(() => {
  for (const k of Object.keys(baseEnv)) delete process.env[k];
});

describe('retrieval handler', () => {
  it('returns 200 with the item when found', async () => {
    ddbMock.on(GetCommand).resolves({
      Item: { jobId: 'job-1', transcript: 'hello', segments: [], topics: [] },
    });
    const res = (await handler(apiEvent({ jobId: 'job-1' }), ctx)) as {
      statusCode: number;
      body: string;
    };
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body)).toMatchObject({ jobId: 'job-1', transcript: 'hello' });
  });

  it('returns 404 when item missing', async () => {
    ddbMock.on(GetCommand).resolves({});
    const res = (await handler(apiEvent({ jobId: 'nope' }), ctx)) as {
      statusCode: number;
      body: string;
    };
    expect(res.statusCode).toBe(404);
    expect(JSON.parse(res.body).error).toBe('not_found');
  });

  it('returns 400 when jobId path param missing', async () => {
    const res = (await handler(apiEvent(undefined), ctx)) as {
      statusCode: number;
      body: string;
    };
    expect(res.statusCode).toBe(400);
    expect(JSON.parse(res.body).error).toBe('bad_request');
  });

  it('returns 500 when DynamoDB throws', async () => {
    ddbMock.on(GetCommand).rejects(new Error('throttled'));
    const res = (await handler(apiEvent({ jobId: 'job-1' }), ctx)) as {
      statusCode: number;
      body: string;
    };
    expect(res.statusCode).toBe(500);
    expect(JSON.parse(res.body).error).toBe('internal_error');
  });
});
