import { forceSimulation, forceLink, forceManyBody, forceCenter, SimulationNodeDatum, SimulationLinkDatum } from "d3-force";
import { select, Selection } from "d3-selection";
import { zoom, zoomIdentity, ZoomBehavior } from "d3-zoom";
import { drag } from "d3-drag";
import { CallGraphEdge, CallGraphMfa, CallGraphNode, CallGraphSnapshot, WebviewToHostMessage } from "./callGraph";

declare function acquireVsCodeApi(): {
  postMessage(message: WebviewToHostMessage): void;
};

interface FunctionSimNode extends CallGraphNode, SimulationNodeDatum {
  id: string;
}

interface ModuleSimNode extends SimulationNodeDatum {
  id: string;
  module: string;
  origin: "workspace" | "external";
  functionCount: number;
}

type SimNode = FunctionSimNode | ModuleSimNode;

interface SimLink<N extends SimNode> extends SimulationLinkDatum<N> {
  source: string | N;
  target: string | N;
}

type ViewMode =
  | { kind: "modules" }
  | { kind: "module-detail"; module: string };

const vscode = acquireVsCodeApi();

let snapshot: CallGraphSnapshot | undefined;
let viewMode: ViewMode = { kind: "modules" };
let searchTerm = "";

function functionNodeId(node: CallGraphMfa): string {
  return `${node.module}:${node.function}/${node.arity}`;
}

function render(): void {
  if (!snapshot) {
    return;
  }
  if (viewMode.kind === "modules") {
    renderModules(snapshot);
  } else {
    renderModuleDetail(snapshot, viewMode.module);
  }
}

function renderModules(fullSnapshot: CallGraphSnapshot): void {
  const originByModule = new Map<string, "workspace" | "external">();
  const countByModule = new Map<string, number>();
  for (const node of fullSnapshot.nodes) {
    originByModule.set(node.module, node.origin);
    countByModule.set(node.module, (countByModule.get(node.module) ?? 0) + 1);
  }

  const nodes: ModuleSimNode[] = Array.from(originByModule.entries()).map(
    ([module, origin]) => ({
      id: module,
      module,
      origin,
      functionCount: countByModule.get(module) ?? 0,
    })
  );

  const edgeKeys = new Set<string>();
  const links: SimLink<ModuleSimNode>[] = [];
  for (const edge of fullSnapshot.edges) {
    if (edge.caller.module === edge.callee.module) {
      continue;
    }
    const key = `${edge.caller.module}->${edge.callee.module}`;
    if (edgeKeys.has(key)) {
      continue;
    }
    edgeKeys.add(key);
    links.push({ source: edge.caller.module, target: edge.callee.module });
  }

  renderGraph<ModuleSimNode>({
    nodes,
    links,
    radius: (node) => 6 + Math.min(Math.sqrt(node.functionCount) * 2, 20),
    label: (node) => `${node.module} (${node.functionCount})`,
    matchesSearch: (node) => node.module.toLowerCase().includes(searchTerm),
    onClick: (node) => {
      if (node.origin === "workspace") {
        viewMode = { kind: "module-detail", module: node.module };
        updateBackButton();
        render();
      }
    },
  });
}

