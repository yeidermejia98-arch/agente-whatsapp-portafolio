-- =====================================================================
-- Turnos, saldos y recordatorios por WhatsApp para un CEA
-- Se ejecuta una sola vez en Supabase: SQL Editor → pegar → Run.
-- =====================================================================

-- Permite la regla "un instructor/alumno no puede tener dos turnos a la vez".
create extension if not exists btree_gist;


-- ---------------------------------------------------------------------
-- Tablas
-- ---------------------------------------------------------------------

-- Quién puede entrar al panel (secretaría, dirección).
-- Se agrega a mano después de crear el usuario en Authentication.
create table public.personal (
  user_id uuid primary key references auth.users (id) on delete cascade,
  nombre  text not null
);

create table public.instructores (
  id     bigint generated always as identity primary key,
  nombre text not null,
  activo boolean not null default true
);

create table public.alumnos (
  id             bigint generated always as identity primary key,
  nombre         text not null,
  -- Formato que exige WhatsApp: indicativo + número, solo dígitos. Ej.: 573001234567
  telefono       text not null unique check (telefono ~ '^[1-9][0-9]{7,14}$'),
  categoria      text,                                   -- A2, B1, C1…
  valor_curso    numeric(12, 0) not null default 0 check (valor_curso >= 0),
  -- Ley 1581 de 2012: sin autorización no se le envía nada.
  autoriza_datos boolean not null default false,
  creado_en      timestamptz not null default now()
);

create table public.turnos (
  id                      bigint generated always as identity primary key,
  alumno_id               bigint not null references public.alumnos (id) on delete cascade,
  instructor_id           bigint references public.instructores (id),
  inicio                  timestamptz not null,
  fin                     timestamptz not null,
  tipo                    text not null default 'practica'
                            check (tipo in ('practica', 'teorica', 'examen')),
  estado                  text not null default 'agendado'
                            check (estado in ('agendado', 'asistio', 'falto', 'cancelado')),
  recordatorio_enviado_en timestamptz,
  creado_en               timestamptz not null default now(),
  check (fin > inicio),
  -- La base de datos rechaza turnos que se crucen (los cancelados no cuentan).
  constraint turnos_sin_cruce_instructor
    exclude using gist (instructor_id with =, tstzrange(inicio, fin) with &&)
    where (estado <> 'cancelado'),
  constraint turnos_sin_cruce_alumno
    exclude using gist (alumno_id with =, tstzrange(inicio, fin) with &&)
    where (estado <> 'cancelado')
);

create table public.pagos (
  id        bigint generated always as identity primary key,
  alumno_id bigint not null references public.alumnos (id) on delete cascade,
  valor     numeric(12, 0) not null check (valor > 0),
  fecha     date not null default (now() at time zone 'America/Bogota')::date,
  medio     text,                                        -- efectivo, Nequi, transferencia…
  nota      text,
  creado_en timestamptz not null default now()
);

-- Registro de cada mensaje que n8n intentó enviar (sirve para auditar y para no repetir).
create table public.mensajes (
  id            bigint generated always as identity primary key,
  alumno_id     bigint references public.alumnos (id) on delete set null,
  turno_id      bigint references public.turnos (id) on delete set null,
  tipo          text not null check (tipo in ('recordatorio_turno', 'recordatorio_saldo')),
  ok            boolean not null,
  wa_message_id text,
  error         text,
  enviado_en    timestamptz not null default now()
);

create index turnos_inicio_idx   on public.turnos (inicio);
create index pagos_alumno_idx    on public.pagos (alumno_id);
create index mensajes_alumno_idx on public.mensajes (alumno_id, tipo, enviado_en desc);


-- ---------------------------------------------------------------------
-- Saldo de cada alumno = valor del curso − lo que ha pagado
-- ---------------------------------------------------------------------
create view public.saldos with (security_invoker = true) as
select a.id                                  as alumno_id,
       a.nombre,
       a.telefono,
       a.valor_curso,
       coalesce(sum(p.valor), 0)             as pagado,
       a.valor_curso - coalesce(sum(p.valor), 0) as saldo
from public.alumnos a
left join public.pagos p on p.alumno_id = a.id
group by a.id;


-- ---------------------------------------------------------------------
-- Seguridad: solo el personal registrado ve y cambia datos desde el panel
-- ---------------------------------------------------------------------
create function public.es_personal()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.personal where user_id = (select auth.uid()));
$$;

alter table public.personal     enable row level security;
alter table public.instructores enable row level security;
alter table public.alumnos      enable row level security;
alter table public.turnos       enable row level security;
alter table public.pagos        enable row level security;
alter table public.mensajes     enable row level security;

