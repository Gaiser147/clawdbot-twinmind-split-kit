# Wrapper Flow Map

## Primary Script
- `vendor/twinmind_orchestrator.py`

## High-level flow
1. Parse CLI args (`--mode`, `--routing-mode`, executor flags).
2. Normalize/sanitize inbound query and select session.
3. Run fast-path handlers (heartbeat, image, cron, skill shortcuts).
4. Route to:
   - `conversation` path (direct TwinMind SSE), or
   - `tool_bridge` loop.
5. In `tool_bridge`:
   - Build tool catalog and protocol prompt.
   - Loop over model/executor outputs.
   - Parse `tool_call` / `final` JSON objects.
   - Execute local tools.
   - Handle repair/fallback/limit conditions.
6. Emit final response in text/json mode.

## Split Routing Semantics
- `routing_mode=legacy`: single-brain bridge behavior.
- `routing_mode=strict_split`: TwinMind planner/finalizer + external executor.
- Route labels in logs:
  - `twinmind_conversation`
  - `twinmind_tool_bridge`
  - `split_executor_bridge`

## Deterministic Safety Mechanics
- File lock (`run.lock`) to avoid overlapping runs.
- Protocol repair prompt when executor emits invalid JSON protocol.
- Tool-call and step limits.
- Lenient non-crash finalization for gateway stability.
