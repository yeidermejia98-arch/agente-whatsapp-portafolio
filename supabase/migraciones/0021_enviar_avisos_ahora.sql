-- Enviar ahora desde el panel: de 9 p. m. a 6 a. m. los avisos esperan (horario de descanso),
-- pero si la secretaría agenda de noche puede pulsar "Enviar ahora" y salen de inmediato.
-- El envío automático (cada 5 min) sigue respetando el descanso.

-- Igual que en 0016, con un parámetro nuevo: p_ignorar_descanso (solo lo usa el botón).
drop function public.avisos_turnos_pendientes(timestamptz);

create function public.avisos_turnos_pendientes(p_ahora timestamptz default now(),
                                                p_ignorar_descanso boolean default false)
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
      -- horario permitido: 6:00 a. m. a 8:59 p. m. (salvo que se pida enviar ya)
      and (p_ignorar_descanso or extract(hour from p_ahora at time zone 'America/Bogota') between 6 and 20)
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

revoke execute on function public.avisos_turnos_pendientes(timestamptz, boolean) from public, anon, authenticated;

-- Para el panel: qué avisos saldrían si se pulsa "Enviar ahora" (sin teléfonos).
create function public.avisos_en_espera()
returns table (nombre text, tipo text, fecha text, hora text)
language sql stable security definer set search_path = ''
as $$
  select a.nombre, p.tipo, p.fecha, p.hora
  from public.avisos_turnos_pendientes(now(), true) p
  join public.alumnos a on a.id = p.alumno_id
  where privado.es_personal();
$$;

revoke execute on function public.avisos_en_espera() from public, anon;
grant execute on function public.avisos_en_espera() to authenticated;
