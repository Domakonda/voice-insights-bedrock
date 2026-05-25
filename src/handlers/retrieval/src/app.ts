import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, GetCommand } from '@aws-sdk/lib-dynamodb';
import { createLogger } from '@voice-insights/shared';
import type { APIGatewayProxyEventV2, APIGatewayProxyResultV2, Context } from 'aws-lambda';
import { getEnv } from './app.env.js';
import { badRequest, internalError, notFound, ok } from './app.params.js';
import { PathParamsSchema } from './app.schema.js';

const logger = createLogger('voice-insights-retrieval');

let _ddb: DynamoDBDocumentClient | undefined;
function getDdb(region: string): DynamoDBDocumentClient {
  if (!_ddb) _ddb = DynamoDBDocumentClient.from(new DynamoDBClient({ region }));
  return _ddb;
}
export function _resetClientsForTests(): void {
  _ddb = undefined;
}

export async function handler(
  event: APIGatewayProxyEventV2,
  _context: Context
): Promise<APIGatewayProxyResultV2> {
  const env = getEnv();
  const ddb = getDdb(env.AWS_REGION);

  const parsed = PathParamsSchema.safeParse(event.pathParameters ?? {});
  if (!parsed.success) {
    logger.warn('Bad path params', { issues: parsed.error.issues });
    return badRequest('Invalid path parameters', parsed.error.issues);
  }

  const { jobId } = parsed.data;

  try {
    const res = await ddb.send(
      new GetCommand({ TableName: env.TRANSCRIPTS_TABLE, Key: { jobId } })
    );
    if (!res.Item) {
      return notFound(`No transcript for jobId=${jobId}`);
    }
    return ok(res.Item);
  } catch (err) {
    logger.error('DynamoDB GetItem failed', {
      jobId,
      err: err instanceof Error ? err.message : String(err),
    });
    return internalError('Failed to fetch transcript');
  }
}
