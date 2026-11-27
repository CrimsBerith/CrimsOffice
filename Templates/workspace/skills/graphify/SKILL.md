---
name: graphify
description: Builds and queries a project knowledge graph (graphify-out/GRAPH_REPORT.md & graph.json) to understand large repos with minimal tokens.
triggers: [graphify, graf, mimari, bağımlılık, refactor, architecture]
---
# Graphify Workflow
- Inspect `graphify-out/GRAPH_REPORT.md` and God Nodes before reading dozens of raw files.
- Run `graphify update .` after edits (AST-only, zero API cost).
