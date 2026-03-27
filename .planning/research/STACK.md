# Technology Stack

**Project:** Orhon Language Evolution
**Researched:** 2026-03-27

## Current Stack (No Changes Recommended)

Orhon's technology stack is well-chosen and requires no changes. The research focused on language design, not implementation technology.

### Core
| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Zig | 0.15.2+ | Compiler implementation + transpilation target | Only backend needed; provides C interop, cross-compilation, fast builds for free |
| PEG grammar | Custom | Parser specification | Grammar-driven parsing, single source of truth for syntax |

### Tooling
| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Zig build system | 0.15.2+ | Build orchestration | Native, no external deps, cross-compilation support |
| Bash | - | Test runner | Simple, portable, 11-stage pipeline |
| Node.js/npm | - | VS Code extension only | Standard for VS Code extensions |

### Missing (Future)
| Technology | Purpose | When |
|------------|---------|------|
| Tree-sitter grammar | Multi-editor syntax highlighting | Phase D (Ecosystem) |
| WASM target | Web playground | Phase D (Ecosystem) |
| Package registry | Dependency hosting | Post-1.0 |

## Alternatives Considered

| Category | Current | Alternative | Why Not |
|----------|---------|-------------|---------|
| Backend | Zig transpilation | LLVM direct | Zig gives us C interop, build system, cross-compilation for free |
| Backend | Zig transpilation | Cranelift | Would lose Zig ecosystem integration |
| Parser | Custom PEG | Tree-sitter | Tree-sitter is for editors; PEG is for compilers. Both can coexist |
| Test framework | Bash scripts | Zig test only | Shell tests cover CLI, build, integration; Zig tests cover units |

## Sources

- Training data analysis of compiler architecture patterns (MEDIUM confidence)
- Orhon project docs: COMPILER.md, TODO.md, build.zig
