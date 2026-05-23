import useSWR from 'swr';
import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { Activity, AlertCircle, Search, ChevronRight } from 'lucide-react';
import { apiUrl } from '../lib/utils';
import { aggregateByClass, classRoute, type ReactorSummary } from '../lib/reactors';

const fetcher = (url: string) => fetch(url).then((res) => res.json());

export default function Dashboard() {
  const { data: reactors, error, isLoading } = useSWR<ReactorSummary[]>(apiUrl('/api/reactors'), fetcher, { refreshInterval: 2000 });
  const [search, setSearch] = useState('');

  const aggregates = useMemo(
    () => aggregateByClass(reactors ?? []).filter((row) =>
      row.className.toLowerCase().includes(search.toLowerCase())
    ),
    [reactors, search]
  );

  const totals = useMemo(() => {
    return aggregates.reduce(
      (acc, row) => ({
        runs: acc.runs + row.runs,
        success: acc.success + row.success,
        running: acc.running + row.running,
        errors: acc.errors + row.errors,
      }),
      { runs: 0, success: 0, running: 0, errors: 0 }
    );
  }, [aggregates]);

  if (error) return (
    <div className="p-4 rounded-lg bg-red-500/10 border border-red-500/20 text-red-400 flex items-center gap-2">
      <AlertCircle className="w-5 h-5" />
      Failed to load reactors
    </div>
  );

  return (
    <div className="space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-white tracking-tight">Dashboard</h1>
          <p className="text-slate-400 text-sm mt-1">Reactor classes grouped with execution counts.</p>
        </div>

        <div className="relative">
          <Search className="w-4 h-4 absolute left-3 top-1/2 -translate-y-1/2 text-slate-500" />
          <input
            type="text"
            placeholder="Search class name..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="bg-slate-900/50 border border-slate-800 text-sm rounded-lg pl-9 pr-4 py-2 text-slate-200 placeholder:text-slate-600 focus:outline-none focus:ring-2 focus:ring-indigo-500/50 w-full sm:w-64 transition-all"
          />
        </div>
      </div>

      <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
        <SummaryCard label="Total Runs" value={totals.runs} />
        <SummaryCard label="Success" value={totals.success} tone="success" />
        <SummaryCard label="Running" value={totals.running} tone="running" />
        <SummaryCard label="Errors" value={totals.errors} tone="error" />
      </div>

      <div className="bg-slate-900/50 backdrop-blur-sm rounded-xl border border-slate-800 overflow-hidden shadow-xl shadow-black/20">
        {isLoading ? (
          <div className="p-12 flex items-center justify-center text-slate-500 animate-pulse">
            Loading reactor data...
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead className="bg-slate-900/80 border-b border-slate-800 text-slate-400 font-medium">
                <tr>
                  <th className="px-6 py-4 font-medium">Class Name</th>
                  <th className="px-6 py-4 font-medium text-right tabular-nums">Runs</th>
                  <th className="px-6 py-4 font-medium text-right tabular-nums">Success</th>
                  <th className="px-6 py-4 font-medium text-right tabular-nums">Running</th>
                  <th className="px-6 py-4 font-medium text-right tabular-nums">Errors</th>
                  <th className="px-6 py-4 w-10"></th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-800/50">
                {aggregates.map((row) => (
                  <tr key={row.className} className="group hover:bg-slate-800/30 transition-colors">
                    <td className="px-6 py-4">
                      <Link
                        to={classRoute(row.className)}
                        className="flex items-center gap-2 text-slate-200 font-medium group-hover:text-indigo-400 transition-colors"
                      >
                        <span className="absolute -left-2 w-1 h-0 group-hover:h-4 bg-indigo-500 rounded-full transition-all duration-300 opacity-0 group-hover:opacity-100"></span>
                        {row.className}
                      </Link>
                    </td>
                    <td className="px-6 py-4 text-right text-slate-300 tabular-nums">{row.runs}</td>
                    <td className="px-6 py-4 text-right text-teal-400 tabular-nums">{row.success}</td>
                    <td className="px-6 py-4 text-right text-indigo-400 tabular-nums">{row.running}</td>
                    <td className="px-6 py-4 text-right text-rose-400 tabular-nums">{row.errors}</td>
                    <td className="px-6 py-4 text-slate-600 group-hover:text-indigo-400 transition-colors">
                      <Link to={classRoute(row.className)} aria-label={`View ${row.className} instances`}>
                        <ChevronRight className="w-4 h-4" />
                      </Link>
                    </td>
                  </tr>
                ))}
                {aggregates.length === 0 && (
                  <tr>
                    <td colSpan={6} className="px-6 py-24 text-center">
                      <div className="flex flex-col items-center gap-3 text-slate-500">
                        <div className="p-4 bg-slate-900 rounded-full border border-slate-800">
                          <Activity className="w-6 h-6 text-slate-600" />
                        </div>
                        <p>No reactor classes found matching your search.</p>
                      </div>
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}

function SummaryCard({ label, value, tone }: { label: string; value: number; tone?: 'success' | 'running' | 'error' }) {
  const valueClass = tone === 'success'
    ? 'text-teal-400'
    : tone === 'running'
      ? 'text-indigo-400'
      : tone === 'error'
        ? 'text-rose-400'
        : 'text-white';

  return (
    <div className="bg-slate-900/50 border border-slate-800 rounded-xl px-4 py-3">
      <p className="text-xs text-slate-500 uppercase tracking-wide">{label}</p>
      <p className={`text-2xl font-bold tabular-nums mt-1 ${valueClass}`}>{value}</p>
    </div>
  );
}
