import { useMemo } from 'react';
import { Terminal, Box, ArrowRight, ArrowRightCircle } from 'lucide-react';


interface StepInspectorProps {
  stepName: string | null;
  structure: Record<string, any>;
  results: Record<string, any>;
  trace: any[];
  inputs: Record<string, any>;
}

export default function StepInspector({ stepName, structure, results, trace }: StepInspectorProps) {
  const stepConfig = stepName ? structure[stepName] : null;
  const result = stepName ? results[stepName] : null;

  // Find relevant trace events
  const stepEvents = useMemo(() => {
    if (!stepName) return [];
    return trace.filter(e => e.step === stepName);
  }, [stepName, trace]);

  const lastEvent = stepEvents[stepEvents.length - 1];
  const stepArgs = lastEvent?.arguments || {};

  if (!stepName) {
    return (
      <div className="h-full flex flex-col items-center justify-center text-slate-500 p-8 border border-slate-800 rounded-xl bg-slate-900/50">
        <div className="p-4 bg-slate-900 rounded-full border border-slate-800 mb-4">
          <Box className="w-8 h-8 text-slate-700" />
        </div>
        <p className="text-center font-medium">No Step Selected</p>
        <p className="text-center text-sm mt-1 text-slate-600">Click on a step in the graph to view details.</p>
      </div>
    );
  }

  return (
    <div className="h-full flex flex-col bg-slate-900/50 backdrop-blur-sm rounded-xl border border-slate-800 overflow-hidden">
      <div className="px-6 py-4 border-b border-slate-800 bg-slate-900/80">
        <div className="flex items-center gap-3">
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
      </div>

      <div className="flex-1 overflow-y-auto p-6 space-y-8">

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
              No result (Pending or Failed)
            </div>
          )}
        </div>

      </div>
    </div>
  );
}
