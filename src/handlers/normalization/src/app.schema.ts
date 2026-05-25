import { JSONStringified } from '@aws-lambda-powertools/parser/helpers';
import { SqsSchema } from '@aws-lambda-powertools/parser/schemas/sqs';
import { z } from 'zod';

const S3RecordSchema = z.object({
  eventSource: z.literal('aws:s3'),
  eventName: z.string(),
  s3: z.object({
    bucket: z.object({ name: z.string().min(1) }),
    object: z.object({ key: z.string().min(1) }),
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

export type NormalizationTrigger = {
  bucket: string;
  key: string;
  source: 'sqs' | 's3-direct' | 'shorthand';
  messageId?: string;
};

export class NormalizationValidationError extends Error {
  constructor(message: string, public readonly attempts: Record<string, string>) {
    super(message);
    this.name = 'NormalizationValidationError';
  }
}

export function validateEvent(event: unknown): NormalizationTrigger[] {
  const attempts: Record<string, string> = {};

  const sqs = SqsWithS3BodySchema.safeParse(event);
  if (sqs.success) {
    const triggers: NormalizationTrigger[] = [];
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

  throw new NormalizationValidationError('Event did not match any known shape', attempts);
}

// Shape of the Bedrock Data Automation standard_output/0/result.json for audio assets.
// BDA emits speaker/channel as objects with *_label fields (e.g. { speaker_label: 'spk_0' }).
// Accept either the object form or a bare string for forward compatibility.
const SpeakerSchema = z.union([
  z.string(),
  z.object({ speaker_label: z.string() }).transform((o) => o.speaker_label),
]).optional();

const ChannelSchema = z.union([
  z.string(),
  z.number(),
  z.object({ channel_label: z.string() }).transform((o) => o.channel_label),
]).optional();

export const BdaSegmentSchema = z.object({
  segment_index: z.number().int().nonnegative().optional(),
  start_timestamp_millis: z.number().int().nonnegative(),
  end_timestamp_millis: z.number().int().nonnegative(),
  text: z.string(),
  speaker: SpeakerSchema,
  channel: ChannelSchema,
  language: z.string().optional(),
}).passthrough();

export const BdaTopicSchema = z.object({
  topic_index: z.number().int().nonnegative().optional(),
  start_timestamp_millis: z.number().int().nonnegative().optional(),
  end_timestamp_millis: z.number().int().nonnegative().optional(),
  summary: z.string(),
}).passthrough();

export const BdaResultSchema = z.object({
  metadata: z.object({
    duration_millis: z.number().int().nonnegative(),
    dominant_asset_language: z.string().optional(),
    s3_bucket: z.string().optional(),
    s3_key: z.string().optional(),
  }).passthrough(),
  audio: z.object({
    summary: z.string().optional(),
    transcript: z.object({
      representation: z.object({
        text: z.string(),
      }),
    }),
  }).passthrough(),
  audio_segments: z.array(BdaSegmentSchema).default([]),
  topics: z.array(BdaTopicSchema).default([]),
}).passthrough();

export type BdaResult = z.infer<typeof BdaResultSchema>;
