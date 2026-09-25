# Waiting on graff

Bugs in graff that Search found, filed on justrach/codegraff by ./graff-issue.
A line goes when the release that fixes it is out and any workaround here is gone.

- [#1250](https://github.com/justrach/codegraff/issues/1250) WS prewarm frame omits model, so every new session falls back to SSE on its first turn — filed 2026-09-24. Fixed on main (#1252); until a release carries it, Agent.swift starts graff with GRAFF_CODEX_WS=off.
