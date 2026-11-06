-- Agente de IA por WhatsApp (versión 1): preguntas frecuentes, saldo y clases, pasar a un humano.
--
-- Regla de seguridad: el agente solo puede ver los datos del número que le está escribiendo.
-- n8n pasa ese número desde el mensaje de WhatsApp (no lo decide el modelo de IA).

-- ── Conocimiento del CEA: lo único con lo que el agente responde preguntas generales ──
create table public.faq (
  id             bigint generated always as identity primary key,
  tema           text not null,               -- Precios, Requisitos, Horarios, Pagos…
  pregunta       text not null,
  respuesta      text not null,
  activo         boolean not null default true,
  actualizado_en timestamptz not null default now()
);

-- ── Solicitudes de atención por una persona ──
create table public.solicitudes_humano (
  id          bigint generated always as identity primary key,
  telefono    text not null,
  nombre      text,                           -- nombre del alumno o, si no es alumno, el de su perfil de WhatsApp
  alumno_id   bigint references public.alumnos (id) on delete set null,
  motivo      text not null,
  resumen     text,
  estado      text not null default 'pendiente' check (estado in ('pendiente', 'atendida')),
  creado_en   timestamptz not null default now(),
  atendida_en timestamptz
);
create index solicitudes_pendientes_idx on public.solicitudes_humano (estado, creado_en desc);

-- ── Memoria de conversaciones (la tabla que usa el nodo "Postgres Chat Memory" de n8n) ──
-- Se crea aquí para dejarla protegida: sin acceso desde internet, solo n8n (dueño de la base).
create table public.n8n_chat_histories (
  id         serial primary key,
  session_id varchar(255) not null,
  message    jsonb not null
);
create index n8n_chat_histories_sesion_idx on public.n8n_chat_histories (session_id);

-- ── Seguridad ──
alter table public.faq                enable row level security;
alter table public.solicitudes_humano enable row level security;
alter table public.n8n_chat_histories enable row level security;   -- sin políticas: nadie por la API

create policy personal_gestiona on public.faq
  for all to authenticated using ((select privado.es_personal())) with check ((select privado.es_personal()));
create policy personal_lee on public.solicitudes_humano
  for select to authenticated using ((select privado.es_personal()));
create policy personal_atiende on public.solicitudes_humano
  for update to authenticated using ((select privado.es_personal())) with check ((select privado.es_personal()));

revoke all on public.faq, public.solicitudes_humano, public.n8n_chat_histories from anon;
revoke all on public.n8n_chat_histories from authenticated;


-- ── Funciones que usa el agente (solo n8n) ──

-- Todo el conocimiento activo, en texto para el modelo.
create function public.agente_faq()
returns text
language sql stable set search_path = ''
as $$
  select coalesce(string_agg(format(E'[%s] %s\n%s', tema, pregunta, respuesta), E'\n\n' order by tema, id),
                  '(Todavía no hay información cargada.)')
  from public.faq where activo;
$$;

-- Datos del alumno que escribe: una fila si el número es de un alumno, ninguna si no.
create function public.agente_datos_alumno(p_telefono text)
returns table (nombre text, categoria text, saldo_pendiente text, saldo_segun text, proximas_clases text)
language sql stable set search_path = ''
as $$
  select a.nombre,
         coalesce(a.categoria, 'sin categoría registrada'),
         case when s.saldo > 0 then public.formato_pesos(s.saldo) else 'al día (no debe nada)' end,
         case when s.origen_saldo = 'facturacion'
              then 'sistema de facturación, actualizado el ' ||
                   to_char(s.saldo_actualizado_en at time zone 'America/Bogota', 'DD/MM/YYYY')
              else 'pagos registrados en la oficina' end,
         coalesce((
           select string_agg(public.fecha_larga(t.inicio) || ' a las ' || public.hora_corta(t.inicio) ||
                             ' (' || t.tipo || ', instructor: ' || coalesce(i.nombre, 'por asignar') || ')',
                             '; ' order by t.inicio)
           from (select * from public.turnos
                 where alumno_id = a.id and estado = 'agendado' and inicio > now()
                 order by inicio limit 5) t
           left join public.instructores i on i.id = t.instructor_id
         ), 'no tiene clases agendadas')
  from public.alumnos a
  join public.saldos s on s.alumno_id = a.id
  where a.telefono = p_telefono;
$$;

-- Registra que la persona necesita hablar con alguien del CEA. Si ya tiene una solicitud
-- pendiente, la actualiza en vez de crear otra.
create function public.agente_pedir_humano(p_telefono text, p_nombre_perfil text,
                                           p_motivo text, p_resumen text)
returns text
language plpgsql volatile set search_path = ''
as $$
declare
  v_alumno public.alumnos%rowtype;
  v_id bigint;
begin
  select * into v_alumno from public.alumnos where telefono = p_telefono;

  update public.solicitudes_humano
     set motivo = p_motivo, resumen = p_resumen, creado_en = now()
   where telefono = p_telefono and estado = 'pendiente'
  returning id into v_id;

  if v_id is null then
    insert into public.solicitudes_humano (telefono, nombre, alumno_id, motivo, resumen)
    values (p_telefono, coalesce(v_alumno.nombre, nullif(trim(p_nombre_perfil), '')), v_alumno.id,
            p_motivo, p_resumen)
    returning id into v_id;
  end if;

  return 'Solicitud #' || v_id || ' registrada. La oficina del CEA contactará a la persona.';
end;
$$;

revoke execute on function public.agente_faq()                                   from public, anon, authenticated;
revoke execute on function public.agente_datos_alumno(text)                      from public, anon, authenticated;
revoke execute on function public.agente_pedir_humano(text, text, text, text)    from public, anon, authenticated;
