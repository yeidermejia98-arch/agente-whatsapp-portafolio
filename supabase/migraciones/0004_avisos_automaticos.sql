-- Avisos automáticos (n8n revisa cada 5 minutos los de turnos y a las 12 m. los de saldo).
--
-- TURNOS (todos con la plantilla recordatorio_turno):
--   1. Confirmación: apenas se agenda (turnos creados en las últimas 24 h).
--   2. Día anterior: a las 6 p. m. del día anterior, si ese día aún no recibió ningún aviso.
--   3. Tres horas antes de la clase.
--   - Nunca se envía entre 9 p. m. y 6 a. m.: lo que caiga ahí sale a las 6 a. m.
--   - Máximo un aviso por turno en cada revisión, y si falta menos de 3 h solo sale el de 3 h.
--   - Máximo 3 intentos fallidos por aviso (p. ej., número sin WhatsApp).
-- SALDOS: cada 8 días y siempre los días 15 y 30 (en febrero, el último día del mes).
--
-- Las funciones reciben p_ahora para poder probarlas con cualquier fecha y hora.

alter table public.mensajes drop constraint mensajes_tipo_check;
alter table public.mensajes add constraint mensajes_tipo_check check (tipo in (
  'recordatorio_turno',          -- histórico (versión anterior: 6 p. m. del día anterior)
  'confirmacion_turno', 'recordatorio_dia_anterior', 'recordatorio_3h',
  'recordatorio_saldo'));

create index mensajes_turno_idx on public.mensajes (turno_id, tipo);

-- La versión anterior se reemplaza por las de abajo.
drop function public.turnos_por_recordar();
drop function public.registrar_recordatorio_turno(bigint, boolean, text, text);
drop function public.saldos_por_recordar(int);


create function public.avisos_turnos_pendientes(p_ahora timestamptz default now())
returns table (turno_id bigint, tipo text, alumno_id bigint, telefono text, nombre text,
               fecha text, hora text, instructor text, saldo text)
language sql stable set search_path = ''
as $$
  with base as (
    select t.id, t.inicio, t.creado_en,
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

create function public.registrar_aviso_turno(p_turno_id bigint, p_tipo text, p_ok boolean,
                                             p_wa_message_id text, p_error text)
returns void
language sql volatile set search_path = ''
as $$
  insert into public.mensajes (alumno_id, turno_id, tipo, ok, wa_message_id, error)
  select t.alumno_id, t.id, p_tipo, p_ok, nullif(p_wa_message_id, ''), nullif(p_error, '')
  from public.turnos t where t.id = p_turno_id;

  update public.turnos set recordatorio_enviado_en = now()
  where id = p_turno_id and p_ok;
$$;

create function public.saldos_para_hoy(p_ahora timestamptz default now())
returns table (alumno_id bigint, telefono text, nombre text, saldo text)
language sql stable set search_path = ''
as $$
  with hoy as (
    select (p_ahora at time zone 'America/Bogota')::date as d
  )
  select s.alumno_id, s.telefono, split_part(s.nombre, ' ', 1), public.formato_pesos(s.saldo)
  from public.saldos s
  join public.alumnos a on a.id = s.alumno_id
  cross join hoy
  where s.saldo > 0
    and a.autoriza_datos
    and a.telefono is not null
    -- nunca dos avisos de saldo el mismo día
    and not exists (select 1 from public.mensajes m
                    where m.alumno_id = s.alumno_id and m.tipo = 'recordatorio_saldo' and m.ok
                      and (m.enviado_en at time zone 'America/Bogota')::date = hoy.d)
    and (
      -- siempre los 15 y los 30
      extract(day from hoy.d) in (15, 30)
      -- en febrero (no tiene 30): el último día del mes
      or (hoy.d = (date_trunc('month', hoy.d) + interval '1 month - 1 day')::date
          and extract(day from hoy.d) < 30)
      -- cada 8 días desde el último aviso de saldo
      or not exists (select 1 from public.mensajes m
                     where m.alumno_id = s.alumno_id and m.tipo = 'recordatorio_saldo' and m.ok
                       and (m.enviado_en at time zone 'America/Bogota')::date > hoy.d - 8)
    )
  order by s.saldo desc;
$$;

-- Solo n8n (dueño de la base) las usa.
revoke execute on function public.avisos_turnos_pendientes(timestamptz)                      from public, anon, authenticated;
revoke execute on function public.registrar_aviso_turno(bigint, text, boolean, text, text)     from public, anon, authenticated;
revoke execute on function public.saldos_para_hoy(timestamptz)                                 from public, anon, authenticated;
