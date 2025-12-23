import { useMemo } from 'react';
import { Terminal, Box, ArrowRight, ArrowRightCircle, AlertCircle, RotateCcw, History, ChevronLeft, CheckCircle } from 'lucide-react';



interface UndoStackItem {
  step_name: string;
  arguments: any;
  result: any;
}

interface StepInspectorProps {
  stepName: string | null;
  structure: Record<string, any>;
  results: Record<string, any>;
  trace: any[];
  inputs: Record<string, any>;
  error?: any;
  undoStack?: UndoStackItem[];
  stepAttempts?: Record<string, number>;
  onClose?: () => void;
}

export default function StepInspector({ stepName, structure, results, trace, error, undoStack = [], stepAttempts = {}, onClose }: StepInspectorProps) {
  const stepConfig = stepName ? structure[stepName] : null;
  const result = stepName ? results[stepName] : null;
  const isFailedStep = (error && error.step_name === stepName) ||
    (error?.message?.includes(`Step '${stepName}' failed`));
  const attempts = stepName ? (stepAttempts[stepName] || 0) : 0;
  const retries = attempts > 1 ? attempts - 1 : 0;

  // Find relevant trace events
  const stepEvents = useMemo(() => {
    if (!stepName) return [];
    return trace.filter(e => e.step === stepName);
  }, [stepName, trace]);

  const lastEvent = stepEvents[stepEvents.length - 1];
  const stepArgs = lastEvent?.arguments || (isFailedStep ? error.step_arguments : {});

  // Calculate combined undo history (executed + pending)
  const combinedUndoHistory = useMemo(() => {
    // 1. Find executed undos/compensations from trace
    const executedUndos = trace
      .filter(e => e.type === 'undo' || e.type === 'compensate')
      .map(e => ({
        step_name: e.step,
        result: e.result,
        status: 'executed' as const,
        timestamp: e.timestamp?._type === 'Time' ? e.timestamp.value : null,
        type: e.type as 'undo' | 'compensate'
      }));

    // 2. Map pending stack items
    const pendingUndos = undoStack.map(item => ({
      step_name: item.step_name,
      result: null,
      status: 'pending' as const,
      timestamp: null
    }));

    // Combined list: executed (as they appear in trace) then pending (stack order)
    return [...executedUndos, ...pendingUndos.reverse()];
  }, [trace, undoStack]);

  if (!stepName) {
    return (
      <div className="h-full flex flex-col bg-slate-900/50 backdrop-blur-sm rounded-xl border border-slate-800 overflow-hidden">
        <div className="px-6 py-4 border-b border-slate-800 bg-slate-900/80">
          <div className="flex items-center gap-3">
            <div className="p-2 bg-slate-800 rounded-lg">
              <History className="w-5 h-5 text-slate-400" />
            </div>
            <div>
              <h2 className="font-bold text-white text-lg">Execution Overview</h2>
              <div className="text-xs text-slate-500 font-mono mt-0.5">Global State</div>
            </div>
          </div>
        </div>

        <div className="flex-1 overflow-y-auto p-6 space-y-8">
          {combinedUndoHistory.length > 0 ? (
            <div>
              <h3 className="text-sm font-medium text-slate-400 mb-3 flex items-center gap-2">
                <RotateCcw className="w-4 h-4" />
                Compensation History
              </h3>
              <div className="space-y-2">
                {combinedUndoHistory.map((item, idx) => (
                  <div key={idx} className={`rounded-lg p-3 border flex items-start gap-3 ${item.status === 'executed'
                    ? 'bg-slate-950/50 border-slate-800'
                    : 'bg-slate-900/30 border-slate-800/50 border-dashed opacity-75'
                    }`}>
                    <div className={`p-1.5 rounded mt-0.5 ${item.status === 'executed'
                      ? 'bg-emerald-500/10 text-emerald-400'
                      : 'bg-slate-700/50 text-slate-500'
                      }`}>
                      {item.status === 'executed' ? <CheckCircle className="w-3 h-3" /> : <Box className="w-3 h-3" />}
                    </div>
                    <div className="min-w-0 flex-1">
                      <div className="flex items-center justify-between gap-2">
                        <span className={`font-medium text-sm ${item.status === 'executed' ? 'text-slate-300' : 'text-slate-500'
                          }`}>
                          {item.step_name}
                        </span>
                        <span className="text-[10px] uppercase font-mono tracking-wider px-1.5 py-0.5 rounded bg-slate-800 text-slate-500">
                          {item.status}
                        </span>
                      </div>
                      {item.status === 'executed' && item.result && (
                        <div className="mt-2 bg-black/30 rounded border border-white/5 p-2 font-mono text-xs text-slate-400 overflow-x-auto">
                          {JSON.stringify(item.result, null, 2)}
                        </div>
                      )}
                    </div>
                  </div>
                ))}
              </div>
            </div>
          ) : (
            <div className="h-40 flex flex-col items-center justify-center text-slate-500 border border-slate-800/50 border-dashed rounded-xl bg-slate-900/30">
              <RotateCcw className="w-6 h-6 mb-2 opacity-50" />
              <p className="text-center font-medium text-sm">Undo History Empty</p>
              <p className="text-center text-xs mt-1 text-slate-600">No compensations executed or pending.</p>
            </div>
          )}
        </div>
      </div>
    );
  }

  return (
    <div className="h-full flex flex-col bg-slate-900/50 backdrop-blur-sm rounded-xl border border-slate-800 overflow-hidden">
      <div className="px-6 py-4 border-b border-slate-800 bg-slate-900/80">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            {onClose && (
              <button
                onClick={onClose}
                className="p-1 hover:bg-white/10 rounded-full text-slate-400 hover:text-white transition-colors"
              >
                <ChevronLeft className="w-5 h-5" />
              </button>
            )}
            <div className="p-2 bg-indigo-500/10 rounded-lg">
              <Box className="w-5 h-5 text-indigo-400" />
            </div>
            <div>
              <h2 className="font-bold text-white text-lg">{stepName}</h2>
              <div className="flex items-center gap-2 text-xs text-slate-500 font-mono mt-0.5">
                <span className="uppercase tracking-wider text-indigo-400">{stepConfig?.type || 'UNKNOWN'}</span>
                {stepConfig?.async && <span className="bg-slate-800 px-1.5 py-0.5 rounded text-slate-400">ASYNC</span>}
              </div>
            </div>
          </div>
          {retries > 0 && (
            <div className="flex items-center gap-1.5 px-2.5 py-1 bg-amber-500/10 border border-amber-500/20 rounded-md">
              <span className="text-xs font-medium text-amber-500">Retries: {retries}</span>
            </div>
          )}
        </div>
      </div>

      <div className="flex-1 overflow-y-auto p-6 space-y-8">

        {/* Error Section */}
        {isFailedStep && (
          <div>
            <h3 className="text-sm font-medium text-red-500 mb-3 flex items-center gap-2">
              <AlertCircle className="w-4 h-4" />
              Failure Details
            </h3>
            <div className="bg-red-500/10 rounded-lg p-4 font-mono text-xs border border-red-500/20 text-red-300 overflow-x-auto space-y-2">
              <div className="font-bold">{error.message}</div>
              {error.backtrace && (
                <div className="pt-2 border-t border-red-500/20 text-red-400/70 whitespace-pre-wrap">
                  {error.backtrace.slice(0, 5).join('\n')}
                  {error.backtrace.length > 5 && '\n...'}
                </div>
              )}
            </div>
          </div>
        )}

        {/* Dependencies */}
        {stepConfig?.depends_on?.length > 0 && (
          <div>
            <h3 className="text-sm font-medium text-slate-400 mb-3 flex items-center gap-2">
              <ArrowRightCircle className="w-4 h-4" />
              Dependencies
            </h3>
            <div className="flex flex-wrap gap-2">
              {stepConfig.depends_on.map((dep: string) => (
                <span key={dep} className="px-2 py-1 bg-slate-800 border border-slate-700 rounded text-xs text-slate-300 font-mono">
                  {dep}
                </span>
              ))}
            </div>
          </div>
        )}

        {/* Inputs / Arguments */}
        <div>
          <h3 className="text-sm font-medium text-slate-400 mb-3 flex items-center gap-2">
            <ArrowRight className="w-4 h-4" />
            Arguments
          </h3>
          <div className="bg-slate-950 rounded-lg p-4 font-mono text-xs border border-slate-800 overflow-x-auto">
            <pre className="text-slate-300">{JSON.stringify(stepArgs, null, 2)}</pre>
          </div>
        </div>

        {/* Result */}
        <div>
          <h3 className="text-sm font-medium text-slate-400 mb-3 flex items-center gap-2">
            <Terminal className="w-4 h-4" />
            Result
          </h3>
          {result !== undefined ? (
            <div className="bg-slate-950 rounded-lg p-4 font-mono text-xs border border-slate-800 overflow-x-auto">
              <pre className="text-emerald-400">{JSON.stringify(result, null, 2)}</pre>
            </div>
          ) : (
            <div className="bg-slate-950/50 rounded-lg p-4 font-mono text-xs border border-slate-800/50 text-slate-600 italic">
              {isFailedStep ? <span className="text-red-400">Step Failed</span> : 'No result (Pending or Failed)'}
            </div>
          )}
        </div>

      </div>
    </div>
  );
}
