# Split Routing Logic

## Key inputs
- `--mode`: `conversation` or `tool_bridge`
- `--routing-mode`: `legacy` or `strict_split`
- inferred tool intent from user message
- fastpath detectors for specific operational requests

## Route matrix

### Conversation mode without explicit tool intent
- Route: `twinmind_conversation`
- Behavior: direct TwinMind response path
- Used for normal chat-style requests

### Conversation mode with explicit tool intent
- Route override into bridge logic
- Behavior: deterministic tool-protocol execution

### Tool bridge + legacy
- Route: `twinmind_tool_bridge`
- Planner/executor/finalizer remain single-path behavior

### Tool bridge + strict_split
- Route: `split_executor_bridge`
- Flow:
  1. optional TwinMind planner brief
  2. external executor produces protocol actions
  3. local tools execute
  4. TwinMind finalizer emits final user response

## Fastpath handling
Certain requests are intentionally short-circuited before generic model routing for reliability and deterministic behavior (for example heartbeat, cron, some local skill dispatches).

## Protocol states in bridge loop
- `tool_call`: run tool, append tool result, continue
- `final`: return answer and finish
- malformed: repair cycle with bounded retries

## Guardrails
- max steps
- max tool calls
- policy-limited shell execution
- write disabled unless explicitly allowed

## Observability
Router decisions and split route labels are written to log events, including:
- `router_decision`
- `planner_brief_ready` or `planner_brief_failed`
- `executor_failed`
- `protocol_error`
- `final`
