import { z } from 'zod';

export const PathParamsSchema = z.object({
  jobId: z.string().min(1).max(200),
});

export type PathParams = z.infer<typeof PathParamsSchema>;
