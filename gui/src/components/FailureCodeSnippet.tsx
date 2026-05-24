import { useMemo } from 'react';
import { Code } from 'lucide-react';
import hljs from 'highlight.js/lib/core';
import javascript from 'highlight.js/lib/languages/javascript';
import ruby from 'highlight.js/lib/languages/ruby';
import typescript from 'highlight.js/lib/languages/typescript';
import 'highlight.js/styles/github-dark.min.css';
import { type CodeSnippetLine } from '../lib/failures';

hljs.registerLanguage('javascript', javascript);
hljs.registerLanguage('ruby', ruby);
hljs.registerLanguage('typescript', typescript);

interface FailureCodeSnippetProps {
  snippet: CodeSnippetLine[];
  filePath?: string;
  lineNumber?: number;
}

function languageFromPath(filePath?: string): string {
  if (!filePath) return 'ruby';
  if (filePath.endsWith('.rb') || filePath.endsWith('.rake')) return 'ruby';
  if (filePath.endsWith('.ts') || filePath.endsWith('.tsx')) return 'typescript';
  if (filePath.endsWith('.js') || filePath.endsWith('.jsx')) return 'javascript';
  return 'ruby';
}

function highlightLine(content: string, language: string): string {
  if (!content) return '&nbsp;';

  try {
    return hljs.highlight(content, { language }).value;
  } catch {
    return hljs.highlight(content, { language: 'plaintext' }).value;
  }
}

export default function FailureCodeSnippet({ snippet, filePath, lineNumber }: FailureCodeSnippetProps) {
  const language = useMemo(() => languageFromPath(filePath), [filePath]);
  const fileName = filePath?.split('/').pop();

  return (
    <div>
      <h3 className="text-sm font-medium text-slate-400 mb-3 flex items-center gap-2">
        <Code className="w-4 h-4" />
        Source Code
      </h3>
      <div className="bg-slate-950 rounded-lg border border-slate-800 overflow-hidden">
        {(filePath || lineNumber) && (
          <div className="px-4 py-2 border-b border-slate-800 bg-slate-900/80 flex items-center justify-between gap-2">
            <span className="text-[10px] uppercase font-bold tracking-widest text-slate-500">Location</span>
            <span className="text-xs font-mono text-slate-400 truncate" title={filePath}>
              {fileName}{lineNumber ? `:${lineNumber}` : ''}
            </span>
          </div>
        )}
        <pre className="overflow-x-auto m-0 p-4 text-xs leading-6 bg-transparent">
          <code className={`hljs language-${language} !bg-transparent !p-0 block`}>
            {snippet.map((line, index) => (
              <span
                key={`${line.line_number}-${index}`}
                className={`flex ${line.target ? 'bg-red-500/15 -mx-4 px-4 border-l-2 border-red-400' : ''}`}
              >
                <span
                  className={`select-none w-6 shrink-0 text-right pr-2 ${line.target ? 'text-red-400 font-bold' : 'text-slate-600'}`}
                  aria-hidden="true"
                >
                  {line.target ? '>' : ' '}
                </span>
                <span
                  className={`select-none w-10 shrink-0 text-right pr-4 ${line.target ? 'text-red-400/70' : 'text-slate-600'}`}
                >
                  {line.line_number}
                </span>
                <span
                  className="flex-1 pr-4 whitespace-pre"
                  dangerouslySetInnerHTML={{ __html: highlightLine(line.content, language) }}
                />
              </span>
            ))}
          </code>
        </pre>
      </div>
    </div>
  );
}
