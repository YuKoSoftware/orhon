const { LanguageClient } = require("vscode-languageclient/node");
const { execFileSync } = require("child_process");
const vscode = require("vscode");

let client;
const outputChannel = vscode.window.createOutputChannel("Orhon Language Server");

function findOrhonPath(configured) {
  // Try the configured path first
  try {
    return execFileSync(configured, ["which"], { encoding: "utf-8" }).trim();
  } catch {}

  // Try common install locations
  const paths = [
    process.env.HOME + "/.local/bin/orhon",
    "/usr/local/bin/orhon",
    "/usr/bin/orhon",
  ];
  for (const p of paths) {
    try {
      return execFileSync(p, ["which"], { encoding: "utf-8" }).trim();
    } catch {}
  }

  return null;
}

function activate(context) {
  const config = vscode.workspace.getConfiguration("orhon");
  if (!config.get("lsp.enabled", true)) return;

  const configured = config.get("lsp.path", "orhon");
  const orhonPath = findOrhonPath(configured);

  if (!orhonPath) {
    outputChannel.appendLine(
      "Could not find orhon binary. Set orhon.lsp.path in settings."
    );
    outputChannel.show();
    return;
  }

  outputChannel.appendLine("Using orhon at: " + orhonPath);

  const serverOptions = {
    command: orhonPath,
    args: ["lsp"],
  };

  const clientOptions = {
    documentSelector: [{ scheme: "file", language: "orhon" }],
    outputChannel: outputChannel,
    initializationOptions: {
      inlayHints: config.get("inlayHints.enabled", false),
      completionSnippets: config.get("completion.snippets", false),
    },
  };

  client = new LanguageClient(
    "orhon",
    "Orhon Language Server",
    serverOptions,
    clientOptions
  );
  client.start().catch((err) => {
    outputChannel.appendLine("Failed to start: " + err.message);
    outputChannel.show();
  });
}

function deactivate() {
  if (client) return client.stop();
}

module.exports = { activate, deactivate };
