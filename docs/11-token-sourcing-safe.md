# Token Sourcing (Safe) and `.env` Setup

Zurueck: [10-model-profiles-and-credentials.md](./10-model-profiles-and-credentials.md)

Diese Seite beschreibt, wie du benoetigte Runtime-Secrets fuer **deinen eigenen Account** sauber beschaffst und sicher ablegst.

## Wichtig vorab
- Nur mit deinem eigenen Konto und deiner eigenen Session arbeiten.
- Keine Tokens an Dritte weitergeben.
- Keine Tokens in Git, Chat-Logs, Tickets oder Screenshots speichern.
- Lokale `.env` Dateien muessen untracked bleiben.

## Welche Secrets sind Pflicht?

| `.env` Variable | Wofuer |
|---|---|
| `TWINMIND_REFRESH_TOKEN` | Erzeugt neue ID-Tokens fuer TwinMind-Zugriffe |
| `TWINMIND_FIREBASE_API_KEY` | Wird beim Firebase Secure Token Refresh verwendet |

## Optionale Executor-Secrets

| `.env` Variable | Wofuer |
|---|---|
| `ORCH_EXECUTOR_API_KEY` | API-Key fuer HTTP/OpenAI-kompatible Executor |
| `OPENAI_API_KEY` | Alternative Key-Quelle fuer `openai`-artige Provider |

## High-Level Beschaffung (eigene Session)
1. In deinem Browser mit deinem eigenen TwinMind-Account anmelden.
2. DevTools oeffnen und Netzwerkanfragen der TwinMind-Web-/Extension-Session beobachten.
3. Relevante Auth-Requests/Responses identifizieren.
4. Refresh-Token und benoetigten API-Key nur lokal in Runtime `.env` uebertragen.
5. Alte/leak-verdachtige Tokens rotieren.

<details>
<summary><strong>Praxisbeispiel: Welche Werte landen in welcher Variable?</strong></summary>

- Gefundener Refresh-Token aus eigener Session -> `TWINMIND_REFRESH_TOKEN`
- Gefundener Firebase API Key fuer Token-Refresh -> `TWINMIND_FIREBASE_API_KEY`
- API-Key fuer externen HTTP-Executor -> `ORCH_EXECUTOR_API_KEY`

</details>

<details>
<summary><strong>Warum Refresh-Token + Firebase API Key getrennt sind</strong></summary>

Der Wrapper nutzt den Refresh-Token nicht direkt fuer jede API-Anfrage. Stattdessen wird ueber den Firebase Secure Token Endpoint ein aktuelles ID-Token bezogen. Deshalb werden beide Werte benoetigt.

</details>

## Beispiel `.env` (Platzhalter)
```env
TWINMIND_REFRESH_TOKEN=<set-locally>
TWINMIND_FIREBASE_API_KEY=<set-locally>

# optional for HTTP executor profiles
ORCH_EXECUTOR_PROVIDER=openai
ORCH_EXECUTOR_MODEL=<set-locally>
ORCH_EXECUTOR_BASE_URL=<set-locally>
ORCH_EXECUTOR_API_KEY=<set-locally>
```

## Sicherheits-Checkliste
1. `.env` ist in `.gitignore` und wird nicht committed.
2. Keine echten Tokens in `templates/`, `docs/`, `reports/`.
3. Vor Push `scripts/safe_push.sh` nutzen.
4. Bei Verdacht auf Leak: sofort rotieren und alte Session invalidieren.

## Weiterfuehrend
- [04-config-reference.md](./04-config-reference.md)
- [06-operations-runbook.md](./06-operations-runbook.md)
- [07-troubleshooting.md](./07-troubleshooting.md)
