import { describe, expect, it } from 'vitest';
import { backgroundFlagsByStep, stepQueue, stepRanInBackground } from '../stepBackground';

describe('stepRanInBackground', () => {
  const steps = [
    { type: 'run', step: 'first', background: false },
    { type: 'run', step: 'second', background: false },
    { type: 'run', step: 'third', background: true },
  ];

  it('uses the last matching trace event', () => {
    expect(stepRanInBackground(steps, 'first')).toBe(false);
    expect(stepRanInBackground(steps, 'third')).toBe(true);
  });

  it('matches a nested path by its leaf name', () => {
    expect(stepRanInBackground(steps, 'parent.third')).toBe(true);
  });

  it('leaves unlabeled older traces unset', () => {
    expect(stepRanInBackground([{ type: 'run', step: 'first' }], 'first')).toBeUndefined();
    expect(stepRanInBackground([], 'first')).toBeUndefined();
  });
});

describe('backgroundFlagsByStep', () => {
  it('keeps the latest stamp per step name', () => {
    expect(backgroundFlagsByStep([
      { step: 'first', background: false },
      { step: 'first', background: true },
    ])).toEqual({ first: true });
  });
});

describe('stepQueue', () => {
  const steps = [
    { type: 'run', step: 'first', background: false },
    { type: 'run', step: 'second', background: true, queue: 'main' },
    { type: 'undo', step: 'second', background: true, queue: 'stripe' },
  ];

  it('names the queue of the last matching trace event', () => {
    expect(stepQueue(steps, 'second')).toBe('stripe');
    expect(stepQueue(steps, 'parent.second')).toBe('stripe');
  });

  it('is unset for a step that ran in the calling process', () => {
    expect(stepQueue(steps, 'first')).toBeUndefined();
    expect(stepQueue([], 'first')).toBeUndefined();
  });
});
