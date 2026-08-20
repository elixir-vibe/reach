import ELK from "elkjs/lib/elk.bundled.js"

interface ElkNode {
  id: string
  width: number
  height: number
}

interface ElkEdge {
  id: string
  sources: string[]
  targets: string[]
}

interface ElkGraph {
  id: string
  layoutOptions: Record<string, string>
  children: ElkNode[]
  edges: ElkEdge[]
}

const DEFAULT_OPTIONS: Record<string, string> = {
  "elk.algorithm": "layered",
  "elk.direction": "DOWN",
  "elk.layered.spacing.nodeNodeBetweenLayers": "40",
  "elk.spacing.nodeNode": "20",
  "elk.spacing.componentComponent": "30",
  "elk.layered.crossingMinimization.strategy": "LAYER_SWEEP",
  "elk.layered.nodePlacement.strategy": "NETWORK_SIMPLEX",
  "elk.separateConnectedComponents": "true",
  "elk.layered.compaction.connectedComponents": "true",
  "elk.layered.considerModelOrder.strategy": "NODES_AND_EDGES",
  "elk.layered.compaction.postCompaction.strategy": "EDGE_LENGTH",
  "elk.edgeRouting": "ORTHOGONAL",
  "elk.aspectRatio": "0.3",
  "elk.layered.wrapping.strategy": "MULTI_EDGE",
  "elk.layered.wrapping.additionalEdgeSpacing": "20"
}

export async function computeLayout(
  nodeIds: string[],
  nodeSizes: Map<string, { width: number; height: number }>,
  edges: { source: string; target: string; id: string }[],
  overrides: Record<string, string> = {}
): Promise<Map<string, { x: number; y: number }>> {
  const elk = new ELK()

  const children: ElkNode[] = nodeIds.map((id) => {
    const size = nodeSizes.get(id) ?? { width: 200, height: 60 }
    return { id, width: size.width, height: size.height }
  })

  const elkEdges: ElkEdge[] = edges.map((e) => ({
    id: e.id,
    sources: [e.source],
    targets: [e.target]
  }))

  const graph: ElkGraph = {
    id: "root",
    layoutOptions: { ...DEFAULT_OPTIONS, ...overrides },
    children,
    edges: elkEdges
  }

  const result = await elk.layout(graph)
  const positions = new Map<string, { x: number; y: number }>()

  for (const child of result.children ?? []) {
    positions.set(child.id, { x: child.x ?? 0, y: child.y ?? 0 })
  }

  return positions
}
