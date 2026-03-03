# Key Line References

Source: `vendor/twinmind_orchestrator.py`

See `analysis/line_refs.txt` for grep-generated anchors.

Highlights:
- CLI and routing flags: `--mode`, `--routing-mode`, executor args
- Split switch: `strict_split = cfg.routing_mode == "strict_split"`
- Split route label: `split_executor_bridge`
- Executor call path: `call_executor(...)`
- Protocol parsing loop: `parse_protocol_output(...)`
- Tool execution: `execute_tool(...)`
- Final emission: `emit_and_exit(...)`
