export interface CodeSnippetLine {
  line_number: number;
  content: string;
  target: boolean;
}

export interface FailureReason {
  message?: string;
  error?: string;
  step_name?: string;
  exception_class?: string;
  file_path?: string;
  line_number?: number;
  code_snippet?: CodeSnippetLine[];
  validation_errors?: Record<string, string | string[]>;
  backtrace?: string[];
  step_arguments?: Record<string, unknown>;
}

export function normalizeFailureReason(reason: unknown): FailureReason | undefined {
  if (!reason || typeof reason !== 'object') return undefined;

  const raw = reason as Record<string, unknown>;
  const { _type, ...rest } = raw;

  return {
    ...(rest as FailureReason),
    message: (raw.message as string | undefined) || (raw.error as string | undefined),
    code_snippet: raw.code_snippet as CodeSnippetLine[] | undefined,
  };
}
