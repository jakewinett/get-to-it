-- Behavior checks for the schema. Every check raises an exception on failure,
-- so psql with ON_ERROR_STOP exits non-zero and CI goes red.
\set ON_ERROR_STOP 1
\set QUIET 1
\o /dev/null

-- Supabase grants table access to authenticated by default; plain Postgres doesn't.
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;

insert into auth.users (id, raw_user_meta_data) values
  ('11111111-1111-1111-1111-111111111111', '{"full_name":"Test User"}'),
  ('22222222-2222-2222-2222-222222222222', '{}');

do $$ begin
  if (select count(*) from public.categories where user_id = '11111111-1111-1111-1111-111111111111') <> 3 then
    raise exception 'new user should get 3 default categories';
  end if;
  if not exists (select 1 from public.profiles where id = '11111111-1111-1111-1111-111111111111' and display_name = 'Test User') then
    raise exception 'new user should get a profile with their name';
  end if;
end $$;

-- Earlier activity: yesterday and 3 days ago, so today makes 3 of the last 7.
insert into public.activity_days
select '11111111-1111-1111-1111-111111111111', public.local_today('11111111-1111-1111-1111-111111111111') - d
from unnest(array[1, 3]) d;

set role authenticated;
set request.jwt.sub = '11111111-1111-1111-1111-111111111111';

insert into public.goals (category_id, title, horizon)
select id, 'Goal ' || name,
       case name when 'Professional' then 'short'::public.goal_horizon when 'Personal' then 'long' else 'mid' end
from public.categories;
insert into public.milestones (goal_id, title, position)
select g.id, 'Step ' || n, n from public.goals g, generate_series(1, 4) n;

create function pg_temp.ms(p_goal text, p_step text) returns uuid language sql as $$
  select m.id from public.milestones m join public.goals g on g.id = m.goal_id
   where g.title = 'Goal ' || p_goal and m.title = p_step and m.broken_down_at is null
$$;
create function pg_temp.complete(p_goal text, p_step text) returns text[] language sql as $$
  select coalesce(array_agg(badge_key order by badge_key), '{}') from public.complete_milestone(pg_temp.ms(p_goal, p_step))
$$;
create function pg_temp.expect(p_label text, p_got text[], p_want text[]) returns void language plpgsql as $$
begin
  if p_got is distinct from p_want then
    raise exception '%: expected %, got %', p_label, p_want, p_got;
  end if;
end $$;

-- Badges ----------------------------------------------------------------------
select pg_temp.expect('first completion',         pg_temp.complete('Professional', 'Step 1'), array['first-step', 'showing-up']);
select pg_temp.expect('reaching halfway',         pg_temp.complete('Professional', 'Step 2'), array['halfway']);
select pg_temp.expect('completing twice',         pg_temp.complete('Professional', 'Step 2'), '{}');
select pg_temp.expect('long-term milestone',      pg_temp.complete('Personal', 'Step 1'),     array['long-game']);
select pg_temp.expect('third category this week', pg_temp.complete('Physical', 'Step 1'),     array['balanced']);
select pg_temp.expect('past halfway',             pg_temp.complete('Professional', 'Step 3'), '{}');
select pg_temp.expect('finishing a goal',         pg_temp.complete('Professional', 'Step 4'), array['summit']);

do $$ begin
  if (select status from public.goals where title = 'Goal Professional') <> 'completed' then
    raise exception 'finished goal should be marked completed';
  end if;
end $$;

-- Undo keeps badges but reopens the goal.
select public.uncomplete_milestone(pg_temp.ms('Professional', 'Step 4'));
do $$ begin
  if (select status from public.goals where title = 'Goal Professional') <> 'active' then
    raise exception 'undoing the last milestone should reopen the goal';
  end if;
  if not exists (select 1 from public.badges_earned where badge_key = 'summit') then
    raise exception 'badges must never be taken back';
  end if;
end $$;

