-- El CEA decidió (30/09/2026) dejar solo dos avisos por turno:
--   1. Confirmación el día que se agenda (en una serie, solo la del primer turno; ver 0013).
--   2. Recordatorio 3 horas antes de cada clase.
-- Se quita el aviso del día anterior a las 6 p. m. El resto queda igual que en 0013.

create or replace function public.avisos_turnos_pendientes(p_ahora timestamptz default now())
returns table (turno_id bigint, tipo text, alumno_id bigint, telefono text, nombre text,
               fecha text, hora text, instructor text, saldo text)
language sql stable set search_path = ''
as $$
  with base as (
    select t.id, t.alumno_id, t.inicio, t.creado_en
    from public.turnos t
    join public.alumnos a on a.id = t.alumno_id
    where t.estado = 'agendado'
      and t.inicio > p_ahora
      and a.autoriza_datos
      and a.telefono is not null
      -- horario permitido: 6:00 a. m. a 8:59 p. m.
      and extract(hour from p_ahora at time zone 'America/Bogota') between 6 and 20
  ),
  candidatos as (
    -- 1. Confirmación: recién agendado, faltando más de 3 h (si no, basta el de 3 h)
    select b.id, b.inicio, 'confirmacion_turno' as tipo, 1 as prioridad
    from base b
    where b.creado_en > p_ahora - interval '24 hours'
      and b.inicio - p_ahora > interval '3 hours'
      -- solo el primero de los agendados juntos (mismo alumno, creados con < 15 min de diferencia)
      and not exists (select 1 from public.turnos h
                      where h.alumno_id = b.alumno_id
                        and h.id <> b.id
                        and h.estado = 'agendado'
                        and h.creado_en between b.creado_en - interval '15 minutes'
                                            and b.creado_en + interval '15 minutes'
                        and (h.inicio, h.id) < (b.inicio, b.id))
    union all
    -- 2. Tres horas antes (si cae entre 9 p. m. y 6 a. m., sale a las 6 a. m.)
    select b.id, b.inicio, 'recordatorio_3h', 2
    from base b
    where p_ahora >= b.inicio - interval '3 hours'
      and not exists (select 1 from public.mensajes m
                      where m.turno_id = b.id and m.ok
                        and m.enviado_en >= b.inicio - interval '3 hours 30 minutes')
  ),
  pendientes as (
    select distinct on (c.id) c.id, c.tipo, c.inicio
    from candidatos c
    where not exists (select 1 from public.mensajes m
                      where m.turno_id = c.id and m.tipo = c.tipo and m.ok)
      and (select count(*) from public.mensajes m
           where m.turno_id = c.id and m.tipo = c.tipo and not m.ok) < 3
    order by c.id, c.prioridad
  )
  select p.id,
         p.tipo,
         a.id,
         a.telefono,
         split_part(a.nombre, ' ', 1),
         public.fecha_larga(p.inicio),
         public.hora_corta(p.inicio),
         coalesce(i.nombre, 'por asignar'),
         case when s.saldo > 0 then public.formato_pesos(s.saldo) else 'al día' end
  from pendientes p
  join public.turnos t  on t.id = p.id
  join public.alumnos a on a.id = t.alumno_id
  join public.saldos s  on s.alumno_id = a.id
  left join public.instructores i on i.id = t.instructor_id
  order by p.inicio;
$$;

revoke execute on function public.avisos_turnos_pendientes(timestamptz) from public, anon, authenticated;