function renderModuleDetail(fullSnapshot: CallGraphSnapshot, module: string): void {
  const inModule = (mfa: CallGraphMfa) => mfa.module === module;

  const coreNodes = fullSnapshot.nodes.filter((node) => inModule(node));
  const coreIds = new Set(coreNodes.map((node) => functionNodeId(node)));

  const relevantEdges = fullSnapshot.edges.filter(
    (edge) => inModule(edge.caller) || inModule(edge.callee)
  );

  const neighborIds = new Set<string>();
  for (const edge of relevantEdges) {
    if (inModule(edge.caller) && !inModule(edge.callee)) {
      neighborIds.add(functionNodeId(edge.callee));
    }
    if (inModule(edge.callee) && !inModule(edge.caller)) {
      neighborIds.add(functionNodeId(edge.caller));
    }
  }
  const neighborNodes = fullSnapshot.nodes.filter(
    (node) => !inModule(node) && neighborIds.has(functionNodeId(node))
  );

  const nodesById = new Map<string, FunctionSimNode>();
  for (const node of [...coreNodes, ...neighborNodes]) {
    nodesById.set(functionNodeId(node), { ...node, id: functionNodeId(node) });
  }

  const links: SimLink<FunctionSimNode>[] = relevantEdges
    .filter(
      (edge) =>
        nodesById.has(functionNodeId(edge.caller)) &&
        nodesById.has(functionNodeId(edge.callee))
    )
    .map((edge) => ({
      source: functionNodeId(edge.caller),
      target: functionNodeId(edge.callee),
    }));

  renderGraph<FunctionSimNode>({
    nodes: Array.from(nodesById.values()),
    links,
    radius: (node) => (coreIds.has(node.id) ? 6 : 4),
    label: (node) => `${node.module}:${node.function}/${node.arity}`,
    matchesSearch: (node) =>
      `${node.module}:${node.function}`.toLowerCase().includes(searchTerm),
    dimmed: (node) => !coreIds.has(node.id),
    onClick: (node) => {
      if (node.origin === "workspace" && node.uri && node.line) {
        vscode.postMessage({
          type: "jumpToDefinition",
          uri: node.uri,
          line: node.line,
        });
      }
    },
  });
}

interface RenderOptions<N extends SimNode> {
  nodes: N[];
  links: SimLink<N>[];
  radius: (node: N) => number;
  label: (node: N) => string;
  matchesSearch: (node: N) => boolean;
  dimmed?: (node: N) => boolean;
  onClick: (node: N) => void;
}

function shortenedTarget<N extends SimNode>(
  link: SimLink<N>,
  radius: (node: N) => number
): { x: number; y: number } {
  const source = link.source as N;
  const target = link.target as N;
  const sourceX = source.x ?? 0;
  const sourceY = source.y ?? 0;
  const targetX = target.x ?? 0;
  const targetY = target.y ?? 0;
  const dx = targetX - sourceX;
  const dy = targetY - sourceY;
  const distance = Math.sqrt(dx * dx + dy * dy) || 1;
  const pullBack = radius(target) + 4;
  const ratio = Math.max(distance - pullBack, 0) / distance;
  return { x: sourceX + dx * ratio, y: sourceY + dy * ratio };
}