-- Notes: the tenth earns Reflective, and every call returns the note id.
do $$
declare r record; n integer := 0;
begin
  for i in 1..9 loop
    for r in select * from public.add_note((select id from public.goals where title = 'Goal Physical'), 'note ' || i) loop
      if r.note_id is null then raise exception 'add_note must return the note id'; end if;
      if r.badge_key is not null then raise exception 'note % should not earn a badge, got %', i, r.badge_key; end if;
      n := n + 1;
    end loop;
  end loop;
  if n <> 9 then raise exception 'add_note should return one row per quiet note, got %', n; end if;
  if (select array_agg(badge_key) from public.add_note((select id from public.goals where title = 'Goal Physical'), 'tenth'))
     is distinct from array['reflective'] then
    raise exception 'tenth note should earn reflective';
  end if;
end $$;

-- Swap streak -----------------------------------------------------------------
reset role;
insert into public.focus_items (user_id, day, milestone_id, swapped_out_at)
select '11111111-1111-1111-1111-111111111111', public.local_today('11111111-1111-1111-1111-111111111111') - d, pg_temp.ms('Physical', 'Step 2'), now()
from generate_series(1, 2) d;
insert into public.focus_items (user_id, day, milestone_id, position)
values ('11111111-1111-1111-1111-111111111111', public.local_today('11111111-1111-1111-1111-111111111111'), pg_temp.ms('Physical', 'Step 2'), 0);
set role authenticated;

do $$ begin
  if public.swap_focus_item(pg_temp.ms('Physical', 'Step 2'), pg_temp.ms('Personal', 'Step 2')) <> 3 then
    raise exception 'third swap in a row should report a streak of 3';
  end if;
end $$;

-- Break a step down -----------------------------------------------------------
do $$
declare v_titles text[];
begin
  perform public.breakdown_milestone(pg_temp.ms('Physical', 'Step 2'), array['Smaller A', 'Smaller B']);
  select array_agg(m.title order by m.position) into v_titles
    from public.milestones m join public.goals g on g.id = m.goal_id
   where g.title = 'Goal Physical' and m.broken_down_at is null;
  if v_titles is distinct from array['Step 1', 'Smaller A', 'Smaller B', 'Step 3', 'Step 4'] then
    raise exception 'breakdown should keep order, got %', v_titles;
  end if;
  if not exists (select 1 from public.focus_items f join public.milestones m on m.id = f.milestone_id
                  where m.title = 'Smaller A' and f.swapped_out_at is null) then
    raise exception 'first smaller step should be on today''s list';
  end if;
end $$;

-- Security --------------------------------------------------------------------
set request.jwt.sub = '22222222-2222-2222-2222-222222222222';
do $$ begin
  if (select count(*) from public.goals) <> 0 or (select count(*) from public.badges_earned) <> 0 then
    raise exception 'a user must not see another user''s goals or badges';
  end if;
  if (select count(*) from public.thoughts where user_id is null) = 0 then
    raise exception 'curated thoughts should be visible to every user';
  end if;
end $$;

reset role;
create temp table other_ms as select id from public.milestones where user_id = '11111111-1111-1111-1111-111111111111' and completed_at is null limit 1;
grant select on other_ms to authenticated;
set role authenticated;

do $$ begin
  perform public.complete_milestone((select id from other_ms));
  raise exception 'SECURITY: completed another user''s milestone';
exception when others then
  if sqlerrm like 'SECURITY:%' then raise; end if;
end $$;

do $$ begin
  insert into public.badges_earned (user_id, badge_key) values ('22222222-2222-2222-2222-222222222222', 'summit');
  raise exception 'SECURITY: inserted a badge directly';
exception when others then
  if sqlerrm like 'SECURITY:%' then raise; end if;
end $$;

do $$ begin
  perform public.award_badge('22222222-2222-2222-2222-222222222222', 'summit');
  raise exception 'SECURITY: called award_badge directly';
exception when others then
  if sqlerrm like 'SECURITY:%' then raise; end if;
end $$;

reset role;
\o
\echo All schema checks passed.
