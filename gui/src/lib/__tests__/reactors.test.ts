import { describe, it, expect, vi, afterEach } from 'vitest';
import { aggregateByClass, classRoute, fetchAllReactors, matchesStatusFilter } from '../reactors';

describe('fetchAllReactors', () => {
  afterEach(() => vi.unstubAllGlobals());

  function stubPages(pages: { ids: string[]; nextCursor: string }[]) {
    const calls: string[] = [];
    const fetchMock = vi.fn(async (url: string) => {
      calls.push(url);
      const page = pages[calls.length - 1];
      return {
        ok: true,
        json: async () => page.ids.map((id) => ({ id, class: 'Foo', status: 'completed', created_at: '2024-01-01' })),
        headers: { get: () => page.nextCursor },
      };
    });
    vi.stubGlobal('fetch', fetchMock);
    return calls;
  }

  it('pages until the cursor comes back "0" and concatenates every batch', async () => {
    const calls = stubPages([
      { ids: ['a', 'b'], nextCursor: '2' },
      { ids: ['c', 'd'], nextCursor: '4' },
      { ids: ['e'], nextCursor: '0' },
    ]);

    const reactors = await fetchAllReactors('/api/reactors', 2);

    expect(reactors.map((r) => r.id)).toEqual(['a', 'b', 'c', 'd', 'e']);
    expect(calls).toHaveLength(3);
    expect(calls[0]).toBe('/api/reactors?limit=2&cursor=0');
    expect(calls[1]).toBe('/api/reactors?limit=2&cursor=2');
    expect(calls[2]).toBe('/api/reactors?limit=2&cursor=4');
  });

  it('stops after a single request when the first page is the only page', async () => {
    const calls = stubPages([{ ids: ['a'], nextCursor: '0' }]);

    await expect(fetchAllReactors('/api/reactors')).resolves.toHaveLength(1);
    expect(calls).toHaveLength(1);
  });

  it('throws when a page request fails', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false, status: 500 })));

    await expect(fetchAllReactors('/api/reactors')).rejects.toThrow('Failed to load reactors: 500');
  });
});

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

  it('counts halted runs in the clean-outcome bucket, and still does so for a legacy skipped row', () => {
    const reactors = [
      { id: '1', class: 'HaltingReactor', status: 'halted', created_at: '2024-01-01' },
      { id: '2', class: 'HaltingReactor', status: 'skipped', created_at: '2024-01-02' },
    ];

    expect(aggregateByClass(reactors)).toEqual([
      { className: 'HaltingReactor', runs: 2, success: 2, running: 0, errors: 0 },
    ]);
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
