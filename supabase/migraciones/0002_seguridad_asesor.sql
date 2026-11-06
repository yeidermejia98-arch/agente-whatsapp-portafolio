-- Correcciones que pidió el asesor de seguridad de Supabase.

-- 1. Las extensiones van en su propio esquema, no en "public" (que se publica en la API).
create schema if not exists extensions;
alter extension btree_gist set schema extensions;

-- 2. es_personal() se usa dentro de las políticas RLS, pero no debe poder llamarse
--    desde internet (/rest/v1/rpc/es_personal). Se mueve a un esquema que la API no publica.
create schema if not exists privado;
revoke all on schema privado from public, anon;
grant usage on schema privado to authenticated;

alter function public.es_personal() set schema privado;
revoke execute on function privado.es_personal() from public, anon;
grant execute on function privado.es_personal() to authenticated;
