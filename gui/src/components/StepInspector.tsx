import { useMemo, useState } from 'react';
import { Terminal, Box, ArrowRight, ArrowRightCircle, AlertCircle, RotateCcw, History, ChevronLeft, CheckCircle, ChevronDown, ChevronUp, Play, Send, Workflow, ExternalLink } from 'lucide-react';
import { apiUrl } from '../lib/utils';
import FailureCodeSnippet from './FailureCodeSnippet';
import { normalizeFailureReason } from '../lib/failures';



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
  composedContexts?: Record<string, any>;
  onClose?: () => void;
  reactorId?: string;
  reactorStatus?: string;
  onAction?: () => void;
}

interface MapResultsSummary {
  _type: 'map_results';
  total: number;
  succeeded: number;
  failed: number;
  failures: any[];
  failures_truncated: boolean;
}

function isMapResults(value: any): value is MapResultsSummary {
  return !!value && typeof value === 'object' && value._type === 'map_results';
}

// A map step's result is a summary, not a value: elements can fail individually
// (each compensating its own steps) while the map itself completes, so the
// counts and the failed elements are the only thing worth showing here.
function MapResultsPanel({ summary }: { summary: MapResultsSummary }) {
  const [expanded, setExpanded] = useState<number | null>(null);

  return (
    <div className="space-y-3">
      <div className="grid grid-cols-3 gap-2">
        {[
          { label: 'elements', value: summary.total, tone: 'text-slate-300' },
          { label: 'succeeded', value: summary.succeeded, tone: 'text-teal-400' },
          { label: 'failed', value: summary.failed, tone: summary.failed > 0 ? 'text-rose-400' : 'text-slate-500' }
        ].map(stat => (
          <div key={stat.label} className="bg-slate-950 rounded-lg border border-slate-800 p-3">
            <div className={`text-xl font-bold font-mono ${stat.tone}`}>{stat.value}</div>
            <div className="text-[10px] uppercase tracking-wider text-slate-500">{stat.label}</div>
          </div>
        ))}
      </div>

      {summary.failed > 0 && (
        <div className="space-y-2">
          <div className="flex items-center justify-between">
            <span className="text-[10px] uppercase font-bold tracking-widest text-rose-400/70">
              Failed elements
            </span>
            {summary.failures_truncated && (
              <span className="text-[10px] text-slate-500 italic">
                showing {summary.failures.length} of {summary.failed}
              </span>
            )}
          </div>

          {summary.failures.map((raw: any, idx: number) => {
            const failure = normalizeFailureReason(raw);
            const isOpen = expanded === idx;

            return (
              <div key={idx} className="bg-rose-500/5 border border-rose-500/20 rounded-lg overflow-hidden">
                <button
                  onClick={() => setExpanded(isOpen ? null : idx)}
                  className="w-full text-left px-3 py-2 flex items-start gap-2 hover:bg-rose-500/10 transition-colors"
                >
                  {isOpen ? <ChevronUp className="w-3 h-3 mt-1 shrink-0 text-rose-400" /> : <ChevronDown className="w-3 h-3 mt-1 shrink-0 text-rose-400" />}
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-2 flex-wrap">
                      {raw.index !== undefined && (
                        <span className="text-[10px] font-mono px-1.5 py-0.5 rounded bg-slate-800 text-slate-400">
                          #{raw.index}
                        </span>
                      )}
                      {failure?.step_name && (
                        <span className="text-[10px] font-mono text-rose-400/80">{failure.step_name}</span>
                      )}
                      {failure?.exception_class && (
                        <span className="text-[10px] font-mono text-slate-500">{failure.exception_class}</span>
                      )}
                    </div>
                    <div className="text-xs text-rose-300 font-mono mt-1 break-words">
                      {failure?.message}
                    </div>
                  </div>
                </button>

                {isOpen && (
                  <div className="px-3 pb-3 space-y-3 border-t border-rose-500/10 pt-3">
                    {failure?.code_snippet && failure.code_snippet.length > 0 && (
                      <FailureCodeSnippet
                        snippet={failure.code_snippet}
                        filePath={failure.file_path}
                        lineNumber={failure.line_number}
                      />
                    )}
                    {raw.inputs && Object.keys(raw.inputs).length > 0 && (
                      <div>
                        <span className="text-[10px] uppercase font-bold tracking-widest text-slate-500">Element inputs</span>
                        <pre className="mt-1 bg-slate-950 rounded p-2 text-xs text-slate-300 overflow-x-auto">
                          {JSON.stringify(raw.inputs, null, 2)}
                        </pre>
                      </div>
                    )}
                    {failure?.backtrace && failure.backtrace.length > 0 && (
                      <div>
                        <span className="text-[10px] uppercase font-bold tracking-widest text-slate-500">Stack trace</span>
                        <div className="mt-1 bg-slate-950 rounded p-2 text-xs text-rose-400/70 font-mono whitespace-pre-wrap max-h-48 overflow-y-auto">
                          {failure.backtrace.join('\n')}
                        </div>
                      </div>
                    )}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

export default function StepInspector({
  stepName,
  structure,
  results,
  trace,
  error,
  undoStack = [],
  stepAttempts = {},
  composedContexts = {},
  onClose,
  reactorId,
  reactorStatus,
  onAction
}: StepInspectorProps) {
  const [showFullBacktrace, setShowFullBacktrace] = useState(false);
  const [resumePayload, setResumePayload] = useState('');
  const [resumeError, setResumeError] = useState<string | null>(null);
  const [isResuming, setIsResuming] = useState(false);

  const handleResume = async () => {
    if (!reactorId || !stepName) return;

    setIsResuming(true);
    setResumeError(null);

    try {
      // Validate JSON
      let payload = {};
      if (resumePayload.trim()) {
        try {
          payload = JSON.parse(resumePayload);
        } catch (e) {
          setResumeError("Invalid JSON payload");
          setIsResuming(false);
          return;
        }
      }

      const response = await fetch(apiUrl(`/api/reactors/${reactorId}/continue`), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          payload: payload,
          step_name: stepName.split('.').pop()
        })
      });

      const data = await response.json();

      if (!response.ok) {
        setResumeError(data.error || "Failed to resume");
      } else {
        setResumePayload('');
        if (onAction) onAction();
        if (onClose) onClose();
      }
    } catch (e) {
      console.error("Failed to resume", e);
      setResumeError("An unexpected error occurred");
    } finally {
      setIsResuming(false);
    }
  };

  // Resolve recursive data based on path
  const resolvedData = useMemo(() => {
    if (!stepName) return null;

    const parts = stepName.split('.');

    const resolve = (pathParts: string[], struct: any, context: any): any => {
      const part = pathParts[0];
      const isLast = pathParts.length === 1;
      const stepConfig = struct?.[part];

      if (isLast) {
        const results = context?.intermediate_results || {};
        const trace = context?.execution_trace || [];
        const attempts = context?.retry_context?.step_attempts || {};

        return {
          stepConfig,
          result: results[part],
          attempts: attempts[part] || 0,
          trace: trace.filter((t: any) => t.step === part),
          // For a dispatched async unit the outcome is NOT in
          // intermediate_results — it lives in the Step Result Record (async_step)
          // or the child's own context row (async_reactor), both already resolved
          // onto this reference by the API's hydration.
          asyncRef: context?.composed_contexts?.[part],
          context: context
        };
      } else {
        const nestedData = context?.composed_contexts?.[part];
        const nestedContext = nestedData?.context?.value || nestedData?.context;

        return resolve(
          pathParts.slice(1),
          stepConfig?.nested_structure,
          nestedContext
        );
      }
    };

    // Initial context mock for root
    const rootContext = {
      composed_contexts: composedContexts,
      failure_reason: error,
      intermediate_results: results,
      execution_trace: trace,
      retry_context: { step_attempts: stepAttempts }
    };

    try {
      return resolve(parts, structure, rootContext);
    } catch (e) {
      console.error("Error resolving step data:", e);
      return null;
    }
  }, [stepName, structure, results, trace, stepAttempts, composedContexts, error]);

  const stepConfig = resolvedData?.stepConfig;
  const result = resolvedData?.result;
  const isFailedStep = (resolvedData?.context?.failure_reason?.step_name === stepName?.split('.').pop());
  const attempts = resolvedData?.attempts || 0;
  const retries = attempts > 1 ? attempts - 1 : 0;

  // `async_step` / `async_reactor` do not run in this execution, so their panel
  // reads from the dispatch reference rather than from intermediate_results.
  const isAsyncUnit = stepConfig?.type === 'async_step' || stepConfig?.type === 'async_reactor';
  const asyncRef = resolvedData?.asyncRef;
  const asyncRecord = asyncRef?.record;
  const asyncChildContext = asyncRef?.context?.value || asyncRef?.context;
  const asyncStatus = asyncRecord?.status || asyncChildContext?.status || 'dispatched';

  // Find relevant trace events
  const stepEvents = resolvedData?.trace || [];

  const lastEvent = stepEvents[stepEvents.length - 1];
  const stepArgs = lastEvent?.arguments || (isFailedStep ? resolvedData?.context?.failure_reason?.step_arguments : {});
  const failureReason = normalizeFailureReason(resolvedData?.context?.failure_reason);
  const codeSnippet = failureReason?.code_snippet;

  // Calculate combined undo history (executed + pending) recursively
  const groupedUndoHistory = useMemo(() => {
    interface UndoItem {
      step_name: string;
      result: any;
      status: 'executed' | 'pending';
      timestamp: string | null;
      type: 'undo' | 'compensate';
    }

    interface ReactorUndoGroup {
      reactorName: string;
      items: UndoItem[];
    }

    const groups: ReactorUndoGroup[] = [];

    const collectUndos = (currentTrace: any[], currentUndoStack: any[], currentComposedContexts: any, reactorName: string) => {
      const executedUndos: UndoItem[] = currentTrace
        .filter(e => e.type === 'undo' || e.type === 'compensate')
        .map(e => ({
          step_name: e.step,
          result: e.result,
          status: 'executed' as const,
          timestamp: e.timestamp?._type === 'Time' ? e.timestamp.value : null,
          type: e.type as 'undo' | 'compensate'
        }));

      const pendingUndos: UndoItem[] = (currentUndoStack || []).map(item => ({
        step_name: item.step_name,
        result: null,
        status: 'pending' as const,
        timestamp: null,
        type: 'undo' as const
      }));

      const items = [...executedUndos, ...pendingUndos.reverse()];
      if (items.length > 0) {
        groups.push({ reactorName, items });
      }

      // Check for undos in composed contexts
      Object.entries(currentComposedContexts || {}).forEach(([name, data]: [string, any]) => {
        const nestedContext = data?.context?.value || data?.context;
        if (nestedContext) {
          collectUndos(
            nestedContext.execution_trace || [],
            nestedContext.undo_stack || [],
            nestedContext.composed_contexts || {},
            name
          );
        }
      });
    };

    collectUndos(trace, undoStack, composedContexts, 'Root Reactor');
    return groups;
  }, [trace, undoStack, composedContexts]);

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
          {groupedUndoHistory.length > 0 ? (
            <div>
              <h3 className="text-sm font-medium text-slate-400 mb-3 flex items-center gap-2">
                <RotateCcw className="w-4 h-4" />
                Compensation History
              </h3>
              <div className="space-y-6">
                {groupedUndoHistory.map((group, groupIdx) => (
                  <div key={groupIdx} className="space-y-3">
                    <div className="flex items-center gap-2 px-2">
                      <div className="h-px flex-1 bg-slate-800"></div>
                      <span className="text-[10px] font-bold uppercase tracking-widest text-slate-500 bg-slate-900/50 px-2 py-0.5 rounded border border-slate-800">
                        {group.reactorName}
                      </span>
                      <div className="h-px flex-1 bg-slate-800"></div>
                    </div>
                    <div className="space-y-2">
                      {group.items.map((item, idx) => (
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
                            <span className={`font-medium text-sm block ${item.status === 'executed' ? 'text-slate-300' : 'text-slate-500'
                              }`}>
                              {item.step_name}
                            </span>
                            <span className="text-[10px] uppercase font-mono tracking-wider px-1.5 py-0.5 rounded bg-slate-800 text-slate-500 inline-flex items-center gap-1.5 mt-1">
                              {item.type && (
                                <span className={`font-bold ${item.type === 'compensate' ? 'text-amber-400' : 'text-indigo-400'}`}>
                                  {item.type}
                                </span>
                              )}
                              <span className="opacity-50">|</span>
                              {item.status}
                            </span>
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
              <h2 className="font-bold text-white text-lg">{stepName?.split('.').pop()}</h2>
              <div className="flex items-center gap-2 text-xs text-slate-500 font-mono mt-0.5">
                <span className="uppercase tracking-wider text-indigo-400">{stepConfig?.type || 'UNKNOWN'}</span>
                {isAsyncUnit && (
                  <span className="bg-slate-800 px-1.5 py-0.5 rounded text-slate-400 flex items-center gap-1">
                    {stepConfig?.type === 'async_reactor' ? <Workflow className="w-3 h-3" /> : <Send className="w-3 h-3" />}
                    DISPATCHED
                  </span>
                )}
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

        {/* Dispatched async unit — its outcome lives outside this execution */}
        {isAsyncUnit && (
          <div className="bg-slate-800/40 rounded-lg border border-slate-700 border-dashed p-4">
            <h3 className="text-sm font-medium text-slate-200 mb-2 flex items-center gap-2">
              {stepConfig?.type === 'async_reactor' ? <Workflow className="w-4 h-4" /> : <Send className="w-4 h-4" />}
              Dispatched independently
            </h3>
            <p className="text-xs text-slate-400 mb-3">
              {stepConfig?.type === 'async_reactor'
                ? 'This child reactor runs on its own and is not part of this reactor\'s compensation graph. Its failure only affects this reactor if a later step reads its result and decides to fail.'
                : 'This step\'s work runs in its own job. This reactor kept executing other ready steps, and a failure here compensates nothing unless a later step reads the result and returns Failure.'}
            </p>

            <dl className="text-xs font-mono space-y-1">
              <div className="flex gap-2">
                <dt className="text-slate-500 w-28">status</dt>
                <dd className="text-slate-300">{asyncStatus}</dd>
              </div>
              {asyncRef?.dispatched_at && (
                <div className="flex gap-2">
                  <dt className="text-slate-500 w-28">dispatched_at</dt>
                  <dd className="text-slate-300">{asyncRef.dispatched_at?.value || String(asyncRef.dispatched_at)}</dd>
                </div>
              )}
              {asyncRef?.execution_id && (
                <div className="flex gap-2">
                  <dt className="text-slate-500 w-28">execution_id</dt>
                  <dd className="text-slate-300 break-all">{asyncRef.execution_id}</dd>
                </div>
              )}
              {asyncRecord && 'success' in asyncRecord && (
                <div className="flex gap-2">
                  <dt className="text-slate-500 w-28">outcome</dt>
                  <dd className={asyncRecord.success ? 'text-teal-400' : 'text-rose-400'}>
                    {asyncRecord.success ? 'Success' : 'Failure'}
                  </dd>
                </div>
              )}
            </dl>

            {asyncRecord?.result !== undefined && (
              <pre className="mt-3 bg-slate-950 rounded p-3 text-xs text-slate-300 overflow-x-auto">
                {JSON.stringify(asyncRecord.result, null, 2)}
              </pre>
            )}

            {asyncRef?.execution_id && (
              <a
                href={`/reactors/${asyncRef.execution_id}`}
                className="mt-3 inline-flex items-center gap-1.5 text-xs text-indigo-400 hover:text-indigo-300 underline"
              >
                Open the linked execution <ExternalLink className="w-3 h-3" />
              </a>
            )}
          </div>
        )}

        {/* Resume Action */}
        {reactorStatus === 'paused' && stepConfig?.type === 'interrupt' && (
          <div className="bg-emerald-500/5 rounded-lg border border-emerald-500/20 p-4">
            <h3 className="text-sm font-medium text-emerald-400 mb-2 flex items-center gap-2">
              <Play className="w-4 h-4" />
              Resume Execution
            </h3>
            <p className="text-xs text-slate-400 mb-3">
              This step is an interrupt point. You can provide a payload and resume execution from here.
            </p>

            <div className="space-y-3">
              <div>
                <label className="text-xs font-mono text-slate-500 mb-1.5 block">Payload (JSON)</label>
                <textarea
                  value={resumePayload}
                  onChange={(e) => setResumePayload(e.target.value)}
                  placeholder='{"key": "value"}'
                  className="w-full h-24 bg-slate-950 border border-slate-800 rounded-lg p-3 text-sm font-mono text-slate-200 focus:outline-none focus:border-emerald-500/50 focus:ring-1 focus:ring-emerald-500/50 font-mono placeholder-slate-700"
                />
              </div>

              {resumeError && (
                <div className="text-xs text-red-400 flex items-center gap-1.5 bg-red-500/10 p-2 rounded border border-red-500/20">
                  <AlertCircle className="w-3 h-3" />
                  {resumeError}
                </div>
              )}

              <button
                onClick={handleResume}
                disabled={isResuming}
                className="w-full py-2 bg-emerald-600 hover:bg-emerald-500 text-white rounded-lg text-sm font-medium shadow-lg shadow-emerald-500/20 transition-all hover:-translate-y-0.5 disabled:opacity-50 disabled:cursor-not-allowed"
              >
                {isResuming ? 'Resuming...' : 'Resume Reactor'}
              </button>
            </div>
          </div>
        )}

        {/* Error Section */}
        {isFailedStep && failureReason && (
          <div className="space-y-4">
            <h3 className="text-sm font-medium text-red-500 mb-3 flex items-center gap-2">
              <AlertCircle className="w-4 h-4" />
              Failure Details
            </h3>
            <div className="bg-red-500/10 rounded-lg p-4 font-mono text-xs border border-red-500/20 text-red-300 overflow-x-auto space-y-2">
              <div className="flex flex-col gap-1">
                {failureReason.exception_class && (
                  <span className="text-[10px] uppercase font-bold tracking-wider text-red-400 opacity-70">
                    {failureReason.exception_class}
                  </span>
                )}
                <div className="font-bold text-sm leading-relaxed">
                  {failureReason.message || failureReason.error}
                </div>
              </div>

              {failureReason.validation_errors && (
                <div className="pt-3 mt-3 border-t border-red-500/10">
                  <span className="text-[10px] uppercase font-bold tracking-widest text-red-400/50 mb-2 block">Validation Errors</span>
                  <div className="space-y-2 bg-red-950/20 rounded p-2">
                    {Object.entries(failureReason.validation_errors).map(([field, messages]: [string, any]) => (
                      <div key={field} className="flex flex-col">
                        <span className="font-bold text-red-400 text-xs">{field}:</span>
                        <div className="pl-2">
                          {Array.isArray(messages) ? (
                            messages.map((msg: string, i: number) => (
                              <div key={i} className="text-red-300/90">- {msg}</div>
                            ))
                          ) : (
                            <div className="text-red-300/90">- {String(messages)}</div>
                          )}
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </div>

            {codeSnippet && codeSnippet.length > 0 && (
              <FailureCodeSnippet
                snippet={codeSnippet}
                filePath={failureReason.file_path}
                lineNumber={failureReason.line_number}
              />
            )}

            {failureReason.backtrace && (
              <div className="bg-red-500/10 rounded-lg p-4 font-mono text-xs border border-red-500/20 text-red-300 overflow-x-auto">
                <div className="flex items-center justify-between mb-2">
                  <span className="text-[10px] uppercase font-bold tracking-widest text-red-400/50">Stack Trace</span>
                  <button
                    onClick={() => setShowFullBacktrace(!showFullBacktrace)}
                    className="flex items-center gap-1 text-[10px] font-bold text-red-400/70 hover:text-red-400 transition-colors uppercase tracking-wider"
                  >
                    {showFullBacktrace ? (
                      <><ChevronUp className="w-3 h-3" /> Show Less</>
                    ) : (
                      <><ChevronDown className="w-3 h-3" /> Show More ({failureReason.backtrace.length} lines)</>
                    )}
                  </button>
                </div>
                <div className="text-red-400/70 whitespace-pre-wrap leading-relaxed max-h-[300px] overflow-y-auto custom-scrollbar">
                  {showFullBacktrace
                    ? failureReason.backtrace.join('\n')
                    : failureReason.backtrace.slice(0, 5).join('\n')
                  }
                  {!showFullBacktrace && failureReason.backtrace.length > 5 && (
                    <div className="mt-1 text-red-400/30 italic">... and {failureReason.backtrace.length - 5} more lines</div>
                  )}
                </div>
              </div>
            )}
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
          {isMapResults(result) ? (
            <MapResultsPanel summary={result} />
          ) : result !== undefined ? (
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
