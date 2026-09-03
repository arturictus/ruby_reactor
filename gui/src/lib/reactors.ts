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

export function aggregateByClass(reactors: ReactorSummary[]): ClassAggregate[] {
  const map = new Map<string, ClassAggregate>();

  for (const reactor of reactors) {
    let aggregate = map.get(reactor.class);
    if (!aggregate) {
      aggregate = { className: reactor.class, runs: 0, success: 0, running: 0, errors: 0 };
      map.set(reactor.class, aggregate);
    }

    aggregate.runs += 1;

    if (reactor.status === 'completed' || reactor.status === 'skipped') {
      aggregate.success += 1;
    } else if (reactor.status === 'running' || reactor.status === 'paused') {
      aggregate.running += 1;
    } else if (reactor.status === 'failed' || reactor.status === 'cancelled') {
      aggregate.errors += 1;
    }
  }

  return Array.from(map.values()).sort((a, b) => a.className.localeCompare(b.className));
}

function getBasePath(): string {
  return window.RUBY_REACTOR_BASE || '/';
}

export function classRoute(className: string) {
  const base = getBasePath().replace(/\/$/, '');
  return `${base}/reactors/by-class/${encodeURIComponent(className)}`;
}

export function reactorRoute(id: string) {
  const base = getBasePath().replace(/\/$/, '');
  return `${base}/reactors/${id}`;
}
