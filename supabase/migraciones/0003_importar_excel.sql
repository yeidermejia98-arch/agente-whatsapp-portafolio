-- Importar alumnos y saldos desde el "Listado de Facturas" (Excel) del sistema de facturación.
-- - Cada alumno se identifica por su documento (cédula).
-- - El saldo que trae el Excel manda sobre el cálculo "valor del curso − pagos".
-- - El listado no trae teléfono: se permite alumno sin teléfono (no recibe mensajes hasta tenerlo).

alter table public.alumnos
  add column documento           text unique,
  add column saldo_externo       numeric(12, 0) check (saldo_externo >= 0),
  add column saldo_actualizado_en timestamptz,
  alter column telefono drop not null;

-- Saldo: si vino del Excel, se usa ese; si no, valor del curso − pagos registrados en el panel.
create or replace view public.saldos with (security_invoker = true) as
select a.id                                  as alumno_id,
       a.nombre,
       a.telefono,
       a.valor_curso,
       case when a.saldo_externo is not null
            then a.valor_curso - a.saldo_externo
            else coalesce(sum(p.valor), 0) end as pagado,
       coalesce(a.saldo_externo, a.valor_curso - coalesce(sum(p.valor), 0)) as saldo,
       case when a.saldo_externo is not null then 'facturacion' else 'panel' end as origen_saldo,
       a.saldo_actualizado_en
from public.alumnos a
left join public.pagos p on p.alumno_id = a.id
group by a.id;

-- Sin teléfono no se intenta enviar nada.
create or replace function public.turnos_por_recordar()
returns table (turno_id bigint, alumno_id bigint, telefono text, nombre text,
               fecha text, hora text, instructor text, saldo text)
language sql stable set search_path = ''
as $$
  select t.id,
         a.id,
         a.telefono,
         split_part(a.nombre, ' ', 1),
         public.fecha_larga(t.inicio),
         public.hora_corta(t.inicio),
         coalesce(i.nombre, 'por asignar'),
         case when s.saldo > 0 then public.formato_pesos(s.saldo) else 'al día' end
  from public.turnos t
  join public.alumnos a      on a.id = t.alumno_id
  join public.saldos s       on s.alumno_id = a.id
  left join public.instructores i on i.id = t.instructor_id
  where t.estado = 'agendado'
    and t.recordatorio_enviado_en is null
    and a.autoriza_datos
    and a.telefono is not null
    and (t.inicio at time zone 'America/Bogota')::date
        = (now() at time zone 'America/Bogota')::date + 1
  order by t.inicio;
$$;

create or replace function public.saldos_por_recordar(dias_entre_avisos int default 7)
returns table (alumno_id bigint, telefono text, nombre text, saldo text)
language sql stable set search_path = ''
as $$
  select s.alumno_id,
         s.telefono,
         split_part(s.nombre, ' ', 1),
         public.formato_pesos(s.saldo)
  from public.saldos s
  join public.alumnos a on a.id = s.alumno_id
  where s.saldo > 0
    and a.autoriza_datos
    and a.telefono is not null
    and not exists (
      select 1 from public.mensajes m
      where m.alumno_id = s.alumno_id
        and m.tipo = 'recordatorio_saldo'
        and m.ok
        and m.enviado_en > now() - make_interval(days => dias_entre_avisos)
    )
  order by s.saldo desc;
$$;

revoke execute on function public.turnos_por_recordar()    from public, anon, authenticated;
revoke execute on function public.saldos_por_recordar(int) from public, anon, authenticated;

-- Importación: crea o actualiza alumnos por documento, todo o nada (una sola transacción).
-- Se ejecuta con los permisos de quien la llama (security invoker): las políticas RLS
-- siguen aplicando, así que solo el personal del CEA puede importar.
-- filas: [{documento, nombre, categoria, valor, saldo, telefono}]
create function public.importar_alumnos(filas jsonb, autorizan boolean)
returns table (creados int, actualizados int, sin_telefono int)
language plpgsql volatile security invoker set search_path = ''
as $$
declare
  v_creados int;
  v_actualizados int;
begin
  with datos as (
    select trim(f.documento) as documento, trim(f.nombre) as nombre, f.categoria,
           f.valor, f.saldo, nullif(trim(f.telefono), '') as telefono
    from jsonb_to_recordset(filas)
      as f(documento text, nombre text, categoria text, valor numeric, saldo numeric, telefono text)
    where nullif(trim(f.documento), '') is not null
  ),
  guardados as (
    insert into public.alumnos as a
      (documento, nombre, categoria, valor_curso, saldo_externo, saldo_actualizado_en,
       telefono, autoriza_datos)
    select documento, nombre, categoria, coalesce(valor, 0), saldo, now(), telefono, autorizan
    from datos
    on conflict (documento) do update set
      nombre               = excluded.nombre,
      categoria            = coalesce(excluded.categoria, a.categoria),
      valor_curso          = excluded.valor_curso,
      saldo_externo        = excluded.saldo_externo,
      saldo_actualizado_en = now(),
      telefono             = coalesce(excluded.telefono, a.telefono),   -- no borra un teléfono ya guardado
      autoriza_datos       = a.autoriza_datos or excluded.autoriza_datos
    returning (xmax = 0) as es_nuevo
  )
  select count(*) filter (where es_nuevo), count(*) filter (where not es_nuevo)
    into v_creados, v_actualizados
  from guardados;

  return query
    select v_creados, v_actualizados,
           (select count(*)::int from public.alumnos al
            where al.telefono is null
              and al.documento in (select d.value->>'documento' from jsonb_array_elements(filas) d));
end;
$$;

revoke execute on function public.importar_alumnos(jsonb, boolean) from public, anon;
grant execute on function public.importar_alumnos(jsonb, boolean) to authenticated;
