-- Minimal stand-in for the parts of Supabase the migration depends on,
-- so the schema can be tested on plain Postgres in CI.
create role anon nologin;
create role authenticated nologin;
create schema auth;
create table auth.users (id uuid primary key, raw_user_meta_data jsonb default '{}');
-- Supabase reads the signed-in user from the JWT; tests set request.jwt.sub instead.
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.sub', true), '')::uuid $$;
grant usage on schema auth to authenticated;
grant execute on function auth.uid() to authenticated;

-- Supabase grants the API roles access to everything new in public; RLS and
-- explicit revokes do the real restricting. Mirror that here so CI sees the
-- same privileges as the hosted database.
grant usage on schema public to anon, authenticated;
alter default privileges in schema public grant all on tables    to anon, authenticated;
alter default privileges in schema public grant all on sequences to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated;
