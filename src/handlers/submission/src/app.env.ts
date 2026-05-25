import { z } from 'zod';

const EnvSchema = z.object({
  BDA_PROJECT_ARN: z.string().min(1),
  BDA_PROFILE_ARN: z.string().min(1),
  OUTPUT_BUCKET: z.string().min(1),
  OUTPUT_PREFIX: z.string().default('transcripts'),
  AWS_REGION: z.string().default('us-east-1'),
});

export type Env = z.infer<typeof EnvSchema>;

let cached: Env | undefined;

export function getEnv(): Env {
  if (!cached) {
    cached = EnvSchema.parse(process.env);
  }
  return cached;
}

export function resetEnvForTests(): void {
  cached = undefined;
}
