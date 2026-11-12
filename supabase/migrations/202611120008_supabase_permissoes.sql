-- Permissões do schema próprio "radar" no Supabase.
-- service_role (Worker): leitura e escrita (ignora RLS por desenho).
-- authenticated: só leitura, filtrada pelas políticas RLS da migração 005.
-- anon: nada.
grant usage on schema radar to service_role, authenticated;
grant all on all tables in schema radar to service_role;
grant all on all sequences in schema radar to service_role;
grant execute on all functions in schema radar to service_role, authenticated;
grant select on all tables in schema radar to authenticated;
alter default privileges in schema radar grant all on tables to service_role;
alter default privileges in schema radar grant all on sequences to service_role;
alter default privileges in schema radar grant select on tables to authenticated;
alter default privileges in schema radar grant execute on functions to service_role, authenticated;

-- Expõe o schema "radar" na API REST (PostgREST), mantendo os padrões do Supabase.
-- Equivale a incluir "radar" em Settings → API → Exposed schemas; confira lá após rodar.
alter role authenticator set pgrst.db_schemas = 'public, graphql_public, radar';
notify pgrst, 'reload config';
