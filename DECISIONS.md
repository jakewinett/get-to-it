# GetToIt — decisions so far

Name: **GetToIt**. Tagline: *Bring practice to your purpose.*
("Cairn" was dropped: an existing private journaling app uses it.)

## Product
- Personal goal app for one user. Calm, simple, encouraging; never punishing.
- Mobile-first (iOS primary). Web companion for planning and long-form notes.
- Morning flow: one daily digest notification → today's thought → Today screen.
- Daily thoughts: curated library **plus** phrases the user adds or saves (option C).
- Goals: categories (Professional, Personal, Physical, plus user-created), horizons (short / mid / long), measured by **milestones**, with notes and updates.
- Today's focus: app picks up to 3 next steps by due date; user can swap or add (max 5).
- Swap nudge: a step swapped out 3 days running prompts a gentle offer to break it into smaller steps.
- Consistency shown as "X of the last 7 days", not a fragile streak. Missed days never reset anything.
- Rewards: badges that can't be lost (First Step, Showing Up, Steady, Fresh Start, Halfway, Summit, Long Game, Reflective, Balanced).
- Reminders: one digest per day, tone Encouraging or Plain, optional long-term nudge and Sunday recap.
- Assistant ("Ask GetToIt"): text or voice; can answer about goals, log updates, add goals, swap steps, save thoughts, navigate, and give inspiration (quote, short story, idiom, Buddhist wisdom). Every app function should be reachable as an assistant action.
- Voice replies: on automatically with headphones (iOS detection); off by default without headphones, with a toggle.

## Platform
- Backend: Supabase (Postgres, auth, edge functions).
- AI: Claude via a Supabase Edge Function, app actions exposed as tools.
- Distribution: TestFlight only, single user for now.
- Auth: Sign in with Apple.

- Stack: **SwiftUI** iOS app + **Next.js** web companion, both on Supabase.

## Backend
- Schema: `supabase/migrations/20261123000000_init.sql` (tested on local Postgres 16; not applied anywhere yet).
- Badge, activity-day and swap-nudge rules live in SQL functions so iOS, web and the assistant behave the same:
  `complete_milestone`, `uncomplete_milestone`, `add_note`, `swap_focus_item`, `swap_streak`, `breakdown_milestone`.
- Clients can read badges but can't award them; only the functions can.
- Curated thoughts are rows with no owner; the user's own thoughts are private rows.

## Open
- Supabase project in the TechVantage LLC org (Pro).
- GitHub repo to hold the code.
- Reserve "GetToIt" in App Store Connect (the real availability check).
- Supabase connector can only see the EvanReads org; it needs access to the TechVantage org.

## Artifacts
- Click-through prototype: `prototype/index.html` (published privately as "GetToIt Prototype").
