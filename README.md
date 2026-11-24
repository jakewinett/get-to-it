# Get To It

*Bring practice to your purpose.*

A personal goal app: a daily thought, a short list of next steps, milestone-based goals with notes, and badges for showing up. iOS first (SwiftUI), with a Next.js web companion for planning and long notes. Backend on Supabase.

## What's here

| Path | What it is |
|---|---|
| `prototype/index.html` | Click-through prototype (single HTML file, open in a browser) |
| `supabase/migrations/` | Database schema, row-level security and app logic in SQL |
| `supabase/tests/` | Behavior checks for the schema, run by CI on every PR that touches `supabase/` |
| `DECISIONS.md` | Product and technical decisions so far |

## Coming next

- `ios/` — SwiftUI app (TestFlight, Sign in with Apple)
- `web/` — Next.js companion
- `supabase/functions/` — edge functions for the assistant and the morning digest

## Running the database checks locally

With any Postgres 16+ you can connect to:

```bash
psql -v ON_ERROR_STOP=1 -f supabase/tests/auth_stub.sql
for f in supabase/migrations/*.sql; do psql -v ON_ERROR_STOP=1 -q -f "$f"; done
psql -v ON_ERROR_STOP=1 -f supabase/tests/behavior.sql
```

Use an empty, throwaway database: the stub creates roles and an `auth` schema.
