import { Activity, Clock, AlertCircle, CheckCircle2, SkipForward } from 'lucide-react';
import { cn } from '../lib/utils';

export default function StatusBadge({ status }: { status: string }) {
  const styles = {
    running: "bg-indigo-500/10 text-indigo-400 border-indigo-500/20 shadow-[0_0_10px_rgba(99,102,241,0.15)]",
    completed: "bg-teal-500/10 text-teal-400 border-teal-500/20 shadow-[0_0_10px_rgba(20,184,166,0.15)]",
    skipped: "bg-sky-500/10 text-sky-400 border-sky-500/20 shadow-[0_0_10px_rgba(14,165,233,0.15)]",
    failed: "bg-rose-500/10 text-rose-400 border-rose-500/20 shadow-[0_0_10px_rgba(244,63,94,0.15)]",
    cancelled: "bg-slate-800 text-slate-400 border-slate-700",
    paused: "bg-amber-500/10 text-amber-400 border-amber-500/20",
  }[status] || "bg-slate-800 text-slate-400 border-slate-700";

  const icons = {
    running: <Activity className="w-3 h-3 animate-pulse" />,
    completed: <CheckCircle2 className="w-3 h-3" />,
    skipped: <SkipForward className="w-3 h-3" />,
    failed: <AlertCircle className="w-3 h-3" />,
    cancelled: <Clock className="w-3 h-3" />,
    paused: <Clock className="w-3 h-3" />,
  }[status];

  return (
    <span className={cn("inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-medium border backdrop-blur-md transition-all", styles)}>
      {icons}
      <span className="capitalize tracking-wide">{status}</span>
    </span>
  );
}
