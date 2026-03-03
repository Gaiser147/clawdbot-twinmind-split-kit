# Security Policy

## Secret Handling Rules

- Never commit real credentials.
- Use placeholders in all examples.
- Keep `.env` and runtime state out of git.
- Use `scripts/safe_push.sh` before every push.
- Pass tokens only through environment variables.

## Prohibited in Repository

- API keys, refresh tokens, OAuth tokens.
- Private keys and signing material.
- Production auth profile exports.
- Raw session dumps containing credentials.

## Reporting

If you detect a leaked credential, rotate it immediately and purge affected git history before pushing.
