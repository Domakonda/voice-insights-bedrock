export class ValidationError extends Error {
  public readonly issues: unknown;
  constructor(message: string, issues: unknown) {
    super(message);
    this.name = 'ValidationError';
    this.issues = issues;
  }
}

export type ValidationResult<T> =
  | { success: true; data: T }
  | { success: false; error: ValidationError };