function renderGraph<N extends SimNode>(options: RenderOptions<N>): void {
  const svgElement = document.querySelector("svg");
  if (!svgElement) {
    return;
  }
  svgElement.innerHTML = "";

  const width = window.innerWidth;
  const height = window.innerHeight;

  const svg = select(svgElement).attr("viewBox", [0, 0, width, height]);

  svg
    .append("defs")
    .append("marker")
    .attr("id", "arrow")
    .attr("viewBox", "0 -5 10 10")
    .attr("refX", 10)
    .attr("refY", 0)
    .attr("markerWidth", 6)
    .attr("markerHeight", 6)
    .attr("orient", "auto")
    .append("path")
    .attr("d", "M0,-5L10,0L0,5")
    .attr("class", "arrow-head");

  const rootGroup = svg.append("g");

  const zoomBehavior: ZoomBehavior<SVGSVGElement, unknown> = zoom<
    SVGSVGElement,
    unknown
  >()
    .scaleExtent([0.05, 8])
    .on("zoom", (event) => {
      rootGroup.attr("transform", event.transform);
    });
  svg.call(zoomBehavior as any);
  svg.call(zoomBehavior.transform as any, zoomIdentity);

  const linkSelection = rootGroup
    .append("g")
    .attr("class", "links")
    .selectAll("line")
    .data(options.links)
    .join("line")
    .attr("class", "link")
    .attr("marker-end", "url(#arrow)");

  const nodeSelection = rootGroup
    .append("g")
    .attr("class", "nodes")
    .selectAll<SVGGElement, N>("g")
    .data(options.nodes)
    .join("g")
    .attr("class", (node: N) => `node ${node.origin}`)
    .classed("dimmed", (node: N) => options.dimmed?.(node) ?? false)
    .on("click", (_event: MouseEvent, node: N) => options.onClick(node));

  nodeSelection.append("circle").attr("r", options.radius);
  nodeSelection
    .append("text")
    .attr("dx", (node: N) => options.radius(node) + 3)
    .attr("dy", 3)
    .text(options.label);

  applySearchHighlight(nodeSelection, options.matchesSearch);

  nodeSelection.call(
    drag<SVGGElement, N>()
      .clickDistance(4)
      .on("start", (event, node) => {
        if (!event.active) {
          simulation.alphaTarget(0.3).restart();
        }
        node.fx = node.x;
        node.fy = node.y;
      })
      .on("drag", (event, node) => {
        node.fx = event.x;
        node.fy = event.y;
      })
      .on("end", (event, node) => {
        if (!event.active) {
          simulation.alphaTarget(0);
        }
        node.fx = null;
        node.fy = null;
      }) as any
  );

  const simulation = forceSimulation<N>(options.nodes)
    .force(
      "link",
      forceLink<N, SimLink<N>>(options.links)
        .id((node) => node.id)
        .distance(70)
    )
    .force("charge", forceManyBody().strength(-160))
    .force("center", forceCenter(width / 2, height / 2))
    .on("tick", () => {
      linkSelection
        .attr("x1", (link: SimLink<N>) => (link.source as N).x ?? 0)
        .attr("y1", (link: SimLink<N>) => (link.source as N).y ?? 0)
        .attr("x2", (link: SimLink<N>) => shortenedTarget(link, options.radius).x)
        .attr("y2", (link: SimLink<N>) => shortenedTarget(link, options.radius).y);

      nodeSelection.attr(
        "transform",
        (node: N) => `translate(${node.x ?? 0}, ${node.y ?? 0})`
      );
    });

  currentNodeSelection = nodeSelection as unknown as Selection<
    SVGGElement,
    SimNode,
    SVGGElement,
    unknown
  >;
  currentMatchesSearch = options.matchesSearch as (node: SimNode) => boolean;
}

let currentNodeSelection:
  | Selection<SVGGElement, SimNode, SVGGElement, unknown>
  | undefined;
let currentMatchesSearch: ((node: SimNode) => boolean) | undefined;

function applySearchHighlight<N extends SimNode>(
  nodeSelection: Selection<SVGGElement, N, SVGGElement, unknown>,
  matchesSearch: (node: N) => boolean
): void {
  if (searchTerm === "") {
    nodeSelection.classed("search-match", false);
    nodeSelection.classed("search-miss", false);
    return;
  }
  nodeSelection.classed("search-match", (node) => matchesSearch(node));
  nodeSelection.classed("search-miss", (node) => !matchesSearch(node));
}

function setupControls(): void {
  const searchInput = document.querySelector<HTMLInputElement>("#search");
  searchInput?.addEventListener("input", () => {
    searchTerm = searchInput.value.trim().toLowerCase();
    if (currentNodeSelection && currentMatchesSearch) {
      applySearchHighlight(currentNodeSelection, currentMatchesSearch);
    }
  });

  const backButton = document.querySelector<HTMLButtonElement>("#back");
  backButton?.addEventListener("click", () => {
    viewMode = { kind: "modules" };
    updateBackButton();
    render();
  });

  updateBackButton();
}

function updateBackButton(): void {
  const backButton = document.querySelector<HTMLButtonElement>("#back");
  if (!backButton) {
    return;
  }
  backButton.style.display =
    viewMode.kind === "module-detail" ? "inline-block" : "none";
  backButton.textContent =
    viewMode.kind === "module-detail"
      ? `← All modules (from ${viewMode.module})`
      : "";
}

setupControls();

window.addEventListener("message", (event: MessageEvent) => {
  snapshot = event.data as CallGraphSnapshot;
  viewMode = { kind: "modules" };
  updateBackButton();
  render();
});

vscode.postMessage({ type: "ready" });
