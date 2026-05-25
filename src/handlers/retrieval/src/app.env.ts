import { z } from 'zod';

const EnvSchema = z.object({
  TRANSCRIPTS_TABLE: z.string().min(1),
  AWS_REGION: z.string().default('us-east-1'),
});

export type Env = z.infer<typeof EnvSchema>;

let cached: Env | undefined;

export function getEnv(): Env {
  if (!cached) cached = EnvSchema.parse(process.env);
  return cached;
}

export function resetEnvForTests(): void {
  cached = undefined;
}
