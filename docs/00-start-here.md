# Start Here: Split Logic + TwinMind Wrapper

This page is the architecture-first entrypoint.

## What this repository is about
1. TwinMind wrapper internals
2. Split routing behavior (`strict_split` vs `legacy`)
3. Deterministic tool-bridge execution loop
4. Migration/replication scripts around that core

## System view
```mermaid
flowchart TD
    A[Clawdbot CLI backend] --> B[twinmind_orchestrator.py]
    B --> C{mode}
    C -->|conversation| D[TwinMind SSE]
    C -->|tool_bridge| E{routing_mode}
    E -->|legacy| F[Single bridge loop]
    E -->|strict_split| G[TwinMind Planner]
    G --> H[External Executor]
    H --> I[Local Tools / skill_run]
    I --> J[TwinMind Finalizer]
    D --> K[User Response]
    F --> K
    J --> K
```

## Execution sequence (`strict_split`)
```mermaid
sequenceDiagram
    participant U as User
    participant C as Clawdbot
    participant W as Wrapper
    participant P as TwinMind Planner
    participant E as Executor
    participant T as Local Tools
    participant F as TwinMind Finalizer

    U->>C: Request
    C->>W: CLI backend call
    W->>P: Planner prompt (optional)
    P-->>W: Planner brief
    W->>E: Protocol prompt + planner brief
    E->>W: tool_call/final JSON
    W->>T: execute tool_call
    T-->>W: TOOL_RESULT
    W->>E: Continue loop
    E-->>W: final
    W->>F: user-facing finalization
    F-->>W: Final answer
    W-->>C: JSON output
```

## Read in this order
1. [01-overview.md](./01-overview.md)
2. [02-wrapper-architecture.md](./02-wrapper-architecture.md)
3. [03-split-routing.md](./03-split-routing.md)
4. [04-config-reference.md](./04-config-reference.md)
5. [09-script-reference.md](./09-script-reference.md)

## Then move to operations
- [05-migration-guide.md](./05-migration-guide.md)
- [06-operations-runbook.md](./06-operations-runbook.md)
- [08-rollback.md](./08-rollback.md)
- [07-troubleshooting.md](./07-troubleshooting.md)
