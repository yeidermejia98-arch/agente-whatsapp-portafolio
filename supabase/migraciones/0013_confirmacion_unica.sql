-- Agendamiento múltiple (p. ej. lunes a sábado a la misma hora): antes, cada turno
-- recién creado mandaba su propia confirmación → el alumno recibía 6 mensajes iguales.
-- Ahora, de los turnos de un alumno agendados juntos (creados con menos de 15 min de
-- diferencia), solo se confirma EL PRIMERO.
-- Los demás siguen recibiendo su aviso del día anterior (6 p. m.) y el de 3 horas antes.
-- Único cambio frente a 0004: la condición "not exists (turno hermano anterior)".

create or replace function public.avisos_turnos_pendientes(p_ahora timestamptz default now())
returns table (turno_id bigint, tipo text, alumno_id bigint, telefono text, nombre text,
               fecha text, hora text, instructor text, saldo text)
language sql stable set search_path = ''
as $$
  with base as (
    select t.id, t.alumno_id, t.inicio, t.creado_en,
           -- 00:00 y 6:00 p. m. del día anterior a la clase, hora Colombia
           (((t.inicio at time zone 'America/Bogota')::date - 1)::timestamp)
             at time zone 'America/Bogota'                              as dia_anterior,
           (((t.inicio at time zone 'America/Bogota')::date - 1) + time '18:00')
             at time zone 'America/Bogota'                              as dia_anterior_6pm
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
    select b.id, b.inicio, 'recordatorio_dia_anterior', 2
    from base b
    where p_ahora >= b.dia_anterior_6pm
      and b.inicio - p_ahora > interval '3 hours'
      and not exists (select 1 from public.mensajes m
                      where m.turno_id = b.id and m.ok and m.enviado_en >= b.dia_anterior)
    union all
    select b.id, b.inicio, 'recordatorio_3h', 3
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
