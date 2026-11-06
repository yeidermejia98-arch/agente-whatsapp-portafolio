-- Avisos de turno por JORNADA (pedido del CEA, 02/10/2026).
-- Un alumno con varios bloques el mismo día (p. ej. 7–9, 9–11 y 11–12) recibía un mensaje
-- por bloque. Ahora:
--   * Confirmación al agendar: un solo mensaje con el horario completo del día
--     ("7:00 a. m. a 12:00 p. m."). Si se agendaron varios días juntos, dice del día
--     primero al último y el horario (si es el mismo todos los días).
--   * Recordatorio 3 h antes: uno solo por día, 3 h antes del PRIMER bloque, con el
--     horario completo de ese día.
-- La plantilla de Meta no cambia: {{2}} lleva la fecha y {{3}} el horario.

-- Horario de un alumno en un día (bloques seguidos se unen):
--   7–9, 9–11, 11–12  → "7:00 a. m. a 12:00 p. m."
--   7–9 y 2–4         → "7:00 a. m. a 9:00 a. m. y 2:00 p. m. a 4:00 p. m."
create function privado.horario_del_dia(p_alumno_id bigint, p_dia date)
returns text
language sql stable set search_path = ''
as $$
  with t as (
    select inicio, fin from public.turnos
    where alumno_id = p_alumno_id and estado = 'agendado'
      and (inicio at time zone 'America/Bogota')::date = p_dia
  ),
  marcados as (  -- empieza un bloque nuevo si no toca con lo anterior
    select inicio, fin,
           case when inicio <= max(fin) over (order by inicio rows between unbounded preceding and 1 preceding)
                then 0 else 1 end as nuevo
    from t
  ),
  grupos as (
    select inicio, fin, sum(nuevo) over (order by inicio) as grupo from marcados
  ),
  bloques as (
    select min(inicio) as desde, max(fin) as hasta from grupos group by grupo
  )
  select string_agg(public.hora_corta(desde) || ' a ' || public.hora_corta(hasta), ' y ' order by desde)
  from bloques;
$$;

-- Fecha y horario para la confirmación de un agendamiento (los turnos del alumno
-- creados con menos de 15 minutos de diferencia cuentan como un solo agendamiento).
create function privado.resumen_agendamiento(p_turno_id bigint)
returns table (fecha text, hora text)
language sql stable set search_path = ''
as $$
  with t as (select alumno_id, creado_en from public.turnos where id = p_turno_id),
  lote as (
    select h.inicio, (h.inicio at time zone 'America/Bogota')::date as dia
    from public.turnos h, t
    where h.alumno_id = t.alumno_id and h.estado = 'agendado'
      and h.creado_en between t.creado_en - interval '15 minutes' and t.creado_en + interval '15 minutes'
  ),
  dias as (
    select d.dia, privado.horario_del_dia((select alumno_id from t), d.dia) as horario
    from (select distinct dia from lote) d
  )
  select case when (select count(*) from dias) = 1
              then public.fecha_larga((select min(inicio) from lote))
              else 'del ' || public.fecha_larga((select min(inicio) from lote))
                   || ' al ' || public.fecha_larga((select max(inicio) from lote))
                   || ' (' || (select count(*) from dias) || ' días)' end,
         case when (select count(distinct horario) from dias) = 1
              then (select min(horario) from dias)
                   || case when (select count(*) from dias) > 1 then ', todos los días' else '' end
              else 'distinto cada día; Lizz le indica el horario de cada día' end;
$$;

revoke execute on function privado.horario_del_dia(bigint, date) from public, anon, authenticated;
revoke execute on function privado.resumen_agendamiento(bigint) from public, anon, authenticated;


create or replace function public.avisos_turnos_pendientes(p_ahora timestamptz default now())
returns table (turno_id bigint, tipo text, alumno_id bigint, telefono text, nombre text,
               fecha text, hora text, instructor text, saldo text)
language sql stable set search_path = ''
as $$
  with base as (
    select t.id, t.alumno_id, t.inicio, t.creado_en,
           (t.inicio at time zone 'America/Bogota')::date as dia
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
    -- 1. Confirmación: solo el primer turno de cada agendamiento, faltando más de 3 h
    select b.id, b.inicio, b.dia, b.alumno_id, 'confirmacion_turno' as tipo, 1 as prioridad
    from base b
    where b.creado_en > p_ahora - interval '24 hours'
      and b.inicio - p_ahora > interval '3 hours'
      and not exists (select 1 from public.turnos h
                      where h.alumno_id = b.alumno_id
                        and h.id <> b.id
                        and h.estado = 'agendado'
                        and h.creado_en between b.creado_en - interval '15 minutes'
                                            and b.creado_en + interval '15 minutes'
                        and (h.inicio, h.id) < (b.inicio, b.id))
    union all
    -- 2. Tres horas antes del PRIMER bloque del día (uno por jornada)
    select b.id, b.inicio, b.dia, b.alumno_id, 'recordatorio_3h', 2
    from base b
    where p_ahora >= b.inicio - interval '3 hours'
      and not exists (select 1 from public.turnos h
                      where h.alumno_id = b.alumno_id
                        and h.id <> b.id
                        and h.estado = 'agendado'
                        and (h.inicio at time zone 'America/Bogota')::date = b.dia
                        and (h.inicio, h.id) < (b.inicio, b.id))
      and not exists (select 1 from public.mensajes m
                      where m.turno_id = b.id and m.ok
                        and m.enviado_en >= b.inicio - interval '3 hours 30 minutes')
  ),
  pendientes as (
    select distinct on (c.id) c.id, c.tipo, c.inicio, c.dia, c.alumno_id
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
         case when p.tipo = 'confirmacion_turno' then r.fecha else public.fecha_larga(p.inicio) end,
         case when p.tipo = 'confirmacion_turno' then r.hora
              else privado.horario_del_dia(p.alumno_id, p.dia) end,
         coalesce(i.nombre, 'por asignar'),
         case when s.saldo > 0 then public.formato_pesos(s.saldo) else 'al día' end
  from pendientes p
  join public.turnos t  on t.id = p.id
  join public.alumnos a on a.id = t.alumno_id
  join public.saldos s  on s.alumno_id = a.id
  left join public.instructores i on i.id = t.instructor_id
  left join lateral privado.resumen_agendamiento(p.id) r on p.tipo = 'confirmacion_turno'
  order by p.inicio;
$$;

revoke execute on function public.avisos_turnos_pendientes(timestamptz) from public, anon, authenticated;
