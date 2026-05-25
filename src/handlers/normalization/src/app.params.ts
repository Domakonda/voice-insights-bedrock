import type { TranscriptResult } from '@voice-insights/shared';
import type { BdaResult } from './app.schema.js';

export function extractJobIdFromKey(key: string): string {
  const parts = key.split('/');
  for (let i = 0; i < parts.length; i++) {
    const p = parts[i];
    if ((p === 'transcripts' || p === 'standard_output' || p === 'custom_output') && parts[i + 1]) {
      return parts[i + 1]!;
    }
  }
  const filename = parts[parts.length - 1] ?? key;
  return filename.replace(/\.[^.]+$/, '');
}

export function normalizeBdaResult(
  bda: BdaResult,
  jobId: string,
  sourceKey: string
): TranscriptResult {
  const lang = bda.metadata.dominant_asset_language?.toLowerCase() ?? 'en';
  return {
    jobId,
    s3Key: sourceKey,
    language: lang,
    durationMs: bda.metadata.duration_millis,
    transcript: bda.audio.transcript.representation.text,
    segments: bda.audio_segments.map((s) => ({
      speaker: s.speaker,
      startMs: s.start_timestamp_millis,
      endMs: s.end_timestamp_millis,
      text: s.text,
    })),
    topics: bda.topics.map((t) => t.summary),
    sentiment: 'neutral',
    actionItems: bda.audio.summary ? [bda.audio.summary] : [],
    createdAt: new Date().toISOString(),
  };
}
