import * as path from "path";
import * as vscode from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export function activate(context: vscode.ExtensionContext): void {
  const config = vscode.workspace.getConfiguration("erlsp");
  const configuredPath = config.get<string>("serverPath");
  const serverPath =
    configuredPath && configuredPath.length > 0
      ? configuredPath
      : path.join(context.extensionPath, "server", "erlsp", "bin", "erlsp");

  const serverOptions: ServerOptions = {
    command: serverPath,
    args: ["-noshell"],
    transport: 0, // stdio
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "erlang" }],
  };

  client = new LanguageClient(
    "erlsp",
    "Erlang Language Server",
    serverOptions,
    clientOptions
  );

  client
    .start()
    .then(() => {
      vscode.window.setStatusBarMessage("erlsp: server started", 5000);
      client?.outputChannel.appendLine(
        `erlsp: server started (${serverPath})`
      );
    })
    .catch((startErr) => {
      vscode.window.showErrorMessage(
        `erlsp: failed to start server: ${startErr}`
      );
    });
}

export function deactivate(): Thenable<void> | undefined {
  return client?.stop();
}
