-- Applied after the first deploy, based on Supabase's security and performance advisors.
--
-- Signed-out callers get nothing. Supabase grants EXECUTE on new public functions
-- to anon and authenticated by default, so take it back explicitly.
-- complete_milestone and add_note stay SECURITY DEFINER and callable by signed-in
-- users on purpose: they are the only way badges get awarded, and they check
-- ownership against auth.uid() themselves.
revoke execute on function public.complete_milestone(uuid)                  from public, anon;
revoke execute on function public.uncomplete_milestone(uuid)                from public, anon;
revoke execute on function public.add_note(uuid, text, public.entry_source) from public, anon;
revoke execute on function public.swap_streak(uuid)                         from public, anon;
revoke execute on function public.swap_focus_item(uuid, uuid)               from public, anon;
revoke execute on function public.breakdown_milestone(uuid, text[])         from public, anon;
revoke execute on function public.local_today(uuid)                         from public, anon;

-- Trigger-only functions: nobody calls these over the API.
revoke execute on function public.handle_new_user()  from public, anon, authenticated;
revoke execute on function public.touch_updated_at() from public, anon, authenticated;

-- Covering indexes for foreign keys (deletes and joins).
create index if not exists badges_earned_badge_key_idx    on public.badges_earned (badge_key);
create index if not exists focus_items_milestone_idx      on public.focus_items (milestone_id);
create index if not exists goal_notes_user_idx            on public.goal_notes (user_id);
create index if not exists goals_category_idx             on public.goals (category_id);
create index if not exists milestones_parent_idx          on public.milestones (parent_id) where parent_id is not null;
create index if not exists milestones_user_idx            on public.milestones (user_id);
create index if not exists thought_favorites_thought_idx  on public.thought_favorites (thought_id);
create index if not exists thought_history_thought_idx    on public.thought_history (thought_id);
create index if not exists thoughts_user_idx              on public.thoughts (user_id) where user_id is not null;
