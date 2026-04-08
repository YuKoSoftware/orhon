# Orhon for VS Code

Language support for [Orhon](https://github.com/YuKoSoftware/orhon) — a compiled, memory-safe programming language that transpiles to Zig.

## Features

- Syntax highlighting for `.orh` files
- Real-time diagnostics via the built-in language server
- Error and warning squiggles as you code

## Requirements

Install the `orhon` compiler and ensure it's on your `PATH`:

```bash
orhon addtopath
```

## Usage

Open any `.orh` file. The extension automatically starts the language server and shows diagnostics on save.

## Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `orhon.lsp.enabled` | `true` | Enable the language server |
| `orhon.lsp.path` | `"orhon"` | Path to the orhon binary |
