import { z } from 'zod';

export const AudioMessageSchema = z.object({
  jobId: z.string().min(1),
  s3Bucket: z.string().min(1),
  s3Key: z.string().min(1),
  contentType: z.string().optional(),
  metadata: z.record(z.string(), z.string()).optional(),
});

export type AudioMessage = z.infer<typeof AudioMessageSchema>;

export const TranscriptSegmentSchema = z.object({
  speaker: z.string().optional(),
  startMs: z.number().int().nonnegative(),
  endMs: z.number().int().nonnegative(),
  text: z.string(),
});

export type TranscriptSegment = z.infer<typeof TranscriptSegmentSchema>;

export const TranscriptResultSchema = z.object({
  jobId: z.string().min(1),
  s3Key: z.string().min(1),
  language: z.string().default('en'),
  durationMs: z.number().int().nonnegative(),
  transcript: z.string(),
  segments: z.array(TranscriptSegmentSchema).default([]),
  topics: z.array(z.string()).default([]),
  sentiment: z.enum(['positive', 'neutral', 'negative', 'mixed']).default('neutral'),
  actionItems: z.array(z.string()).default([]),
  createdAt: z.string().datetime(),
});

export type TranscriptResult = z.infer<typeof TranscriptResultSchema>;
