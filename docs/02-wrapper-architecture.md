# Wrapper Architecture

## Main executable
- `vendor/twinmind_orchestrator.py`

## Runtime phases
1. Bootstrap
   - load environment overlays
   - parse CLI flags
   - derive stable session identity
2. Pre-routing normalization
   - sanitize inbound transport wrappers
   - optional media/PDF preprocessing
   - dynamic memory context load
3. Router selection
   - fastpaths (heartbeat/image/cron/local skills)
   - conversation or bridge path
4. Execution core
   - conversation path: TwinMind SSE call + fallback handling
   - bridge path: protocol-driven tool loop
5. Finalization and emit
   - optional finalizer in split mode
   - output in text or json envelope

## Internal subsystems

### Session and locking
- lock file prevents overlapping run collisions
- session id persists conversational continuity

### Protocol subsystem (bridge mode)
- tool catalog generation
- strict protocol prompt generation
- parser normalizes variants into canonical actions
- repair prompt cycle when malformed outputs are detected

### Tool subsystem
- read-only utilities (web/search/read file)
- skill dispatch (`skill_run`) for curated operations
- shell path with policy checks and write restrictions

### Split subsystem (`strict_split`)
- optional TwinMind planner creates compact task brief
- external executor performs deterministic protocol steps
- TwinMind finalizer composes user-facing answer

### Reliability and degradation
- retry on transient HTTP failures
- controlled fallback messages when protocol/executor fails
- avoid fatal non-zero exits in JSON backend mode

## File and state surfaces
- logs under wrapper state directory
- sessions mapping file
- lock file
- memory cache files for TwinMind memory index/query

## Source references
See `analysis/line_refs.txt` for direct anchors to critical methods and route decisions.
