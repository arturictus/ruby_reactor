import { useState } from 'react';
import { AlertCircle, ChevronDown, ChevronUp } from 'lucide-react';
import FailureCodeSnippet from './FailureCodeSnippet';
import { type FailureReason } from '../lib/failures';

interface FailureDetailsProps {
  failure: FailureReason;
}

export default function FailureDetails({ failure }: FailureDetailsProps) {
  const [showFullBacktrace, setShowFullBacktrace] = useState(false);
  const codeSnippet = failure.code_snippet;

  return (
    <div className="space-y-4">
      <h3 className="text-sm font-medium text-red-500 mb-3 flex items-center gap-2">
        <AlertCircle className="w-4 h-4" />
        Failure Details
      </h3>
      <div className="bg-red-500/10 rounded-lg p-4 font-mono text-xs border border-red-500/20 text-red-300 overflow-x-auto space-y-2">
        <div className="flex flex-col gap-1">
          {failure.exception_class && (
            <span className="text-[10px] uppercase font-bold tracking-wider text-red-400 opacity-70">
              {failure.exception_class}
            </span>
          )}
          <div className="font-bold text-sm leading-relaxed">
            {failure.message || failure.error}
          </div>
        </div>

        {failure.validation_errors && (
          <div className="pt-3 mt-3 border-t border-red-500/10">
            <span className="text-[10px] uppercase font-bold tracking-widest text-red-400/50 mb-2 block">Validation Errors</span>
            <div className="space-y-2 bg-red-950/20 rounded p-2">
              {Object.entries(failure.validation_errors).map(([field, messages]: [string, string | string[]]) => (
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
          filePath={failure.file_path}
          lineNumber={failure.line_number}
        />
      )}

      {failure.backtrace && (
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
                <><ChevronDown className="w-3 h-3" /> Show More ({failure.backtrace.length} lines)</>
              )}
            </button>
          </div>
          <div className="text-red-400/70 whitespace-pre-wrap leading-relaxed max-h-[300px] overflow-y-auto custom-scrollbar">
            {showFullBacktrace
              ? failure.backtrace.join('\n')
              : failure.backtrace.slice(0, 5).join('\n')
            }
            {!showFullBacktrace && failure.backtrace.length > 5 && (
              <div className="mt-1 text-red-400/30 italic">... and {failure.backtrace.length - 5} more lines</div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
