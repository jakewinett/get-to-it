-- GetToIt: initial schema
-- One user for now (TestFlight + Sign in with Apple), but every row is owned by
-- auth.uid() and protected by RLS so the app can open up later without a rewrite.
--
-- Rules that matter to more than one client (iOS, web, assistant) live in SQL
-- functions, so badges, activity days and swap nudges behave the same everywhere:
--   complete_milestone, add_note, swap_focus_item, breakdown_milestone

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------
create type public.goal_horizon as enum ('short', 'mid', 'long');
create type public.goal_status  as enum ('active', 'completed', 'archived');
create type public.thought_kind as enum ('thought', 'quote', 'story', 'idiom', 'buddhist');
create type public.entry_source as enum ('ios', 'web', 'assistant');

-- ---------------------------------------------------------------------------
-- Profile and settings (one row per user)
-- ---------------------------------------------------------------------------
create table public.profiles (
  id                        uuid primary key references auth.users (id) on delete cascade,
  display_name              text,
  timezone                  text not null default 'America/New_York',
  digest_time               time not null default '07:30',
  digest_tone               text not null default 'encouraging' check (digest_tone in ('encouraging', 'plain')),
  long_term_nudges          boolean not null default true,
  sunday_recap              boolean not null default true,
  voice_with_headphones     boolean not null default true,
  voice_without_headphones  boolean not null default false,
  max_focus_items           smallint not null default 5 check (max_focus_items between 1 and 10),
  created_at                timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Goals
-- ---------------------------------------------------------------------------
create table public.categories (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name        text not null check (length(trim(name)) between 1 and 40),
  color       text not null,                       -- design token name, e.g. 'pro', 'c4'
  position    smallint not null default 0,
  archived_at timestamptz,
  created_at  timestamptz not null default now()
);
create unique index categories_user_name_key on public.categories (user_id, lower(name)) where archived_at is null;

create table public.goals (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid() references auth.users (id) on delete cascade,
  category_id  uuid not null references public.categories (id),
  title        text not null check (length(trim(title)) between 1 and 200),
  horizon      public.goal_horizon not null default 'short',
  target_date  date,
  target_label text,                               -- "April 2027", "Summer 2027" when a date is too precise
  status       public.goal_status not null default 'active',
  completed_at timestamptz,
  source       public.entry_source not null default 'ios',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index goals_user_status_idx on public.goals (user_id, status);

create table public.milestones (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users (id) on delete cascade,
  goal_id         uuid not null references public.goals (id) on delete cascade,
  title           text not null check (length(trim(title)) between 1 and 200),
  position        integer not null default 0,
  due_date        date,
  completed_at    timestamptz,
  parent_id       uuid references public.milestones (id) on delete set null,  -- set when created by a breakdown
  broken_down_at  timestamptz,                     -- original step that was split; hidden from lists
  created_at      timestamptz not null default now()
);
create index milestones_goal_idx on public.milestones (goal_id, position) where broken_down_at is null;

create table public.goal_notes (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  goal_id    uuid not null references public.goals (id) on delete cascade,
  body       text not null check (length(trim(body)) between 1 and 20000),
  source     public.entry_source not null default 'ios',
  created_at timestamptz not null default now()
);
create index goal_notes_goal_idx on public.goal_notes (goal_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Today's focus
-- ---------------------------------------------------------------------------
create table public.focus_items (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references auth.users (id) on delete cascade,
  day            date not null,
  milestone_id   uuid not null references public.milestones (id) on delete cascade,
  position       smallint not null default 0,
  picked_by      text not null default 'app' check (picked_by in ('app', 'user')),
  swapped_out_at timestamptz,                      -- set when the user swaps it away; the row is kept for the nudge
  created_at     timestamptz not null default now(),
  unique (user_id, day, milestone_id)
);
create index focus_items_user_day_idx on public.focus_items (user_id, day);

-- A day with any progress. Drives "X of the last 7 days" and several badges.
create table public.activity_days (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  day     date not null,
  primary key (user_id, day)
);

-- ---------------------------------------------------------------------------
-- Thoughts: curated library (user_id is null) plus the user's own
-- ---------------------------------------------------------------------------
create table public.thoughts (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid references auth.users (id) on delete cascade,   -- null = curated, shared
  kind       public.thought_kind not null default 'thought',
  body       text not null check (length(trim(body)) between 1 and 2000),
  subline    text,
  source     text,                                 -- attribution, e.g. 'Dhammapada, verse 122'
  in_morning_rotation boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.thought_favorites (
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  thought_id uuid not null references public.thoughts (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, thought_id)
);

-- Which thought was shown on which morning, so the rotation avoids repeats.
create table public.thought_history (
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  day        date not null,
  thought_id uuid not null references public.thoughts (id) on delete cascade,
  primary key (user_id, day)
);

-- ---------------------------------------------------------------------------
-- Badges
-- ---------------------------------------------------------------------------
create table public.badge_catalog (
  key        text primary key,
  name       text not null,
  how        text not null,
  glyph      text not null,
  repeatable boolean not null default false,
  position   smallint not null
);

-- One row per time a badge is earned; counts come from grouping.
create table public.badges_earned (
  id        uuid primary key default gen_random_uuid(),
  user_id   uuid not null references auth.users (id) on delete cascade,
  badge_key text not null references public.badge_catalog (key),
  earned_at timestamptz not null default now(),
  context   jsonb not null default '{}'::jsonb      -- e.g. {"goal_id": "..."}
);
create index badges_earned_user_idx on public.badges_earned (user_id, badge_key, earned_at desc);

-- ---------------------------------------------------------------------------
-- Notifications and assistant
-- ---------------------------------------------------------------------------
create table public.push_tokens (
  user_id      uuid not null default auth.uid() references auth.users (id) on delete cascade,
  device_token text not null,
  environment  text not null default 'sandbox' check (environment in ('sandbox', 'production')),
  updated_at   timestamptz not null default now(),
  primary key (user_id, device_token)
);

create table public.reminder_log (
  user_id uuid not null references auth.users (id) on delete cascade,
  kind    text not null check (kind in ('digest', 'sunday_recap')),
  sent_on date not null,
  sent_at timestamptz not null default now(),
  primary key (user_id, kind, sent_on)
);

create table public.assistant_turns (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  input_mode    text not null check (input_mode in ('text', 'voice')),
  input         text not null,
  reply         text,
  actions       jsonb not null default '[]'::jsonb, -- tool calls the assistant made
  model         text,
  input_tokens  integer,
  output_tokens integer,
  created_at    timestamptz not null default now()
);
create index assistant_turns_user_idx on public.assistant_turns (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------
alter table public.profiles          enable row level security;
alter table public.categories        enable row level security;
alter table public.goals             enable row level security;
alter table public.milestones        enable row level security;
alter table public.goal_notes        enable row level security;
alter table public.focus_items       enable row level security;
alter table public.activity_days     enable row level security;
alter table public.thoughts          enable row level security;
alter table public.thought_favorites enable row level security;
alter table public.thought_history   enable row level security;
alter table public.badge_catalog     enable row level security;
alter table public.badges_earned     enable row level security;
alter table public.push_tokens       enable row level security;
alter table public.reminder_log      enable row level security;
alter table public.assistant_turns   enable row level security;

create policy "own profile" on public.profiles
  for all to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- Plain ownership on the tables clients write directly.
do $$
declare t text;
begin
  foreach t in array array['categories', 'goals', 'milestones', 'goal_notes', 'focus_items',
                           'thought_favorites', 'thought_history', 'push_tokens']
  loop
    execute format(
      'create policy "own rows" on public.%I for all to authenticated
         using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()))', t);
  end loop;
end $$;

-- Read-only for clients; written by functions or the service role.
create policy "own rows read" on public.activity_days   for select to authenticated using (user_id = (select auth.uid()));
create policy "own rows read" on public.badges_earned   for select to authenticated using (user_id = (select auth.uid()));
create policy "own rows read" on public.reminder_log    for select to authenticated using (user_id = (select auth.uid()));
create policy "own rows read" on public.assistant_turns for select to authenticated using (user_id = (select auth.uid()));
create policy "catalog read"  on public.badge_catalog   for select to authenticated using (true);

-- Curated thoughts are readable by everyone signed in; personal ones only by their owner.
create policy "read curated and own" on public.thoughts
  for select to authenticated using (user_id is null or user_id = (select auth.uid()));
create policy "write own" on public.thoughts
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy "update own" on public.thoughts
  for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "delete own" on public.thoughts
  for delete to authenticated using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create or replace function public.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;

create trigger goals_touch before update on public.goals
  for each row execute function public.touch_updated_at();

-- "Today" in the user's own time zone.
create or replace function public.local_today(p_user uuid) returns date
language sql stable set search_path = '' as $$
  select (now() at time zone coalesce((select timezone from public.profiles where id = p_user), 'UTC'))::date
$$;

-- New user: profile plus the three starting categories.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'));
  insert into public.categories (user_id, name, color, position) values
    (new.id, 'Professional', 'pro', 0),
    (new.id, 'Personal',     'per', 1),
    (new.id, 'Physical',     'phy', 2);
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Internal: record a badge and return its key.
create or replace function public.award_badge(p_user uuid, p_key text, p_context jsonb default '{}'::jsonb)
returns text language sql security definer set search_path = '' as $$
  insert into public.badges_earned (user_id, badge_key, context) values (p_user, p_key, p_context)
  returning badge_key
$$;
revoke all on function public.award_badge(uuid, text, jsonb) from public, anon, authenticated;

-- Internal: mark today active. Returns the badge keys that activity alone unlocks.
create or replace function public.record_activity(p_user uuid) returns setof text
language plpgsql security definer set search_path = '' as $$
declare
  v_today    date := public.local_today(p_user);
  v_inserted integer;
  v_prev     date;
  v_week     integer;
begin
  select max(day) into v_prev from public.activity_days where user_id = p_user and day < v_today;
  insert into public.activity_days (user_id, day) values (p_user, v_today) on conflict do nothing;
  get diagnostics v_inserted = row_count;
  if v_inserted = 0 then return; end if;  -- already active today

  -- Fresh Start: back after 3 or more quiet days.
  if v_prev is not null and v_today - v_prev > 3 then
    return next public.award_badge(p_user, 'fresh-start');
  end if;

  select count(*) into v_week from public.activity_days
   where user_id = p_user and day > v_today - 7;

  if v_week = 3 and not exists (select 1 from public.badges_earned where user_id = p_user
       and badge_key = 'showing-up' and earned_at > now() - interval '7 days') then
    return next public.award_badge(p_user, 'showing-up');
  end if;
  if v_week = 5 and not exists (select 1 from public.badges_earned where user_id = p_user
       and badge_key = 'steady' and earned_at > now() - interval '7 days') then
    return next public.award_badge(p_user, 'steady');
  end if;
end $$;
revoke all on function public.record_activity(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Client-facing actions (the iOS app, web app and assistant all call these)
-- ---------------------------------------------------------------------------

-- Complete a milestone. Returns the badges earned by this action, if any.
create or replace function public.complete_milestone(p_milestone uuid)
returns table (badge_key text)
language plpgsql security definer set search_path = '' as $$
declare
  v_user   uuid := auth.uid();
  v_goal   public.goals%rowtype;
  v_ms     public.milestones%rowtype;
  v_total  integer;
  v_before integer;
  v_cats   integer;
begin
  if v_user is null then raise exception 'not signed in'; end if;

  select * into v_ms from public.milestones
   where id = p_milestone and user_id = v_user and broken_down_at is null for update;
  if not found then raise exception 'milestone not found'; end if;
  if v_ms.completed_at is not null then return; end if;

  select * into v_goal from public.goals where id = v_ms.goal_id for update;
  select count(*), count(completed_at) into v_total, v_before
    from public.milestones where goal_id = v_goal.id and broken_down_at is null;

  update public.milestones set completed_at = now() where id = p_milestone;

  return query select public.record_activity(v_user);

  if not exists (select 1 from public.badges_earned where user_id = v_user and badges_earned.badge_key = 'first-step') then
    badge_key := public.award_badge(v_user, 'first-step'); return next;
  end if;

  -- Halfway and Summit compare the share of milestones done before and after.
  if v_before * 2 < v_total and (v_before + 1) * 2 >= v_total and v_before + 1 < v_total then
    badge_key := public.award_badge(v_user, 'halfway', jsonb_build_object('goal_id', v_goal.id)); return next;
  end if;
  if v_before + 1 = v_total then
    update public.goals set status = 'completed', completed_at = now() where id = v_goal.id;
    badge_key := public.award_badge(v_user, 'summit', jsonb_build_object('goal_id', v_goal.id)); return next;
  end if;

  if v_goal.horizon = 'long' then
    badge_key := public.award_badge(v_user, 'long-game', jsonb_build_object('goal_id', v_goal.id)); return next;
  end if;

  -- Balanced: progress in three categories within 7 days, at most once a week.
  select count(distinct g.category_id) into v_cats
    from public.milestones m join public.goals g on g.id = m.goal_id
   where m.user_id = v_user and m.completed_at > now() - interval '7 days';
  if v_cats >= 3 and not exists (select 1 from public.badges_earned where user_id = v_user
       and badges_earned.badge_key = 'balanced' and earned_at > now() - interval '7 days') then
    badge_key := public.award_badge(v_user, 'balanced'); return next;
  end if;
end $$;

-- Undo a completion. Badges are never taken back.
create or replace function public.uncomplete_milestone(p_milestone uuid) returns void
language sql security invoker set search_path = '' as $$
  update public.milestones set completed_at = null where id = p_milestone and user_id = auth.uid();
  update public.goals g set status = 'active', completed_at = null
    from public.milestones m
   where m.id = p_milestone and g.id = m.goal_id and g.status = 'completed';
$$;

-- Add a note or update. Returns badges earned (Reflective at 10 notes).
create or replace function public.add_note(p_goal uuid, p_body text, p_source public.entry_source default 'ios')
returns table (note_id uuid, badge_key text)
language plpgsql security definer set search_path = '' as $$
declare
  v_user  uuid := auth.uid();
  v_id    uuid;
  v_count integer;
  v_any   boolean := false;
begin
  if v_user is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from public.goals where id = p_goal and user_id = v_user) then
    raise exception 'goal not found';
  end if;
  insert into public.goal_notes (user_id, goal_id, body, source) values (v_user, p_goal, p_body, p_source)
  returning id into v_id;
  note_id := v_id;

  for badge_key in select public.record_activity(v_user) loop v_any := true; return next; end loop;

  select count(*) into v_count from public.goal_notes where user_id = v_user;
  if v_count >= 10 and not exists (select 1 from public.badges_earned where user_id = v_user and badges_earned.badge_key = 'reflective') then
    badge_key := public.award_badge(v_user, 'reflective'); v_any := true; return next;
  end if;
  if not v_any then badge_key := null; return next; end if;  -- always return the note id
end $$;

-- How many days in a row (ending today) a step has been swapped out of Today.
create or replace function public.swap_streak(p_milestone uuid) returns integer
language sql stable security invoker set search_path = '' as $$
  with days as (
    select day from public.focus_items
     where milestone_id = p_milestone and user_id = auth.uid() and swapped_out_at is not null
  ), today as (select public.local_today(auth.uid()) as d)
  select coalesce(max(n) + 1, 0)::integer from (
    select n from today, generate_series(0, 30) as n
     where not exists (
       select 1 from generate_series(0, n) k
        where (today.d - k) not in (select day from days))
  ) s
$$;

-- Swap a step out of today's list for another. Returns the swap streak of the step
-- that left, so the client can show the "break it down" nudge at 3.
create or replace function public.swap_focus_item(p_out uuid, p_in uuid) returns integer
language plpgsql security invoker set search_path = '' as $$
declare
  v_user  uuid := auth.uid();
  v_today date := public.local_today(auth.uid());
  v_pos   smallint;
begin
  update public.focus_items set swapped_out_at = now()
   where user_id = v_user and day = v_today and milestone_id = p_out and swapped_out_at is null
  returning position into v_pos;
  if not found then raise exception 'step is not on today''s list'; end if;

  insert into public.focus_items (user_id, day, milestone_id, position, picked_by)
  values (v_user, v_today, p_in, v_pos, 'user')
  on conflict (user_id, day, milestone_id) do update set swapped_out_at = null, picked_by = 'user', position = excluded.position;

  return public.swap_streak(p_out);
end $$;

-- Split a step into smaller ones. The original is kept for history but hidden.
-- The first new step goes onto today's list if there is room.
create or replace function public.breakdown_milestone(p_milestone uuid, p_steps text[]) returns setof uuid
language plpgsql security invoker set search_path = '' as $$
declare
  v_user  uuid := auth.uid();
  v_ms    public.milestones%rowtype;
  v_n     integer := coalesce(array_length(p_steps, 1), 0);
  v_first uuid;
  v_id    uuid;
  v_today date := public.local_today(auth.uid());
  i       integer;
begin
  if v_n = 0 then raise exception 'add at least one smaller step'; end if;
  select * into v_ms from public.milestones where id = p_milestone and user_id = v_user and broken_down_at is null;
  if not found then raise exception 'milestone not found'; end if;

  update public.milestones set position = position + v_n
   where goal_id = v_ms.goal_id and position > v_ms.position;
  update public.milestones set broken_down_at = now() where id = p_milestone;

  for i in 1 .. v_n loop
    insert into public.milestones (user_id, goal_id, title, position, parent_id, due_date)
    values (v_user, v_ms.goal_id, trim(p_steps[i]), v_ms.position + i, p_milestone, case when i = 1 then v_ms.due_date end)
    returning id into v_id;
    if i = 1 then v_first := v_id; end if;
    return next v_id;
  end loop;

  if (select count(*) from public.focus_items where user_id = v_user and day = v_today and swapped_out_at is null)
     < (select max_focus_items from public.profiles where id = v_user) then
    insert into public.focus_items (user_id, day, milestone_id, position, picked_by)
    values (v_user, v_today, v_first, 99, 'app') on conflict do nothing;
  end if;
end $$;

grant execute on function public.complete_milestone(uuid)                       to authenticated;
grant execute on function public.uncomplete_milestone(uuid)                     to authenticated;
grant execute on function public.add_note(uuid, text, public.entry_source)      to authenticated;
grant execute on function public.swap_streak(uuid)                              to authenticated;
grant execute on function public.swap_focus_item(uuid, uuid)                    to authenticated;
grant execute on function public.breakdown_milestone(uuid, text[])              to authenticated;

-- ---------------------------------------------------------------------------
-- Seed: badge catalog and a starter thought library
-- ---------------------------------------------------------------------------
insert into public.badge_catalog (key, name, how, glyph, repeatable, position) values
  ('first-step',  'First Step',  'Complete your first milestone.',                                     'flag',     false, 1),
  ('showing-up',  'Showing Up',  'Make progress on 3 days in a week.',                                  'sunrise',  true,  2),
  ('steady',      'Steady',      'Make progress on 5 days in a week. Any 5, not 5 in a row.',          'wave',     true,  3),
  ('fresh-start', 'Fresh Start', 'Come back after a few days away. Returning is a skill.',             'seedling', true,  4),
  ('halfway',     'Halfway',     'Reach the midpoint of any goal.',                                     'half',     true,  5),
  ('summit',      'Summit',      'Complete a goal.',                                                    'mountain', true,  6),
  ('long-game',   'Long Game',   'Reach a milestone on a long-term goal.',                              'compass',  true,  7),
  ('reflective',  'Reflective',  'Write 10 notes or updates on your goals.',                            'pen',      false, 8),
  ('balanced',    'Balanced',    'Make progress in three categories in one week.',                      'balance',  true,  9);

insert into public.thoughts (kind, body, subline, source) values
  ('thought',  'Small steps still move you forward.',     'You don''t have to do everything today. Just the next thing.', null),
  ('thought',  'Progress counts, even when it''s quiet.', 'Some days the win is simply showing up.',                       null),
  ('thought',  'Begin again as often as you need.',       'A missed day is a pause, not a verdict.',                      null),
  ('quote',    'The journey of a thousand miles begins with a single step.', null, 'Lao Tzu, Tao Te Ching'),
  ('buddhist', 'Drop by drop is the water pot filled. Likewise, the wise one, gathering it little by little, fills themselves with good.', null, 'Adapted from the Dhammapada, verse 122'),
  ('idiom',    'Fall down seven times, get up eight.',     null, 'Japanese proverb, nana korobi ya oki'),
  ('idiom',    'Little by little, one goes far.',          null, 'Spanish proverb, poco a poco se va lejos');
