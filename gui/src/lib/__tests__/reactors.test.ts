import { describe, it, expect } from 'vitest';
import { aggregateByClass, classRoute, matchesStatusFilter } from '../reactors';

describe('aggregateByClass', () => {
  it('groups reactors by class and counts statuses', () => {
    const reactors = [
      { id: '1', class: 'ParentReactor', status: 'completed', created_at: '2024-01-01' },
      { id: '2', class: 'ParentReactor', status: 'running', created_at: '2024-01-02' },
      { id: '3', class: 'ParentReactor', status: 'failed', created_at: '2024-01-03' },
      { id: '4', class: 'WebhookInterruptReactor', status: 'skipped', created_at: '2024-01-04' },
      { id: '5', class: 'WebhookInterruptReactor', status: 'cancelled', created_at: '2024-01-05' },
      { id: '6', class: 'WebhookInterruptReactor', status: 'paused', created_at: '2024-01-06' },
    ];

    expect(aggregateByClass(reactors)).toEqual([
      { className: 'ParentReactor', runs: 3, success: 1, running: 1, errors: 1 },
      { className: 'WebhookInterruptReactor', runs: 3, success: 1, running: 1, errors: 1 },
    ]);
  });

  it('returns an empty array when no reactors exist', () => {
    expect(aggregateByClass([])).toEqual([]);
  });
});

describe('matchesStatusFilter', () => {
  it('matches dashboard success and error groups', () => {
    expect(matchesStatusFilter('completed', 'success')).toBe(true);
    expect(matchesStatusFilter('skipped', 'success')).toBe(true);
    expect(matchesStatusFilter('failed', 'success')).toBe(false);
    expect(matchesStatusFilter('failed', 'errors')).toBe(true);
    expect(matchesStatusFilter('cancelled', 'errors')).toBe(true);
    expect(matchesStatusFilter('paused', 'running')).toBe(true);
  });

  it('matches an exact status or all', () => {
    expect(matchesStatusFilter('completed', 'completed')).toBe(true);
    expect(matchesStatusFilter('failed', 'completed')).toBe(false);
    expect(matchesStatusFilter('failed', 'all')).toBe(true);
  });
});

describe('classRoute', () => {
  it('appends a status query when a filter is active', () => {
    expect(classRoute('ParentReactor')).toBe('/reactors/by-class/ParentReactor');
    expect(classRoute('ParentReactor', 'success')).toBe('/reactors/by-class/ParentReactor?status=success');
  });
});
