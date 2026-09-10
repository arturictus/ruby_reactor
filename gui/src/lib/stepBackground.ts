export type TraceEntry = {
  step?: string;
  background?: boolean | string;
  [key: string]: unknown;
};

function matchesStep(entry: TraceEntry, stepName: string): boolean {
  const leaf = stepName.includes('.') ? stepName.split('.').pop() : stepName;
  return String(entry.step) === String(stepName) || String(entry.step) === String(leaf);
}

function asBoolean(value: unknown): boolean | undefined {
  if (value === true || value === 'true') return true;
  if (value === false || value === 'false') return false;
  return undefined;
}

// Last matching execution_trace event is the source of truth: Redis stamps
// `background` when the step actually ran, not from the reactor's hand-off cut.
export function stepRanInBackground(steps: TraceEntry[] | undefined, stepName: string): boolean | undefined {
  if (!steps?.length) return undefined;

  for (let i = steps.length - 1; i >= 0; i -= 1) {
    const entry = steps[i];
    if (!matchesStep(entry, stepName)) continue;
    return asBoolean(entry.background);
  }

  return undefined;
}

export function backgroundFlagsByStep(steps: TraceEntry[] | undefined): Record<string, boolean> {
  const flags: Record<string, boolean> = {};
  (steps || []).forEach((entry) => {
    if (!entry.step) return;
    const flag = asBoolean(entry.background);
    if (flag === undefined) return;
    flags[String(entry.step)] = flag;
  });
  return flags;
}
