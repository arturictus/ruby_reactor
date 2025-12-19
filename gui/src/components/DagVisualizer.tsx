import { useMemo } from 'react';
import {
  ReactFlow,
  Background,
  Controls,
  useNodesState,
  useEdgesState,
  MarkerType,
  Handle,
  Position
} from '@xyflow/react';
import '@xyflow/react/dist/style.css';
import { cn } from '../lib/utils';
import { Activity, CheckCircle2, AlertCircle, Clock } from 'lucide-react';

interface DagVisualizerProps {
  structure: Record<string, any>;
  steps: any[];
  currentStep?: string;
  onStepSelect: (stepName: string) => void;
  selectedStep: string | null;
}

const StepNode = ({ data }: { data: any }) => {
  const isSelected = data.selected;
  const status = data.status;

  const statusColors = {
    pending: "border-slate-700 bg-slate-900 text-slate-500",
    running: "border-indigo-500 bg-indigo-500/10 text-indigo-400 ring-2 ring-indigo-500/20",
    completed: "border-teal-500 bg-teal-500/10 text-teal-400",
    failed: "border-rose-500 bg-rose-500/10 text-rose-400",
    cancelled: "border-slate-600 bg-slate-800 text-slate-400"
  };

  const StatusIcon = {
    pending: Clock,
    running: Activity,
    completed: CheckCircle2,
    failed: AlertCircle,
    cancelled: Clock
  }[status as keyof typeof statusColors] || Clock;

  return (
    <div className={cn(
      "px-4 py-3 rounded-lg border shadow-lg transition-all min-w-[180px]",
      statusColors[status as keyof typeof statusColors] || statusColors.pending,
      isSelected && "ring-2 ring-white/20 scale-105"
    )}>
      <Handle type="target" position={Position.Top} className="!bg-slate-500 !w-2 !h-2" />

      <div className="flex items-center gap-3">
        <StatusIcon className={cn(
          "w-4 h-4",
          status === 'running' && "animate-pulse"
        )} />
        <div>
          <div className="font-medium text-sm">{data.label}</div>
          <div className="text-[10px] opacity-70 uppercase tracking-wider">{data.type}</div>
        </div>
      </div>

      <Handle type="source" position={Position.Bottom} className="!bg-slate-500 !w-2 !h-2" />
    </div>
  );
};

const nodeTypes = {
  step: StepNode,
};

// Simple auto-layout helper since we don't have dagre
// This organizes nodes in layers
const getLayoutedElements = (nodes: any[], edges: any[]) => {
  const nodeWidth = 200;
  const nodeHeight = 80;
  const rankSep = 100; // vertical separation
  const nodeSep = 50;  // horizontal separation

  // Calculate ranks (depth) for each node based on dependencies
  const ranks: Record<string, number> = {};

  const getRank = (nodeId: string): number => {
    if (ranks[nodeId] !== undefined) return ranks[nodeId];

    // Find edges pointing to this node
    const incomingEdges = edges.filter(e => e.target === nodeId);
    if (incomingEdges.length === 0) {
      ranks[nodeId] = 0;
      return 0;
    }

    const parentRanks = incomingEdges.map(e => getRank(e.source));
    const rank = Math.max(...parentRanks) + 1;
    ranks[nodeId] = rank;
    return rank;
  };

  nodes.forEach(node => getRank(node.id));

  // Group nodes by rank
  const layers: Record<number, any[]> = {};
  nodes.forEach(node => {
    const rank = ranks[node.id];
    if (!layers[rank]) layers[rank] = [];
    layers[rank].push(node);
  });

  // Assign positions
  return nodes.map(node => {
    const rank = ranks[node.id];
    const layer = layers[rank];
    const indexInLayer = layer.indexOf(node);

    const x = indexInLayer * (nodeWidth + nodeSep) - ((layer.length - 1) * (nodeWidth + nodeSep)) / 2;
    const y = rank * (nodeHeight + rankSep);

    return { ...node, position: { x, y } };
  });
};

export default function DagVisualizer({ structure, steps, onStepSelect, selectedStep }: DagVisualizerProps) {
  // Determine status for each node based on execution trace
  const nodeStatus = useMemo(() => {
    const statusMap: Record<string, string> = {};

    // Initialize all as pending
    Object.keys(structure || {}).forEach(key => statusMap[key] = 'pending');

    // Update based on trace
    (steps || []).forEach(step => {
      // If step is in structure, update status.
      if (structure && structure[step.step]) {
        statusMap[step.step] = 'completed';
      }
    });

    return statusMap;
  }, [structure, steps]);

  const initialNodes = useMemo(() => {
    if (!structure) return [];

    return Object.entries(structure).map(([key, config]: [string, any]) => ({
      id: key,
      type: 'step',
      data: {
        label: key,
        type: config.type,
        status: nodeStatus[key],
        selected: selectedStep === key
      },
      position: { x: 0, y: 0 } // Layouted later
    }));
  }, [structure, nodeStatus, selectedStep]);

  const initialEdges = useMemo(() => {
    if (!structure) return [];

    const edges: any[] = [];
    Object.entries(structure).forEach(([key, config]: [string, any]) => {
      if (Array.isArray(config.depends_on)) {
        config.depends_on.forEach((dep: string) => {
          edges.push({
            id: `${dep}-${key}`,
            source: dep,
            target: key,
            type: 'smoothstep',
            animated: true,
            style: { stroke: '#475569' },
            markerEnd: { type: MarkerType.ArrowClosed, color: '#475569' },
          });
        });
      }
    });
    return edges;
  }, [structure]);

  const [nodes, setNodes, onNodesChange] = useNodesState<any>([]);
  const [edges, setEdges, onEdgesChange] = useEdgesState<any>([]);

  useMemo(() => {
    const layoutedNodes = getLayoutedElements(initialNodes, initialEdges);
    setNodes(layoutedNodes);
    setEdges(initialEdges);
  }, [initialNodes, initialEdges, setNodes, setEdges]);

  return (
    <div className="w-full h-full min-h-[500px] bg-slate-950 rounded-xl overflow-hidden">
      <ReactFlow
        nodes={nodes}
        edges={edges}
        onNodesChange={onNodesChange}
        onEdgesChange={onEdgesChange}
        nodeTypes={nodeTypes}
        onNodeClick={(_, node) => onStepSelect(node.id)}
        fitView
        className="bg-slate-900/50"
      >
        <Background color="#1e293b" gap={16} />
        <Controls className="bg-slate-800 border-slate-700 fill-slate-400 text-slate-400" />
      </ReactFlow>
    </div>
  );
}
