# TwinMind Split Kit

Diese Startseite führt neue Nutzer Schritt für Schritt durch die Architektur, die Unterschiede zu Standard-Clawdbot und den sicheren Einstieg.

## Für wen ist dieses Repo?
- Für Nutzer, die verstehen wollen, wie der TwinMind Wrapper arbeitet.
- Für Nutzer, die die Split-Logik (`legacy bridge` vs `strict_split`) sicher einsetzen wollen.
- Für Nutzer, die von Standard-Clawdbot auf diese Architektur migrieren möchten.

## 5-Minuten Einstieg
1. Verstehe die Grundidee in [docs/00-start-here.md](./docs/00-start-here.md).
2. Lies die Begriffe in [docs/01-overview.md](./docs/01-overview.md).
3. Schau das Routing in [docs/03-split-routing.md](./docs/03-split-routing.md) an.
4. Prüfe Konfiguration in [docs/04-config-reference.md](./docs/04-config-reference.md).
5. Starte Migration immer mit `plan` in [docs/05-migration-guide.md](./docs/05-migration-guide.md).

## Split-Logik einfach erklärt
- `conversation`: Wrapper fragt TwinMind direkt, ohne striktes Tool-Protokoll.
- `tool_bridge`: Wrapper erzwingt ein strukturiertes Tool-Protokoll (`tool_call`/`final`).
- `legacy bridge`: Ein Bridge-Pfad ohne harte Planner/Executor-Aufteilung.
  Der gleiche LLM-Pfad macht Planung, Tool-Aufrufe und Finale in einer Brücke.
- `strict_split`: TwinMind plant/finalisiert, ein externer Executor führt deterministisch aus.

Merksatz:
- `legacy bridge` = kompatibler Ein-Brücken-Flow.
- `strict_split` = klar getrennte Rollen (Planner -> Executor -> Finalizer).

## Architektur auf einen Blick
```mermaid
flowchart LR
    A[Clawdbot] --> B[Wrapper: twinmind_orchestrator.py]
    B --> C{mode}
    C -->|conversation| D[TwinMind SSE]
    C -->|tool_bridge| E{routing_mode}
    E -->|legacy| F[Legacy Bridge Loop]
    E -->|strict_split| G[Planner -> Executor -> Finalizer]
    D --> H[User Response]
    F --> H
    G --> H
```

## Routing-Entscheidung
```mermaid
flowchart TD
    A[Request] --> B{Fastpath?}
    B -->|ja| C[Deterministischer Fastpath]
    B -->|nein| D{mode=conversation?}
    D -->|ja| E{Tool-Intent?}
    E -->|nein| F[twinmind_conversation]
    E -->|ja| G[tool_bridge]
    D -->|nein| G
    G --> H{routing_mode}
    H -->|legacy| I[twinmind_tool_bridge]
    H -->|strict_split| J[split_executor_bridge]
```

## Unterschied zu Standard-Clawdbot

| Bereich | Standard-Clawdbot | Dieses Repo (TwinMind Split Kit) | Wirkung |
|---|---|---|---|
| Primäres Backend | Standard Provider/Agent-Flow | TwinMind Wrapper als CLI-Backend | Einheitliches Wrapper-Routing |
| Routing | Kein expliziter Split-Mechanismus | `legacy bridge` + `strict_split` | Kontrollierbare Ausführungswege |
| Tool-Orchestrierung | Provider-abhängig | JSON-Protokoll in `tool_bridge` | Deterministischere Tool-Schritte |
| Finalisierung | Direkt aus Provider-Pfad | Optional TwinMind-Finalizer in `strict_split` | Konsistentere Nutzerantwort |
| Migration/Rollback | Kein dediziertes Kit | `plan/apply/rollback` Skripte + Manifest | Sicherere Umstellung |
| Replizierbarkeit | Manuell | Replica-Bootstrap-Skript | Schneller Neuaufbau |

## Code-Struktur und Verantwortlichkeiten
- [vendor/](./vendor/) Runtime-Kern
  - [twinmind_orchestrator.py](./vendor/twinmind_orchestrator.py): Hauptlogik
  - [twinmind_memory_sync.py](./vendor/twinmind_memory_sync.py): Memory-Sync
  - [twinmind_memory_query.py](./vendor/twinmind_memory_query.py): Memory-Query
- [scripts/](./scripts/) Betrieb und Migration
  - [convert_clawdbot_to_split.sh](./scripts/convert_clawdbot_to_split.sh)
  - [bootstrap_clawdbot_replica.sh](./scripts/bootstrap_clawdbot_replica.sh)
  - [safe_push.sh](./scripts/safe_push.sh)
- [docs/](./docs/) Onboarding, Architektur, Betrieb
- [templates/](./templates/) Patch- und Env-Vorlagen
- [manifests/](./manifests/) Migrationsschema und erzeugte Manifeste
- [analysis/](./analysis/) Line-Refs und Architektur-Mapping

## Lesewege nach Ziel
- Ich bin neu:
  - [00-start-here](./docs/00-start-here.md)
  - [01-overview](./docs/01-overview.md)
  - [03-split-routing](./docs/03-split-routing.md)
- Ich migriere/betreibe:
  - [05-migration-guide](./docs/05-migration-guide.md)
  - [06-operations-runbook](./docs/06-operations-runbook.md)
  - [08-rollback](./docs/08-rollback.md)
- Ich will tief technisch einsteigen:
  - [02-wrapper-architecture](./docs/02-wrapper-architecture.md)
  - [03-split-routing](./docs/03-split-routing.md)
  - [09-script-reference](./docs/09-script-reference.md)

## Sicherheitsregeln
- Keine Migration automatisch ausführen.
- Immer zuerst `plan`.
- Keine Credentials committen.
- Vor Push immer [scripts/safe_push.sh](./scripts/safe_push.sh).

## Schnellbefehle
Migration planen:
```bash
/root/twinmind-split-kit/scripts/convert_clawdbot_to_split.sh --mode plan --config /root/.clawdbot/clawdbot.json
```

Replica dry-run:
```bash
/root/twinmind-split-kit/scripts/bootstrap_clawdbot_replica.sh --mode plan --target-root /root/.clawdbot-replica
```

Private Repo Push dry-run:
```bash
/root/twinmind-split-kit/scripts/init_private_repo_and_push.sh --owner <your-github-user> --repo clawdbot-twinmind-split-kit --dry-run 1
```

## Erforderliche Runtime-Secrets
- `TWINMIND_REFRESH_TOKEN`
- `TWINMIND_FIREBASE_API_KEY`

In runtime `.env` setzen, niemals committen.

## Provenance
- [vendor/PROVENANCE.md](./vendor/PROVENANCE.md)
