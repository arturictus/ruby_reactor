import useSWR, { mutate } from 'swr';
import { useParams, Link, useNavigate } from 'react-router-dom';
import { ChevronLeft, Play, XOctagon, AlertCircle } from 'lucide-react';
import { useState } from 'react';
import { apiUrl } from '../lib/utils';
import { classRoute, reactorRoute } from '../lib/reactors';
import DagVisualizer from './DagVisualizer';
import StepInspector from './StepInspector';
import CoordinationPanel from './CoordinationPanel';

const fetcher = (url: string) => fetch(url).then((res) => res.json());


export default function ReactorDetail() {
  const { id } = useParams();
  const navigate = useNavigate();
  const { data: reactor, error, isLoading } = useSWR(id ? apiUrl(`/api/reactors/${id}`) : null, fetcher, { refreshInterval: 1000 });
  const [selectedStep, setSelectedStep] = useState<string | null>(null);
  const [isRetrying, setIsRetrying] = useState(false);
  const [retryError, setRetryError] = useState<string | null>(null);

  const handleAction = async (action: 'cancel') => {
    if (!id) return;
    try {
      await fetch(apiUrl(`/api/reactors/${id}/${action}`), { method: 'POST' });
      mutate(apiUrl(`/api/reactors/${id}`));
    } catch (e) {
      console.error(`Failed to ${action}`, e);
    }
  };

  const handleRetry = async () => {
    if (!id || reactor?.status !== 'failed' || isRetrying) return;

    setIsRetrying(true);
    setRetryError(null);

    try {
      const response = await fetch(apiUrl(`/api/reactors/${id}/retry`), { method: 'POST' });
      const payload = await response.json().catch(() => ({}));

      if (!response.ok || !payload.id) {
        setRetryError(payload.error || 'Failed to retry execution');
        return;
      }

      navigate(reactorRoute(payload.id));
    } catch (e) {
      setRetryError('Failed to retry execution');
      console.error('Failed to retry', e);
    } finally {
      setIsRetrying(false);
    }
  };



  if (error) return <div className="p-4 text-red-500 bg-red-500/10 border border-red-500/20 rounded-lg">Failed to load reactor</div>;
  if (isLoading) return <div className="p-4 text-slate-500 animate-pulse">Loading reactor details...</div>;

  return (
    <div className="space-y-6 h-[calc(100vh-8rem)] flex flex-col relative">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 border-b border-slate-800 pb-6 shrink-0">
        <div className="flex items-center gap-4">
          <Link
            to={reactor.class ? classRoute(reactor.class) : '/'}
            className="p-2 hover:bg-white/5 rounded-full text-slate-400 hover:text-white transition-colors"
          >
            <ChevronLeft className="w-5 h-5" />
          </Link>
          <div>
            <div className="flex items-center gap-3">
              <h1 className="text-2xl font-bold text-white tracking-tight">{reactor.class}</h1>
              <span className="px-2 py-0.5 rounded text-xs font-mono bg-slate-800 text-slate-400 border border-slate-700">#{id}</span>
            </div>
            <div className="flex items-center gap-2 mt-1.5">
              <span className="text-sm text-slate-400">Status: <span className={`font-medium ${reactor.status === 'failed' ? 'text-red-400' :
                reactor.status === 'completed' ? 'text-emerald-400' :
                  reactor.status === 'paused' ? 'text-amber-400' :
                    reactor.status === 'skipped' ? 'text-sky-400' :
                      reactor.status === 'pending' ? 'text-slate-400' :
                    'text-slate-200'
                }`}>{reactor.status}</span></span>
              {reactor.retry_count > 0 && (
                <span className="text-sm text-slate-400 ml-3 pl-3 border-l border-slate-700">
                  Retries: <span className="font-medium text-amber-400">{reactor.retry_count}</span>
                </span>
              )}
            </div>
          </div>
        </div>

        <div className="flex items-center gap-2 ml-auto">
          {retryError && (
            <span className="text-xs text-red-400 max-w-xs truncate" title={retryError}>
              {retryError}
            </span>
          )}

          <button
            onClick={handleRetry}
            className="flex items-center gap-2 px-4 py-2 bg-indigo-600 hover:bg-indigo-500 text-white rounded-lg shadow-lg shadow-indigo-500/20 text-sm font-medium transition-all hover:-translate-y-0.5 cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
            disabled={reactor.status !== 'failed' || isRetrying}
          >
            <Play className="w-4 h-4" />
            Retry Execution
          </button>
          <button
            onClick={() => handleAction('cancel')}
            className="flex items-center gap-2 px-4 py-2 bg-slate-900 border border-slate-700 text-slate-300 rounded-lg hover:bg-slate-800 hover:text-white text-sm font-medium transition-colors cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
            disabled={reactor.status !== 'running' && reactor.status !== 'paused'}
          >
            <XOctagon className="w-4 h-4" />
            Cancel
          </button>
        </div>
      </div>

      <CoordinationPanel coordination={reactor.coordination} />

      {reactor.status === 'failed' && reactor.error && (
        <div className="px-2">
          <div className="px-4 py-3 bg-red-500/10 border border-red-500/20 rounded-lg flex items-start gap-3">
            <AlertCircle className="w-5 h-5 text-red-500 shrink-0 mt-0.5" />
            <div className="space-y-1 overflow-hidden">
              <h3 className="text-sm font-medium text-red-500">
                {reactor.error.snooze_attempts != null
                  ? `Coordination contention — ${reactor.error.snooze_attempts} snooze attempts exhausted`
                  : 'Workflow Failed'}
                {reactor.error.step_name && <span className="text-red-400"> at step <span className="font-mono bg-red-500/10 px-1 rounded">{reactor.error.step_name}</span></span>}
              </h3>
              <p className="text-xs text-red-400/80 font-mono truncate">{reactor.error.message || reactor.error.error}</p>
            </div>
          </div>
        </div>
      )}

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6 flex-1 min-h-0">
        <div className="lg:col-span-2 h-full">
          <DagVisualizer
            structure={reactor.structure}
            steps={reactor.steps}
            selectedStep={selectedStep}
            onStepSelect={setSelectedStep}
            reactorStatus={reactor.status}
            error={reactor.error}
            results={reactor.intermediate_results}
            composedContexts={reactor.composed_contexts}
          />
        </div>

        <div className="h-full">
          <StepInspector
            stepName={selectedStep}
            structure={reactor.structure}
            results={reactor.intermediate_results}
            inputs={reactor.inputs}
            trace={reactor.steps}
            error={reactor.error}
            undoStack={reactor.undo_stack}
            stepAttempts={reactor.step_attempts}
            composedContexts={reactor.composed_contexts}
            onClose={() => setSelectedStep(null)}
            reactorId={id}
            reactorStatus={reactor.status}
            onAction={() => mutate(apiUrl(`/api/reactors/${id}`))}
          />
        </div>
      </div>


    </div>
  );
}
