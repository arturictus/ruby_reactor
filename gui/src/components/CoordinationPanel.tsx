import { Lock, Gauge, Timer, Calendar, AlertCircle } from 'lucide-react';
import { cn } from '../lib/utils';

interface LockState {
  held: boolean;
  owner?: string;
  owned_by_this_context?: boolean;
  reentrant_count?: number;
  ttl?: number;
}

interface LockCoordination {
  configured: { ttl: number; wait: number; auto_extend: boolean };
  key: string | null;
  key_error?: string;
  state?: LockState;
}

interface SemaphoreCoordination {
  configured: { limit: number; wait: number };
  key: string | null;
  key_error?: string;
  state?: { available: number; held: number; limit: number };
}

interface RateLimitWindow {
  name: string;
  limit: number;
  period_seconds: number;
  count: number;
  ttl: number;
}

interface RateLimitCoordination {
  configured: { limits: Array<{ name: string; limit: number; period_seconds: number }> };
  key: string | null;
  key_error?: string;
  state?: RateLimitWindow[];
}

interface PeriodCoordination {
  configured: { every: string };
  key: string | null;
  bucket_key?: string | null;
  key_error?: string;
  state?: { marked: boolean; ttl: number };
}

export interface CoordinationData {
  lock?: LockCoordination;
  semaphore?: SemaphoreCoordination;
  rate_limit?: RateLimitCoordination;
  period?: PeriodCoordination;
}

interface CoordinationPanelProps {
  coordination?: CoordinationData | null;
}

function formatTtl(ttl?: number): string {
  if (ttl === undefined || ttl === null) return '—';
  if (ttl < 0) return '—';
  if (ttl === 0) return 'expiring';
  if (ttl >= 3600) return `${Math.floor(ttl / 3600)}h ${Math.floor((ttl % 3600) / 60)}m`;
  if (ttl >= 60) return `${Math.floor(ttl / 60)}m ${ttl % 60}s`;
  return `${ttl}s`;
}

function KeyDisplay({ keyValue, keyError }: { keyValue: string | null; keyError?: string }) {
  if (keyError) {
    return (
      <span className="text-xs text-amber-400/80 flex items-center gap-1">
        <AlertCircle className="w-3 h-3 shrink-0" />
        {keyError}
      </span>
    );
  }

  return (
    <span className="font-mono text-xs text-slate-300 truncate" title={keyValue ?? undefined}>
      {keyValue ?? '—'}
    </span>
  );
}

function LockCard({ lock }: { lock: LockCoordination }) {
  const { state } = lock;
  const statusLabel = !state?.held
    ? 'Free'
    : state.owned_by_this_context
      ? 'Held (this run)'
      : 'Held (other)';

  const statusClass = !state?.held
    ? 'bg-slate-800 text-slate-400 border-slate-700'
    : state.owned_by_this_context
      ? 'bg-emerald-500/10 text-emerald-400 border-emerald-500/20'
      : 'bg-amber-500/10 text-amber-400 border-amber-500/20';

  return (
    <div className="rounded-lg border border-slate-800 bg-slate-900/60 p-3 space-y-2 min-w-0">
      <div className="flex items-center justify-between gap-2">
        <div className="flex items-center gap-2 min-w-0">
          <Lock className="w-4 h-4 text-indigo-400 shrink-0" />
          <span className="text-xs font-semibold uppercase tracking-wider text-slate-400">Lock</span>
        </div>
        <span className={cn('text-[10px] font-medium px-2 py-0.5 rounded-full border shrink-0', statusClass)}>
          {statusLabel}
        </span>
      </div>
      <KeyDisplay keyValue={lock.key} keyError={lock.key_error} />
      <div className="flex flex-wrap gap-x-4 gap-y-1 text-[11px] text-slate-500">
        <span>TTL config: {lock.configured.ttl}s</span>
        {lock.configured.auto_extend && <span>Auto-extend</span>}
        {state?.held && state.reentrant_count !== undefined && state.reentrant_count > 1 && (
          <span>Reentrant: {state.reentrant_count}</span>
        )}
        {state?.held && state.ttl !== undefined && state.ttl >= 0 && (
          <span>Expires: {formatTtl(state.ttl)}</span>
        )}
        {state?.held && state.owner && !state.owned_by_this_context && (
          <span className="font-mono truncate max-w-full" title={state.owner}>
            Owner: {state.owner.substring(0, 8)}…
          </span>
        )}
      </div>
    </div>
  );
}

