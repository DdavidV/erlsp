export interface CallGraphMfa {
  module: string;
  function: string;
  arity: number;
}

export interface CallGraphNode extends CallGraphMfa {
  origin: "workspace" | "external";
  uri?: string;
  line?: number;
}

export interface CallGraphEdge {
  caller: CallGraphMfa;
  callee: CallGraphMfa;
}

export interface CallGraphSnapshot {
  nodes: CallGraphNode[];
  edges: CallGraphEdge[];
}

export interface JumpToDefinitionMessage {
  type: "jumpToDefinition";
  uri: string;
  line: number;
}

export interface ReadyMessage {
  type: "ready";
}

export type WebviewToHostMessage = JumpToDefinitionMessage | ReadyMessage;
