# Overview

## Purpose
This kit standardizes a TwinMind-wrapper-based architecture for Clawdbot and provides a controlled migration path for existing installations.

## Core components
- `vendor/twinmind_orchestrator.py`: primary wrapper with conversation and tool-bridge modes.
- `vendor/twinmind_memory_sync.py`: local memory index sync.
- `vendor/twinmind_memory_query.py`: local memory query utility.

## Modes
- `conversation`: direct TwinMind conversation path.
- `tool_bridge`: deterministic JSON protocol (`tool_call` / `final`) with local tool execution.

## Split routing
- `routing_mode=legacy`: no strict planner/executor split.
- `routing_mode=strict_split`: TwinMind planner/finalizer + external executor.

## Goals of migration
- Route Clawdbot CLI backend through TwinMind wrapper.
- Keep non-related config keys intact.
- Ensure rollback safety via manifest and backups.
