import { JSONStringified } from '@aws-lambda-powertools/parser/helpers';
import { SqsSchema } from '@aws-lambda-powertools/parser/schemas/sqs';
import { z } from 'zod';

const S3ObjectSchema = z.object({
  key: z.string().min(1),
  size: z.number().int().nonnegative().optional(),
});

const S3BucketSchema = z.object({
  name: z.string().min(1),
});

const S3RecordSchema = z.object({
  eventSource: z.literal('aws:s3'),
  eventName: z.string(),
  s3: z.object({
    bucket: S3BucketSchema,
    object: S3ObjectSchema,
  }),
});

export const S3EventSchema = z.object({
  Records: z.array(S3RecordSchema).min(1),
});

export const ShorthandSchema = z.object({
  bucket: z.string().min(1),
  key: z.string().min(1),
});

const SqsWithS3BodySchema = SqsSchema.extend({
  Records: z.array(
    z.object({
      messageId: z.string(),
      body: JSONStringified(S3EventSchema),
    }).passthrough()
  ).min(1),
});

export type SubmissionTrigger = {
  bucket: string;
  key: string;
  source: 'sqs' | 's3-direct' | 'shorthand';
  messageId?: string;
};

export class SubmissionValidationError extends Error {
  constructor(message: string, public readonly attempts: Record<string, string>) {
    super(message);
    this.name = 'SubmissionValidationError';
  }
}

export function validateEvent(event: unknown): SubmissionTrigger[] {
  const attempts: Record<string, string> = {};

  const sqs = SqsWithS3BodySchema.safeParse(event);
  if (sqs.success) {
    const triggers: SubmissionTrigger[] = [];
    for (const record of sqs.data.Records) {
      const body = record.body as z.infer<typeof S3EventSchema>;
      for (const s3record of body.Records) {
        triggers.push({
          bucket: s3record.s3.bucket.name,
          key: decodeURIComponent(s3record.s3.object.key.replace(/\+/g, ' ')),
          source: 'sqs',
          messageId: record.messageId,
        });
      }
    }
    return triggers;
  }
  attempts['sqs->s3'] = sqs.error.message;

  const direct = S3EventSchema.safeParse(event);
  if (direct.success) {
    return direct.data.Records.map((r) => ({
      bucket: r.s3.bucket.name,
      key: decodeURIComponent(r.s3.object.key.replace(/\+/g, ' ')),
      source: 's3-direct' as const,
    }));
  }
  attempts['s3-direct'] = direct.error.message;

  const shorthand = ShorthandSchema.safeParse(event);
  if (shorthand.success) {
    return [
      {
        bucket: shorthand.data.bucket,
        key: shorthand.data.key,
        source: 'shorthand',
      },
    ];
  }
  attempts['shorthand'] = shorthand.error.message;

  throw new SubmissionValidationError('Event did not match any known shape', attempts);
}