create policy personal_ve_su_fila on public.personal
  for select to authenticated using (user_id = (select auth.uid()));

create policy personal_gestiona on public.instructores
  for all to authenticated using ((select public.es_personal())) with check ((select public.es_personal()));
create policy personal_gestiona on public.alumnos
  for all to authenticated using ((select public.es_personal())) with check ((select public.es_personal()));
create policy personal_gestiona on public.turnos
  for all to authenticated using ((select public.es_personal())) with check ((select public.es_personal()));
create policy personal_gestiona on public.pagos
  for all to authenticated using ((select public.es_personal())) with check ((select public.es_personal()));
-- Los mensajes solo los escribe n8n; el panel solo los lee.
create policy personal_lee on public.mensajes
  for select to authenticated using ((select public.es_personal()));

-- Los visitantes sin sesión no tocan nada.
revoke all on all tables in schema public from anon;


-- ---------------------------------------------------------------------
-- Funciones que usa n8n (se conecta como dueño de la base, no desde el panel)
-- ---------------------------------------------------------------------

-- 350000 → "$350.000"
create function public.formato_pesos(valor numeric)
returns text
language sql immutable set search_path = ''
as $$
  select '$' || replace(to_char(valor, 'FM999,999,999,990'), ',', '.');
$$;

-- → "viernes 26 de septiembre"
create function public.fecha_larga(momento timestamptz)
returns text
language sql immutable set search_path = ''
as $$
  select (array['lunes','martes','miércoles','jueves','viernes','sábado','domingo'])
           [extract(isodow from momento at time zone 'America/Bogota')::int]
      || ' ' || extract(day from momento at time zone 'America/Bogota')::int
      || ' de ' ||
         (array['enero','febrero','marzo','abril','mayo','junio','julio',
                'agosto','septiembre','octubre','noviembre','diciembre'])
           [extract(month from momento at time zone 'America/Bogota')::int];
$$;

-- → "3:00 p. m."
create function public.hora_corta(momento timestamptz)
returns text
language sql immutable set search_path = ''
as $$
  select to_char(momento at time zone 'America/Bogota', 'FMHH12:MI')
      || case when extract(hour from momento at time zone 'America/Bogota') < 12
              then ' a. m.' else ' p. m.' end;
$$;

-- Turnos de mañana que aún no tienen recordatorio.
create function public.turnos_por_recordar()
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
    and (t.inicio at time zone 'America/Bogota')::date
        = (now() at time zone 'America/Bogota')::date + 1
  order by t.inicio;
$$;

-- Alumnos con saldo pendiente a quienes no se les ha avisado en los últimos N días.
create function public.saldos_por_recordar(dias_entre_avisos int default 7)
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
    and not exists (
      select 1 from public.mensajes m
      where m.alumno_id = s.alumno_id
        and m.tipo = 'recordatorio_saldo'
        and m.ok
        and m.enviado_en > now() - make_interval(days => dias_entre_avisos)
    )
  order by s.saldo desc;
$$;

-- n8n llama esto después de cada intento de envío.
create function public.registrar_recordatorio_turno(p_turno_id bigint, p_ok boolean,
                                                    p_wa_message_id text, p_error text)
returns void
language sql volatile set search_path = ''
as $$
  insert into public.mensajes (alumno_id, turno_id, tipo, ok, wa_message_id, error)
  select t.alumno_id, t.id, 'recordatorio_turno', p_ok,
         nullif(p_wa_message_id, ''), nullif(p_error, '')
  from public.turnos t where t.id = p_turno_id;

  update public.turnos set recordatorio_enviado_en = now()
  where id = p_turno_id and p_ok;
$$;

create function public.registrar_recordatorio_saldo(p_alumno_id bigint, p_ok boolean,
                                                    p_wa_message_id text, p_error text)
returns void
language sql volatile set search_path = ''
as $$
  insert into public.mensajes (alumno_id, tipo, ok, wa_message_id, error)
  values (p_alumno_id, 'recordatorio_saldo', p_ok,
          nullif(p_wa_message_id, ''), nullif(p_error, ''));
$$;

-- Estas funciones no se exponen al panel ni a internet: solo n8n (dueño) las usa.
revoke execute on function public.turnos_por_recordar()                                   from public, anon, authenticated;
revoke execute on function public.saldos_por_recordar(int)                                from public, anon, authenticated;
revoke execute on function public.registrar_recordatorio_turno(bigint, boolean, text, text) from public, anon, authenticated;
revoke execute on function public.registrar_recordatorio_saldo(bigint, boolean, text, text) from public, anon, authenticated;