function SemaphoreCard({ semaphore }: { semaphore: SemaphoreCoordination }) {
  const { state, configured } = semaphore;
  const held = state?.held ?? 0;
  const limit = state?.limit || configured.limit || 1;
  const pct = limit > 0 ? Math.min(100, (held / limit) * 100) : 0;

  return (
    <div className="rounded-lg border border-slate-800 bg-slate-900/60 p-3 space-y-2 min-w-0">
      <div className="flex items-center gap-2">
        <Gauge className="w-4 h-4 text-violet-400 shrink-0" />
        <span className="text-xs font-semibold uppercase tracking-wider text-slate-400">Semaphore</span>
      </div>
      <KeyDisplay keyValue={semaphore.key} keyError={semaphore.key_error} />
      {state && (
        <>
          <div className="flex items-center justify-between text-xs text-slate-400">
            <span>{held} / {limit} held</span>
            <span>{state.available} available</span>
          </div>
          <div className="h-1.5 rounded-full bg-slate-800 overflow-hidden">
            <div
              className="h-full bg-violet-500/70 rounded-full transition-all"
              style={{ width: `${pct}%` }}
            />
          </div>
        </>
      )}
    </div>
  );
}

function RateLimitCard({ rateLimit }: { rateLimit: RateLimitCoordination }) {
  return (
    <div className="rounded-lg border border-slate-800 bg-slate-900/60 p-3 space-y-2 min-w-0">
      <div className="flex items-center gap-2">
        <Timer className="w-4 h-4 text-cyan-400 shrink-0" />
        <span className="text-xs font-semibold uppercase tracking-wider text-slate-400">Rate Limit</span>
      </div>
      <KeyDisplay keyValue={rateLimit.key} keyError={rateLimit.key_error} />
      {rateLimit.state && rateLimit.state.length > 0 && (
        <div className="space-y-1.5">
          {rateLimit.state.map((window) => {
            const atLimit = window.count >= window.limit;
            return (
              <div key={window.name} className="flex items-center justify-between text-xs gap-2">
                <span className="text-slate-500 capitalize">{window.name}</span>
                <span className={cn('font-mono', atLimit ? 'text-amber-400' : 'text-slate-300')}>
                  {window.count}/{window.limit}
                </span>
                <span className="text-slate-600 text-[10px]">{formatTtl(window.ttl)}</span>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

function PeriodCard({ period }: { period: PeriodCoordination }) {
  const marked = period.state?.marked ?? false;

  return (
    <div className="rounded-lg border border-slate-800 bg-slate-900/60 p-3 space-y-2 min-w-0">
      <div className="flex items-center justify-between gap-2">
        <div className="flex items-center gap-2 min-w-0">
          <Calendar className="w-4 h-4 text-orange-400 shrink-0" />
          <span className="text-xs font-semibold uppercase tracking-wider text-slate-400">Period</span>
        </div>
        <span
          className={cn(
            'text-[10px] font-medium px-2 py-0.5 rounded-full border shrink-0',
            marked
              ? 'bg-orange-500/10 text-orange-400 border-orange-500/20'
              : 'bg-slate-800 text-slate-400 border-slate-700'
          )}
        >
          {marked ? 'Bucket marked' : 'Bucket open'}
        </span>
      </div>
      <KeyDisplay keyValue={period.key} keyError={period.key_error} />
      {period.bucket_key && (
        <p className="text-[10px] font-mono text-slate-600 truncate" title={period.bucket_key}>
          {period.bucket_key}
        </p>
      )}
      <div className="text-[11px] text-slate-500">
        <span>Every: {period.configured.every}</span>
        {marked && period.state?.ttl !== undefined && period.state.ttl >= 0 && (
          <span className="ml-3">TTL: {formatTtl(period.state.ttl)}</span>
        )}
      </div>
    </div>
  );
}

export default function CoordinationPanel({ coordination }: CoordinationPanelProps) {
  if (!coordination || Object.keys(coordination).length === 0) {
    return null;
  }

  return (
    <div className="px-2 shrink-0">
      <div className="rounded-xl border border-slate-800 bg-slate-900/40 p-4">
        <h2 className="text-xs font-semibold uppercase tracking-widest text-slate-500 mb-3">
          Coordination
        </h2>
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3">
          {coordination.lock && <LockCard lock={coordination.lock} />}
          {coordination.semaphore && <SemaphoreCard semaphore={coordination.semaphore} />}
          {coordination.rate_limit && <RateLimitCard rateLimit={coordination.rate_limit} />}
          {coordination.period && <PeriodCard period={coordination.period} />}
        </div>
      </div>
    </div>
  );
}
