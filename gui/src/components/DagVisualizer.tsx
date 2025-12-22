import { useMemo, useCallback } from 'react';
import {
  ReactFlow,
  Background,
  Controls,
  useNodesState,
  useEdgesState,
  MarkerType,
  Handle,
  Position,
  type Node,
  type Edge
} from '@xyflow/react';
import '@xyflow/react/dist/style.css';
import { cn } from '../lib/utils';
import { Activity, CheckCircle2, AlertCircle, Clock, Ban } from 'lucide-react';

interface DagVisualizerProps {
  structure: Record<string, any>;
  steps: any[];
  currentStep?: string;
  onStepSelect: (stepName: string) => void;
  selectedStep: string | null;
  reactorStatus?: string;
  error?: any;
  results?: Record<string, any>;
}

const StepNode = ({ data }: { data: any }) => {
  const isSelected = data.selected;
  const status = data.status;

  const statusColors = {
    pending: "border-slate-700 bg-slate-900 text-slate-500",
    running: "border-indigo-500 bg-indigo-500/10 text-indigo-400 ring-2 ring-indigo-500/20",
    completed: "border-teal-500 bg-teal-500/10 text-teal-400",
    failed: "border-rose-500 bg-rose-500/10 text-rose-400 shadow-[0_0_15px_rgba(244,63,94,0.2)]",
    cancelled: "border-amber-500/50 bg-amber-500/10 text-amber-500"
  };

  const StatusIcon = {
    pending: Clock,
    running: Activity,
    completed: CheckCircle2,
    failed: AlertCircle,
    cancelled: Ban
  }[status as keyof typeof statusColors] || Clock;

  return (
    <div className={cn(
      "px-4 py-3 rounded-lg border shadow-lg transition-all min-w-[150px]",
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
          <div className="text-[10px] opacity-70 uppercase tracking-wider">
            {status === 'cancelled' ? 'CANCELLED' : data.type}
          </div>
        </div>
      </div>

      <Handle type="source" position={Position.Bottom} className="!bg-slate-500 !w-2 !h-2" />
    </div>
  );
};

const GroupNode = ({ data }: { data: any }) => {
  const isSelected = data.selected;
  const status = data.status;

  const statusBorderColors = {
    pending: "border-slate-700",
    running: "border-indigo-500",
    completed: "border-teal-500",
    failed: "border-rose-500",
    cancelled: "border-amber-500/50"
  };

  return (
    <div className={cn(
      "px-4 py-8 rounded-xl border-2 border-dashed transition-all relative",
      "bg-slate-900/50 backdrop-blur-sm",
      statusBorderColors[status as keyof typeof statusBorderColors] || statusBorderColors.pending,
      isSelected && "ring-2 ring-white/20"
    )} style={{ width: '100%', height: '100%' }}>
      {/* Visual Group Label */}
      <div className="absolute top-0 left-0 bg-slate-800 px-3 py-1 rounded-br-lg text-xs font-bold text-slate-300 border-b border-r border-slate-700">
        {data.label} ({data.type})
      </div>

      {/* Handles for connecting to the group as a whole step */}
      <Handle type="target" position={Position.Top} className="!bg-slate-500 !w-2 !h-2" style={{ top: -10 }} />
      <Handle type="source" position={Position.Bottom} className="!bg-slate-500 !w-2 !h-2" style={{ bottom: -10 }} />
    </div>
  );
};

const nodeTypes = {
  step: StepNode,
  group: GroupNode
};

// --- Recursive Processing & Layout ---

const NODE_WIDTH = 200;
const NODE_HEIGHT = 80;
const GROUP_PADDING = 40;
const RANK_SEP = 100; // vertical
const NODE_SEP = 50;  // horizontal

interface LayoutResult {
  nodes: Node[];
  edges: Edge[];
  width: number;
  height: number;
}

const performLayout = (
  nodes: Record<string, any>,
  parentId: string | null = null,
  nodeStatus: Record<string, string>
): LayoutResult => {
  if (!nodes || Object.keys(nodes).length === 0) {
    return { nodes: [], edges: [], width: 0, height: 0 };
  }

  const resultNodes: Node[] = [];
  const resultEdges: Edge[] = [];

  // 1. Identify nodes and recursion
  const currentLevelNodes: any[] = [];

  Object.entries(nodes).forEach(([key, config]: [string, any]) => {
    // Check for nested structure
    let childLayout: LayoutResult | null = null;
    let width = NODE_WIDTH;
    let height = NODE_HEIGHT;

    if (config.nested_structure) {
      // Recurse
      childLayout = performLayout(config.nested_structure, key, nodeStatus);
      width = childLayout.width + GROUP_PADDING * 2;
      height = childLayout.height + GROUP_PADDING * 2 + 30; // 30 for label header

      // Add child edges (nodes added later to preserve z-index)
      resultEdges.push(...childLayout.edges);
    }

    currentLevelNodes.push({
      key,
      config,
      width,
      height,
      childLayout
    });
  });

  // 2. Compute Ranks (Vertical Layers) for current level
  const ranks: Record<string, number> = {};

  const getRank = (nodeKey: string, visited = new Set<string>()): number => {
    if (visited.has(nodeKey)) return 0; // Cycle protection
    if (ranks[nodeKey] !== undefined) return ranks[nodeKey];

    visited.add(nodeKey);
    const config = nodes[nodeKey];
    if (!config || !config.depends_on || config.depends_on.length === 0) {
      ranks[nodeKey] = 0;
      return 0;
    }

    // Only consider deps present in current level
    const relevantDeps = config.depends_on.filter((d: string) => nodes[d]);
    if (relevantDeps.length === 0) {
      ranks[nodeKey] = 0;
      return 0;
    }

    const parentRanks = relevantDeps.map((d: string) => getRank(d, new Set(visited)));
    const rank = Math.max(...parentRanks) + 1;
    ranks[nodeKey] = rank;
    return rank;
  };

  currentLevelNodes.forEach(n => getRank(n.key));

  // 3. Group by Rank
  const layers: Record<number, any[]> = {};
  currentLevelNodes.forEach(N => {
    const rank = ranks[N.key];
    if (!layers[rank]) layers[rank] = [];
    layers[rank].push(N);
  });

  // 4. Assign Positions
  // We need to calculate cumulative height for Y, and center for X

  let currentY = 0;
  let maxLayerWidth = 0;

  const sortedRanks = Object.keys(layers).map(Number).sort((a, b) => a - b);

  sortedRanks.forEach(rank => {
    const layerNodes = layers[rank];
    // Calculate total width of this layer
    const layerWidth = layerNodes.reduce((sum, n) => sum + n.width + NODE_SEP, 0) - NODE_SEP;
    maxLayerWidth = Math.max(maxLayerWidth, layerWidth);

    let currentX = -layerWidth / 2; // Center alignment

    // Find max height in this layer to determine row height
    const layerHeight = Math.max(...layerNodes.map(n => n.height));

    layerNodes.forEach(N => {
      // Create the Node
      const isGroup = !!N.childLayout;
      const type = isGroup ? 'group' : 'step';

      const node: Node = {
        id: N.key,
        type: type,
        data: {
          label: N.key,
          type: N.config.type,
          status: nodeStatus[N.key] || 'pending',
          selected: false // handled by parent check
        },
        position: { x: currentX + N.width / 2 - (isGroup ? N.width / 2 : NODE_WIDTH / 2), y: currentY },
        // For groups, we need to set style width/height
        style: isGroup ? { width: N.width, height: N.height } : undefined,
        parentId: parentId || undefined,
        extent: parentId ? 'parent' : undefined,
      };

      // If group, we need to offset its children to be inside the group
      if (N.childLayout) {
        // The layout of children was 0-indexed. We need to center them inside this group node?
        // ReactFlow relative position means x,y relative to parent top-left.
        // Current childLayout was centered around 0,0 or similar.
        // We should probably re-normalize child positions to be positive relative to padding.

        // Let's assume childLayout generated pos where minX might be negative.
        // We need to shift all children so they fit nicely within (GROUP_PADDING, GROUP_PADDING + header)

        const minChildX = Math.min(...N.childLayout.nodes.map((n: Node) => n.position.x));
        const minChildY = Math.min(...N.childLayout.nodes.map((n: Node) => n.position.y));

        // Shift children to be inside the group
        const xOffset = -minChildX + GROUP_PADDING;
        const yOffset = -minChildY + GROUP_PADDING + 30;

        N.childLayout.nodes.forEach((childNode: Node) => {
          childNode.position.x += xOffset;
          childNode.position.y += yOffset;
        });
      }

      resultNodes.push(node);

      if (N.childLayout) {
        resultNodes.push(...N.childLayout.nodes);
      }

      currentX += N.width + NODE_SEP;
    });

    currentY += layerHeight + RANK_SEP;
  });

  // 5. Generate Edges for current level
  Object.entries(nodes).forEach(([key, config]: [string, any]) => {
    if (config.depends_on) {
      config.depends_on.forEach((dep: string) => {
        // Create edge if dep exists in this level
        if (nodes[dep]) {
          resultEdges.push({
            id: `${dep}-${key}`,
            source: dep,
            target: key,
            type: 'smoothstep',
            animated: true,
            style: { stroke: '#475569' },
            markerEnd: { type: MarkerType.ArrowClosed, color: '#475569' },
          });
        }
      });
    }
  });

  return {
    nodes: resultNodes,
    edges: resultEdges,
    width: maxLayerWidth,
    height: currentY
  };
};


export default function DagVisualizer({ structure, steps, onStepSelect, selectedStep, reactorStatus, error, results }: DagVisualizerProps) {
  console.log('DagVisualizer Render. Status:', reactorStatus, 'Error type:', typeof error, 'Error:', error);

  const nodeStatus = useMemo(() => {
    const statusMap: Record<string, string> = {};

    const processLevel = (str: any) => {
      Object.keys(str || {}).forEach(key => {
        statusMap[key] = 'pending';
        if (str[key].nested_structure) processLevel(str[key].nested_structure);
      });
    };
    processLevel(structure);

    (steps || []).forEach(step => {
      // Only mark as completed if we have a result for this step
      if (results && results[step.step]) {
        statusMap[step.step] = 'completed';
      } else if (reactorStatus === 'running') {
        statusMap[step.step] = 'running';
      }
    });

    // Check for failed step
    let failedStepName = error?.step_name;

    // Fallback: try to parse from message if not provided
    if (!failedStepName && error?.message) {
      const match = error.message.match(/Step '([^']+)' failed/);
      if (match) {
        failedStepName = match[1];
      }
    }

    if (failedStepName) {
      statusMap[failedStepName] = 'failed';
    }

    // Check for cancelled/skipped
    if (reactorStatus === 'failed' || reactorStatus === 'cancelled') {
      // Any step that is still pending should be marked as cancelled
      Object.keys(statusMap).forEach(key => {
        if (statusMap[key] === 'pending') {
          statusMap[key] = 'cancelled';
        }
      });
    }

    return statusMap;
  }, [structure, steps, reactorStatus, error, results]);

  const { nodes, edges } = useMemo(() => {
    if (!structure) return { nodes: [], edges: [] };

    const layout = performLayout(structure, null, nodeStatus);

    // Post-process to set selection state which changes dynamically
    const finalNodes = layout.nodes.map(n => ({
      ...n,
      data: {
        ...n.data,
        selected: selectedStep === n.id
      }
    }));

    return { nodes: finalNodes, edges: layout.edges };
  }, [structure, nodeStatus, selectedStep]);

  const [nodesState, setNodes, onNodesChange] = useNodesState<Node>([]);
  const [edgesState, setEdges, onEdgesChange] = useEdgesState<Edge>([]);

  useMemo(() => {
    setNodes(nodes);
    setEdges(edges);
  }, [nodes, edges, setNodes, setEdges]);

  const onNodeClick = useCallback((_: any, node: Node) => {
    onStepSelect(node.id);
  }, [onStepSelect]);

  return (
    <div className="w-full h-full min-h-[500px] bg-slate-950 rounded-xl overflow-hidden">
      <ReactFlow
        nodes={nodesState}
        edges={edgesState}
        onNodesChange={onNodesChange}
        onEdgesChange={onEdgesChange}
        nodeTypes={nodeTypes}
        onNodeClick={onNodeClick}
        fitView
        className="bg-slate-900/50"
      >
        <Background color="#1e293b" gap={16} />
        <Controls className="bg-slate-800 border-slate-700 fill-slate-400 text-slate-400" />
      </ReactFlow>
    </div>
  );
}
