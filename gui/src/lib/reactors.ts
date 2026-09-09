export interface ReactorSummary {
  id: string;
  class: string;
  status: string;
  created_at: string;
  failure?: {
    step_name?: string;
    exception_class?: string;
  };
}

export interface ClassAggregate {
  className: string;
  runs: number;
  success: number;
  running: number;
  errors: number;
}

export const STATUS_GROUPS = {
  success: ['completed', 'halted', 'skipped'],
  running: ['running', 'paused'],
  errors: ['failed', 'cancelled'],
} as const;

export type StatusGroup = keyof typeof STATUS_GROUPS;

export function matchesStatusFilter(status: string, filter: string): boolean {
  if (filter === 'all') return true;
  const group = STATUS_GROUPS[filter as StatusGroup];
  if (group) return (group as readonly string[]).includes(status);
  return status === filter;
}

export function aggregateByClass(reactors: ReactorSummary[]): ClassAggregate[] {
  const map = new Map<string, ClassAggregate>();

  for (const reactor of reactors) {
    let aggregate = map.get(reactor.class);
    if (!aggregate) {
      aggregate = { className: reactor.class, runs: 0, success: 0, running: 0, errors: 0 };
      map.set(reactor.class, aggregate);
    }

    aggregate.runs += 1;

    if (matchesStatusFilter(reactor.status, 'success')) {
      aggregate.success += 1;
    } else if (matchesStatusFilter(reactor.status, 'running')) {
      aggregate.running += 1;
    } else if (matchesStatusFilter(reactor.status, 'errors')) {
      aggregate.errors += 1;
    }
  }

  return Array.from(map.values()).sort((a, b) => a.className.localeCompare(b.className));
}

export function classRoute(className: string, statusFilter: string = 'all') {
  const path = `/reactors/by-class/${encodeURIComponent(className)}`;
  return statusFilter === 'all' ? path : `${path}?status=${statusFilter}`;
}

export function reactorRoute(id: string) {
  return `/reactors/${id}`;
}

// The API returns one page per request and hands back the next page's cursor in
// X-Next-Cursor ("0" = no more pages). Page through them all so the dashboard
// isn't silently capped at the first batch.
export async function fetchAllReactors(url: string, pageSize = 100): Promise<ReactorSummary[]> {
  const all: ReactorSummary[] = [];
  let cursor = '0';

  // ponytail: hard page ceiling so a bad cursor can't spin forever; raise it if
  // anyone ever has >50k reactors live at once.
  for (let page = 0; page < 500; page++) {
    const separator = url.includes('?') ? '&' : '?';
    const response = await fetch(`${url}${separator}limit=${pageSize}&cursor=${encodeURIComponent(cursor)}`);
    if (!response.ok) throw new Error(`Failed to load reactors: ${response.status}`);

    all.push(...(await response.json()));

    const next = response.headers.get('X-Next-Cursor');
    if (!next || next === '0') break;
    cursor = next;
  }

  return all;
}
