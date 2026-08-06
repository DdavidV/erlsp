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

  context.subscriptions.push(
    vscode.commands.registerCommand("erlsp.reindexWorkspace", async () => {
      if (!client) {
        return;
      }
      await client.sendNotification("erlsp/reindexWorkspace");
      vscode.window.setStatusBarMessage("erlsp: reindexing workspace", 5000);
    }),
    vscode.commands.registerCommand("erlsp.restartServer", async () => {
      if (!client) {
        return;
      }
      try {
        await client.restart();
        vscode.window.setStatusBarMessage("erlsp: server restarted", 5000);
      } catch (restartErr) {
        vscode.window.showErrorMessage(
          `erlsp: failed to restart server: ${restartErr}`
        );
      }
    })
  );
}

export function deactivate(): Thenable<void> | undefined {
  return client?.stop();
}
