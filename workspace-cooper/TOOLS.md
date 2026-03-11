# Tools

## Sub-agents
- tars: coding tasks (spawned, not persistent)
- brand: email/calendar (spawned, not persistent)
- murph: social/content (spawned, not persistent)

## Task Board
- Source of truth: tasks.json
- Statuses: backlog → todo → in_progress → review → done
- Only spawn for "todo" tasks
- Update status + result on sub-agent completion

## Memory
- Entity memory via `memory` CLI (backed by Qdrant)
- `memory event` for raw observations (auto-expire 30 days)
- `memory store` for confirmed facts (upserted, not appended)
- `memory search` for retrieval (always search before spawning)
- No MEMORY.md — everything is on-demand via vector search
