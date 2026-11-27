---
name: rtk-proxy
description: Runs dev/git/test shell commands through RTK (Rust Token Killer) proxy to reduce LLM context token usage by 60-90%.
triggers: [rtk, terminal, git, test, log, build, diff]
---
# RTK AI Workflow
- Prefer `rtk git status`, `rtk git diff`, `rtk ls`, `rtk swift build`, `rtk pytest`, `rtk npm test`.
- Use `rtk gain` to inspect cumulative token savings.
