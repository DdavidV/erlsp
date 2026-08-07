import * as vscode from "vscode";
import { CallGraphSnapshot, WebviewToHostMessage } from "./callGraph";

let currentPanel: vscode.WebviewPanel | undefined;
let pendingSnapshot: CallGraphSnapshot | undefined;
let isWebviewReady = false;

export function showCallGraphPanel(
  context: vscode.ExtensionContext,
  snapshot: CallGraphSnapshot
): void {
  if (currentPanel) {
    postSnapshot(snapshot);
    currentPanel.reveal(vscode.ViewColumn.Active);
    return;
  }

  const panel = vscode.window.createWebviewPanel(
    "erlspCallGraph",
    "erlsp: Call Graph",
    vscode.ViewColumn.Active,
    {
      enableScripts: true,
      retainContextWhenHidden: true,
      localResourceRoots: [vscode.Uri.joinPath(context.extensionUri, "out")],
    }
  );

  currentPanel = panel;
  isWebviewReady = false;
  panel.onDidDispose(() => {
    currentPanel = undefined;
    isWebviewReady = false;
    pendingSnapshot = undefined;
  });

  panel.webview.onDidReceiveMessage((message: WebviewToHostMessage) => {
    if (message.type === "ready") {
      isWebviewReady = true;
      if (pendingSnapshot) {
        void currentPanel?.webview.postMessage(pendingSnapshot);
        pendingSnapshot = undefined;
      }
    } else if (message.type === "jumpToDefinition") {
      void jumpToDefinition(message.uri, message.line);
    }
  });

  panel.webview.html = renderHtml(panel.webview, context);
  postSnapshot(snapshot);
}

function postSnapshot(snapshot: CallGraphSnapshot): void {
  if (isWebviewReady) {
    void currentPanel?.webview.postMessage(snapshot);
  } else {
    pendingSnapshot = snapshot;
  }
}

async function jumpToDefinition(uri: string, line: number): Promise<void> {
  const documentUri = vscode.Uri.parse(uri);
  const document = await vscode.workspace.openTextDocument(documentUri);
  const position = new vscode.Position(Math.max(line - 1, 0), 0);
  await vscode.window.showTextDocument(document, {
    viewColumn: vscode.ViewColumn.Beside,
    selection: new vscode.Range(position, position),
  });
}

function renderHtml(
  webview: vscode.Webview,
  context: vscode.ExtensionContext
): string {
  const scriptUri = webview.asWebviewUri(
    vscode.Uri.joinPath(context.extensionUri, "out", "callGraphView.js")
  );
  const nonce = createNonce();
  const csp = [
    "default-src 'none'",
    `style-src ${webview.cspSource} 'unsafe-inline'`,
    `script-src 'nonce-${nonce}'`,
  ].join("; ");

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta http-equiv="Content-Security-Policy" content="${csp}" />
  <style>
    body {
      margin: 0;
      padding: 0;
      overflow: hidden;
      background: var(--vscode-editor-background);
      color: var(--vscode-editor-foreground);
      font-family: var(--vscode-font-family);
    }
    svg {
      position: fixed;
      top: 0;
      left: 0;
      width: 100vw;
      height: 100vh;
      display: block;
      z-index: 0;
    }
    #toolbar {
      position: fixed;
      top: 8px;
      left: 8px;
      right: 8px;
      z-index: 1;
      display: flex;
      gap: 8px;
      align-items: center;
    }
    #toolbar button,
    #toolbar input {
      pointer-events: auto;
    }
    #search {
      flex: 0 1 320px;
      padding: 4px 8px;
      background: var(--vscode-input-background);
      color: var(--vscode-input-foreground);
      border: 1px solid var(--vscode-input-border, transparent);
      border-radius: 2px;
      font-family: var(--vscode-font-family);
      font-size: 13px;
    }
    #back {
      display: none;
      padding: 4px 10px;
      background: var(--vscode-button-secondaryBackground);
      color: var(--vscode-button-secondaryForeground);
      border: none;
      border-radius: 2px;
      cursor: pointer;
      font-family: var(--vscode-font-family);
      font-size: 12px;
    }
    #back:hover {
      background: var(--vscode-button-secondaryHoverBackground);
    }
    .node circle {
      stroke: var(--vscode-editor-background);
      stroke-width: 1.5px;
      cursor: pointer;
    }
    .node.workspace circle {
      fill: var(--vscode-charts-blue, #3794ff);
    }
    .node.external circle {
      fill: var(--vscode-descriptionForeground, #999);
    }
    .node text {
      font-size: 10px;
      fill: var(--vscode-editor-foreground);
      pointer-events: none;
    }
    .node.dimmed circle {
      opacity: 0.35;
    }
    .node.dimmed text {
      opacity: 0.35;
    }
    .node.search-match circle {
      stroke: var(--vscode-charts-yellow, #cca700);
      stroke-width: 3px;
    }
    .node.search-match text {
      font-weight: bold;
      opacity: 1;
    }
    .node.search-miss circle,
    .node.search-miss text {
      opacity: 0.15;
    }
    .link {
      stroke: var(--vscode-editorIndentGuide-background, #666);
      stroke-opacity: 0.5;
    }
    .arrow-head {
      fill: var(--vscode-editorIndentGuide-background, #666);
      opacity: 0.8;
    }
  </style>
</head>
<body>
  <div id="toolbar">
    <button id="back"></button>
    <input id="search" type="text" placeholder="Search modules/functions..." />
  </div>
  <svg></svg>
  <script nonce="${nonce}" src="${scriptUri}"></script>
</body>
</html>`;
}

function createNonce(): string {
  const chars =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  let nonce = "";
  for (let i = 0; i < 32; i++) {
    nonce += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return nonce;
}
