-- Today's focus, picked by the database so iOS, web and the assistant all show the same list.
--
-- Rules (match the approved prototype):
-- * Up to 3 steps a day (or max_focus_items if lower): the next open milestone of an active goal,
--   one per goal, soonest due date first, then oldest goal.
-- * The list is picked once per day. Finished steps stay on it, checked, and don't trigger a refill.
--   It only tops up while today has fewer than 3 steps, for example after the first goal is added.
-- * A goal already on today's list, including one swapped out today, isn't picked again today.
-- * Swapped-out and broken-down steps are not returned.
create or replace function public.todays_focus()
returns table (
  focus_id        uuid,
  milestone_id    uuid,
  milestone_title text,
  due_date        date,
  completed_at    timestamptz,
  goal_id         uuid,
  goal_title      text,
  goal_horizon    public.goal_horizon,
  category_color  text,
  picked_by       text,
  sort_order      smallint
)
language plpgsql security invoker set search_path = '' as $$
#variable_conflict use_column
declare
  v_user  uuid := auth.uid();
  v_today date;
  v_limit integer;
  v_count integer;
  v_next  integer;
begin
  if v_user is null then raise exception 'not signed in'; end if;
  v_today := public.local_today(v_user);

  select least(3, p.max_focus_items) into v_limit from public.profiles p where p.id = v_user;
  v_limit := coalesce(v_limit, 3);

  select count(*), coalesce(max(f.position), -1) + 1 into v_count, v_next
    from public.focus_items f
    join public.milestones m on m.id = f.milestone_id
   where f.user_id = v_user and f.day = v_today
     and f.swapped_out_at is null and m.broken_down_at is null;

  if v_count < v_limit then
    insert into public.focus_items (user_id, day, milestone_id, position, picked_by)
    select v_user, v_today, c.id,
           (v_next + row_number() over (order by c.due_date nulls last, c.goal_created) - 1)::smallint,
           'app'
      from (
        select distinct on (g.id) m.id, m.due_date, g.created_at as goal_created
          from public.goals g
          join public.milestones m on m.goal_id = g.id
         where g.user_id = v_user and g.status = 'active'
           and m.completed_at is null and m.broken_down_at is null
           and not exists (
             select 1 from public.focus_items f
               join public.milestones fm on fm.id = f.milestone_id
              where f.user_id = v_user and f.day = v_today and fm.goal_id = g.id)
         order by g.id, m.position
      ) c
     order by c.due_date nulls last, c.goal_created
     limit v_limit - v_count
    on conflict do nothing;
  end if;

  return query
    select f.id, m.id, m.title, m.due_date, m.completed_at,
           g.id, g.title, g.horizon, cat.color, f.picked_by, f.position
      from public.focus_items f
      join public.milestones m  on m.id = f.milestone_id
      join public.goals g       on g.id = m.goal_id
      join public.categories cat on cat.id = g.category_id
     where f.user_id = v_user and f.day = v_today
       and f.swapped_out_at is null and m.broken_down_at is null
     order by f.position, f.created_at;
end $$;

revoke execute on function public.todays_focus() from public, anon;
grant execute on function public.todays_focus() to authenticated;
