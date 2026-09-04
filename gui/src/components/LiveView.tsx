import useSWR from 'swr';
import { useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { Activity, AlertCircle, Search, Filter } from 'lucide-react';
import { apiUrl } from '../lib/utils';
import { matchesStatusFilter, reactorRoute } from '../lib/reactors';
import StatusBadge from './StatusBadge';

const fetcher = (url: string) => fetch(url).then((res) => res.json());

export default function LiveView() {
  const { data: reactors, error, isLoading } = useSWR(apiUrl('/api/reactors'), fetcher, { refreshInterval: 2000 });
  const [search, setSearch] = useState('');
  const [searchParams, setSearchParams] = useSearchParams();
  const statusFilter = searchParams.get('status') || 'all';

  const filteredReactors = reactors?.filter((reactor: any) => {
    const matchesSearch =
      reactor.id.toLowerCase().includes(search.toLowerCase()) ||
      reactor.class.toLowerCase().includes(search.toLowerCase());

    return matchesSearch && matchesStatusFilter(reactor.status, statusFilter);
  });

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
          <h1 className="text-2xl font-bold text-white tracking-tight">Live Executions</h1>
          <p className="text-slate-400 text-sm mt-1">Real-time view of all reactor runs.</p>
        </div>

        <div className="flex items-center gap-3">
          <div className="relative">
            <Search className="w-4 h-4 absolute left-3 top-1/2 -translate-y-1/2 text-slate-500" />
            <input
              type="text"
              placeholder="Search ID or Class..."
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              className="bg-slate-900/50 border border-slate-800 text-sm rounded-lg pl-9 pr-4 py-2 text-slate-200 placeholder:text-slate-600 focus:outline-none focus:ring-2 focus:ring-indigo-500/50 w-full sm:w-64 transition-all"
            />
          </div>

          <div className="relative">
            <Filter className="w-4 h-4 absolute left-3 top-1/2 -translate-y-1/2 text-slate-500 pointer-events-none" />
            <select
              value={statusFilter}
              onChange={(e) => {
                const next = e.target.value;
                if (next === 'all') {
                  setSearchParams({});
                } else {
                  setSearchParams({ status: next });
                }
              }}
              className="appearance-none bg-slate-900/50 border border-slate-800 text-slate-300 rounded-lg pl-9 pr-8 py-2 hover:bg-slate-800 hover:text-white transition-colors text-sm font-medium focus:outline-none focus:ring-2 focus:ring-indigo-500/50 cursor-pointer"
            >
              <option value="all">All Status</option>
              <option value="success">Success</option>
              <option value="running">Running</option>
              <option value="errors">Errors</option>
              <option value="completed">Completed</option>
              <option value="skipped">Skipped</option>
              <option value="paused">Paused</option>
              <option value="failed">Failed</option>
              <option value="cancelled">Cancelled</option>
            </select>
          </div>
        </div>
      </div>

      <div className="bg-slate-900/50 backdrop-blur-sm rounded-xl border border-slate-800 overflow-hidden shadow-xl shadow-black/20">
        {isLoading ? (
          <div className="p-12 flex items-center justify-center text-slate-500 animate-pulse">
            Loading reactor data...
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead className="bg-slate-900/80 border-b border-slate-800 text-slate-400 font-medium pb-4">
                <tr>
                  <th className="px-6 py-4 font-medium">Reactor ID</th>
                  <th className="px-6 py-4 font-medium">Class Name</th>
                  <th className="px-6 py-4 font-medium">Status</th>
                  <th className="px-6 py-4 font-medium">Failure</th>
                  <th className="px-6 py-4 font-medium">Started</th>
                  <th className="px-6 py-4 text-right font-medium">Actions</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-800/50">
                {filteredReactors?.map((reactor: any) => (
                  <tr key={reactor.id} className="group hover:bg-slate-800/30 transition-colors">
                    <td className="px-6 py-4 font-mono text-slate-500 group-hover:text-indigo-400 transition-colors">
                      <Link to={reactorRoute(reactor.id)} className="block relative">
                        <span className="absolute -left-2 top-1/2 -translate-y-1/2 w-1 h-0 group-hover:h-4 bg-indigo-500 rounded-full transition-all duration-300 opacity-0 group-hover:opacity-100"></span>
                        {reactor.id.substring(0, 8)}...
                      </Link>
                    </td>
                    <td className="px-6 py-4 text-slate-200 font-medium">{reactor.class}</td>
                    <td className="px-6 py-4">
                      <StatusBadge status={reactor.status} />
                    </td>
                    <td className="px-6 py-4 text-slate-400 font-mono text-xs">
                      {reactor.status === 'failed' && reactor.failure && (
                        <div className="flex flex-col">
                          <span className="text-rose-400 font-medium">{reactor.failure.step_name}</span>
                          <span className="text-slate-500 text-[10px] leading-tight opacity-70">{reactor.failure.exception_class}</span>
                        </div>
                      )}
                    </td>
                    <td className="px-6 py-4 text-slate-500 tabular-nums">
                      {new Date(reactor.created_at).toLocaleString()}
                    </td>
                    <td className="px-6 py-4 text-right">
                      <Link
                        to={reactorRoute(reactor.id)}
                        className="inline-flex items-center gap-1.5 text-xs font-medium text-slate-500 hover:text-indigo-400 transition-colors px-3 py-1.5 rounded-md hover:bg-indigo-500/10"
                      >
                        Inspect
                        <span className="sr-only">{reactor.id}</span>
                      </Link>
                    </td>
                  </tr>
                ))}
                {filteredReactors?.length === 0 && (
                  <tr>
                    <td colSpan={6} className="px-6 py-24 text-center">
                      <div className="flex flex-col items-center gap-3 text-slate-500">
                        <div className="p-4 bg-slate-900 rounded-full border border-slate-800">
                          <Activity className="w-6 h-6 text-slate-600" />
                        </div>
                        <p>No active reactors found matching your filters.</p>
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
