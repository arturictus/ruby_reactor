import useSWR from 'swr';
import { useParams, Link } from 'react-router-dom';
import { ChevronLeft, Play, XOctagon, Share2, MoreHorizontal } from 'lucide-react';

const fetcher = (url: string) => fetch(url).then((res) => res.json());

export default function ReactorDetail() {
  const { id } = useParams();
  const { data: reactor, error, isLoading } = useSWR(id ? `/api/reactors/${id}` : null, fetcher);

  if (error) return <div className="p-4 text-red-500 bg-red-500/10 border border-red-500/20 rounded-lg">Failed to load reactor</div>;
  if (isLoading) return <div className="p-4 text-slate-500 animate-pulse">Loading reactor details...</div>;

  return (
    <div className="space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 border-b border-slate-800 pb-6">
        <div className="flex items-center gap-4">
          <Link to="/" className="p-2 hover:bg-white/5 rounded-full text-slate-400 hover:text-white transition-colors">
            <ChevronLeft className="w-5 h-5" />
          </Link>
          <div>
            <div className="flex items-center gap-3">
              <h1 className="text-2xl font-bold text-white tracking-tight">{reactor.class}</h1>
              <span className="px-2 py-0.5 rounded text-xs font-mono bg-slate-800 text-slate-400 border border-slate-700">#{id}</span>
            </div>
            <div className="flex items-center gap-2 mt-1.5">
              <span className="text-sm text-slate-400">Status: <span className="text-slate-200 font-medium">{reactor.status}</span></span>
            </div>
          </div>
        </div>

        <div className="flex items-center gap-2 ml-auto">
          <button className="flex items-center gap-2 px-4 py-2 bg-indigo-600 hover:bg-indigo-500 text-white rounded-lg shadow-lg shadow-indigo-500/20 text-sm font-medium transition-all hover:-translate-y-0.5">
            <Play className="w-4 h-4" />
            Retry Execution
          </button>
          <button className="flex items-center gap-2 px-4 py-2 bg-slate-900 border border-slate-700 text-slate-300 rounded-lg hover:bg-slate-800 hover:text-white text-sm font-medium transition-colors">
            <XOctagon className="w-4 h-4" />
            Cancel
          </button>
          <button className="p-2 text-slate-400 hover:text-white hover:bg-white/5 rounded-lg transition-colors">
            <MoreHorizontal className="w-5 h-5" />
          </button>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <div className="lg:col-span-2 bg-slate-900/50 backdrop-blur-sm rounded-xl border border-slate-800 p-8 min-h-[500px] flex flex-col items-center justify-center text-slate-500 relative overflow-hidden group">
          <div className="absolute inset-0 bg-grid-slate-800/[0.25] [mask-image:linear-gradient(0deg,transparent,black)]"></div>
          <div className="relative z-10 flex flex-col items-center gap-4">
            <Share2 className="w-12 h-12 text-slate-700 group-hover:text-indigo-500/50 transition-colors duration-700" />
            <p>DAG Visualization Placeholder</p>
          </div>
        </div>

        <div className="space-y-6">
          <div className="bg-slate-900/50 backdrop-blur-sm rounded-xl border border-slate-800 p-6 h-full">
            <h2 className="font-semibold text-white mb-4 flex items-center gap-2">
              <span className="w-1 h-4 bg-indigo-500 rounded-full"></span>
              Step Details
            </h2>
            <div className="text-slate-500 text-sm py-8 text-center border-2 border-dashed border-slate-800 rounded-lg">
              Select a step in the graph to view details.
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
