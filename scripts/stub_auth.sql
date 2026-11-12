-- Somente para testes fora do Supabase: imita auth.uid() lendo uma GUC de sessão.
create schema if not exists auth;
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
