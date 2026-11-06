-- Puente de atención humana: la oficina conversa con el cliente desde su propio WhatsApp.
--
-- 1. Lizz usa pasar_a_humano → se abre una "atención" y la oficina recibe un aviso.
-- 2. Mientras la atención está activa, Lizz NO responde a ese cliente: lo que escriba se
--    reenvía a la oficina ("💬 Juan: …").
-- 3. La oficina contesta usando "Responder" sobre el mensaje del cliente: n8n le hace llegar
--    el texto al cliente desde el número de Lizz. "listo" termina la atención.
-- 4. Si en horario de oficina nadie contesta en 30 minutos, la atención vence y Lizz retoma.
--    Fuera de horario la atención espera (hasta 24 h) a que la oficina abra.
--
-- Arranca APAGADO. Se enciende con puente_config.activo y, para pruebas, se limita a los
-- números de puente_config.solo_telefonos (vacío = todos).

create table public.puente_config (
  id                        int primary key default 1 check (id = 1),
  activo                    boolean not null default false,
  solo_telefonos            text[] not null default '{}',
  minutos_espera            int not null default 30,
  oficina_ultimo_mensaje_en timestamptz   -- para saber si la ventana de 24 h de WhatsApp está abierta
);
insert into public.puente_config default values;

create table public.atenciones (
  id                   bigint generated always as identity primary key,
  telefono             text not null,
  nombre               text,
  motivo               text,
  estado               text not null default 'activa' check (estado in ('activa', 'cerrada', 'vencida')),
  creada_en            timestamptz not null default now(),
  aviso_enviado_en     timestamptz,
  primera_respuesta_en timestamptz,
  ultima_actividad_en  timestamptz not null default now(),
  cerrada_en           timestamptz,
  cerrada_por          text
);
create unique index atenciones_una_activa_idx on public.atenciones (telefono) where estado = 'activa';
create index atenciones_estado_idx on public.atenciones (estado, creada_en desc);

-- Mensajes enviados a la oficina → a qué atención pertenecen (para enrutar su "Responder")
create table public.atencion_mensajes (
  wamid       text primary key,
  atencion_id bigint not null references public.atenciones (id) on delete cascade,
  creado_en   timestamptz not null default now()
);

alter table public.puente_config    enable row level security;
alter table public.atenciones       enable row level security;
alter table public.atencion_mensajes enable row level security;
create policy personal_lee on public.atenciones
  for select to authenticated using ((select privado.es_personal()));
create policy personal_gestiona on public.puente_config
  for all to authenticated using ((select privado.es_personal())) with check ((select privado.es_personal()));
revoke all on public.puente_config, public.atenciones, public.atencion_mensajes from anon;


-- Horario de oficina: lunes a sábado, 7:00–12:00 y 2:00–6:00 p. m. (hora Colombia)
create function privado.en_horario_oficina(p_momento timestamptz)
returns boolean
language sql immutable set search_path = ''
as $$
  select extract(isodow from p_momento at time zone 'America/Bogota') between 1 and 6
     and (extract(hour from p_momento at time zone 'America/Bogota') between 7 and 11
          or extract(hour from p_momento at time zone 'America/Bogota') between 14 and 17);
$$;

create function privado.puente_aplica(p_telefono text)
returns boolean
language sql stable set search_path = ''
as $$
  select coalesce((select c.activo and (cardinality(c.solo_telefonos) = 0 or p_telefono = any (c.solo_telefonos))
                   from public.puente_config c where c.id = 1), false);
$$;

-- ¿La oficina escribió en las últimas 23 h? Si no, WhatsApp exige plantilla.
create function privado.oficina_necesita_plantilla(p_ahora timestamptz)
returns boolean
language sql stable set search_path = ''
as $$
  select coalesce((select c.oficina_ultimo_mensaje_en is null or c.oficina_ultimo_mensaje_en < p_ahora - interval '23 hours'
                   from public.puente_config c where c.id = 1), true);
$$;

-- Texto apto para una variable de plantilla (sin saltos de línea ni espacios repetidos)
create function privado.texto_plano(p_texto text, p_max int default 900)
returns text
language sql immutable set search_path = ''
as $$ select left(regexp_replace(coalesce(p_texto, ''), '\s+', ' ', 'g'), p_max); $$;


-- Lizz pide atención humana: además de la solicitud del panel, abre la atención (si el
-- puente aplica a ese número) y le dice a Lizz qué contestarle a la persona.
create or replace function public.agente_pedir_humano(p_telefono text, p_nombre_perfil text, p_motivo text, p_resumen text)
returns text
language plpgsql set search_path = ''
as $$
declare
  v_alumno public.alumnos%rowtype;
  v_id bigint;
  v_hora text := to_char(now() at time zone 'America/Bogota', 'DD/MM HH12:MI am');
  v_nombre text;
begin
  select * into v_alumno from public.alumnos where telefono = p_telefono;
  v_nombre := coalesce(v_alumno.nombre, nullif(trim(p_nombre_perfil), ''));

  update public.solicitudes_humano s
     set motivo    = case when position(p_motivo in s.motivo) > 0 then s.motivo
                          else s.motivo || ' + ' || p_motivo end,
         resumen   = concat_ws(E'\n', s.resumen, '[' || v_hora || '] ' || p_resumen),
         creado_en = now()
   where s.telefono = p_telefono and s.estado = 'pendiente'
  returning s.id into v_id;

  if v_id is null then
    insert into public.solicitudes_humano (telefono, nombre, alumno_id, motivo, resumen)
    values (p_telefono, v_nombre, v_alumno.id, p_motivo, '[' || v_hora || '] ' || p_resumen)
    returning id into v_id;
  end if;

  if not privado.puente_aplica(p_telefono) then
    return 'Solicitud #' || v_id || ' registrada. La oficina del CEA contactará a la persona.';
  end if;

  insert into public.atenciones (telefono, nombre, motivo)
  select p_telefono, v_nombre, privado.texto_plano(p_motivo || ': ' || p_resumen, 300)
  where not exists (select 1 from public.atenciones a where a.telefono = p_telefono and a.estado = 'activa');

  if privado.en_horario_oficina(now()) then
    return 'Solicitud #' || v_id || ' registrada y enviada a la oficina. Dile a la persona que un asesor de la oficina '
        || 'le escribirá por este mismo chat en unos minutos, y despídete con amabilidad. No sigas resolviendo el tema.';
  end if;
  return 'Solicitud #' || v_id || ' registrada y enviada a la oficina, que ahora está cerrada. Dile a la persona que la '
      || 'oficina atiende de lunes a sábado de 7:00 a. m. a 12:00 m. y de 2:00 a 6:00 p. m., y que un asesor le escribirá '
      || 'por este mismo chat en ese horario. Despídete con amabilidad.';
end;
$$;


-- Decide qué hacer con cada mensaje entrante.
-- accion = 'lizz'   → sigue el camino normal (Lizz responde, o comprobante si es archivo)
-- accion = 'enviar' → mandar "texto" al número "para" (y si registrar, guardar el wamid)
create function public.puente_entrante(p_de text, p_tipo text, p_texto text, p_context text,
                                       p_oficina text, p_ahora timestamptz default now())
returns table (accion text, para text, texto text, plantilla boolean, registrar boolean,
               atencion_id bigint, nombre text, whatsapp text, motivo text)
language plpgsql volatile set search_path = ''
as $$
declare
  v public.atenciones%rowtype;
  v_minutos int := coalesce((select c.minutos_espera from public.puente_config c where c.id = 1), 30);
  v_activo boolean := coalesce((select c.activo from public.puente_config c where c.id = 1), false);
  v_abiertas text;
begin
  if not v_activo then
    return query select 'lizz', null::text, null::text, false, false, null::bigint, null::text, null::text, null::text;
    return;
  end if;

  -- ── Mensaje de la oficina ──
  if p_de = p_oficina then
    update public.puente_config set oficina_ultimo_mensaje_en = p_ahora where id = 1;

    -- ¿A qué cliente le responde? Por el mensaje citado ("Responder")
    select a.* into v from public.atencion_mensajes m
      join public.atenciones a on a.id = m.atencion_id
     where m.wamid = p_context and a.estado in ('activa', 'vencida');
    -- Sin cita: si hay una sola atención activa, es esa
    if v.id is null and p_context is null and (select count(*) from public.atenciones where estado = 'activa') = 1 then
      select * into v from public.atenciones where estado = 'activa';
    end if;

    if v.id is null then
      if not exists (select 1 from public.atenciones where estado = 'activa') then
        -- No hay atenciones: la oficina está hablando con Lizz (p. ej. probando)
        return query select 'lizz', null::text, null::text, false, false, null::bigint, null::text, null::text, null::text;
        return;
      end if;
      select string_agg(coalesce(a.nombre, a.telefono), ', ' order by a.creada_en) into v_abiertas
        from public.atenciones a where a.estado = 'activa';
      return query select 'enviar', p_oficina,
        'Para contestarle a un cliente, deslice su mensaje y elija Responder. Atenciones abiertas: ' || v_abiertas || '.',
        false, false, null::bigint, null::text, null::text, null::text;
      return;
    end if;

    -- Respuesta tardía a una atención vencida: se reabre si el cliente no tiene otra activa
    if v.estado = 'vencida' then
      if exists (select 1 from public.atenciones a where a.telefono = v.telefono and a.estado = 'activa') then
        return query select 'enviar', p_oficina,
          'Esa atención ya había terminado y ' || coalesce(v.nombre, v.telefono) || ' tiene otra abierta: responda sobre el mensaje más reciente.',
          false, false, null::bigint, null::text, null::text, null::text;
        return;
      end if;
      update public.atenciones set estado = 'activa', cerrada_en = null, cerrada_por = null where id = v.id;
    end if;

    if p_tipo <> 'text' then
      return query select 'enviar', p_oficina, 'Por ahora al cliente solo se le pueden enviar mensajes de texto.',
        false, false, null::bigint, null::text, null::text, null::text;
      return;
    end if;

    if lower(trim(p_texto)) in ('listo', 'listo.', 'fin', 'terminar', 'terminado') then
      update public.atenciones set estado = 'cerrada', cerrada_en = p_ahora, cerrada_por = 'oficina' where id = v.id;
      update public.solicitudes_humano set estado = 'atendida', atendida_en = p_ahora
       where telefono = v.telefono and estado = 'pendiente';
      return query
        select 'enviar', v.telefono,
               'Gracias por comunicarse con [Nombre del CEA]. Si necesita algo más, aquí estoy para ayudarle. — Lizz',
               false, false, v.id, v.nombre, null::text, null::text
        union all
        select 'enviar', p_oficina,
               'Atención con ' || coalesce(v.nombre, v.telefono) || ' terminada. Lizz retoma la conversación.',
               false, false, null::bigint, null::text, null::text, null::text;
      return;
    end if;

    update public.atenciones
       set primera_respuesta_en = coalesce(primera_respuesta_en, p_ahora), ultima_actividad_en = p_ahora
     where id = v.id;
    return query select 'enviar', v.telefono, p_texto, false, false, v.id, v.nombre, null::text, null::text;
    return;
  end if;

  -- ── Mensaje de un cliente ──
  select * into v from public.atenciones a where a.telefono = p_de and a.estado = 'activa';
  if v.id is null then
    return query select 'lizz', null::text, null::text, false, false, null::bigint, null::text, null::text, null::text;
    return;
  end if;

  -- ¿Venció? En horario: 30 min sin respuesta de la oficina. Siempre: 24 h sin respuesta,
  -- o 3 h sin actividad después de que la oficina contestó.
  if (v.primera_respuesta_en is null and privado.en_horario_oficina(p_ahora)
        and p_ahora - v.creada_en > make_interval(mins => v_minutos))
     or (v.primera_respuesta_en is null and p_ahora - v.creada_en > interval '24 hours')
     or (v.primera_respuesta_en is not null and p_ahora - v.ultima_actividad_en > interval '3 hours') then
    update public.atenciones set estado = 'vencida', cerrada_en = p_ahora, cerrada_por = 'tiempo' where id = v.id;
    return query select 'lizz', null::text, null::text, false, false, null::bigint, null::text, null::text, null::text;
    return;
  end if;

  if p_tipo <> 'text' then
    -- Fotos y documentos siguen el camino de comprobantes (que ya avisa a la oficina)
    return query select 'lizz', null::text, null::text, false, false, null::bigint, null::text, null::text, null::text;
    return;
  end if;

  update public.atenciones set ultima_actividad_en = p_ahora where id = v.id;
  return query select 'enviar', p_oficina,
    '💬 ' || coalesce(v.nombre, v.telefono) || ': ' || p_texto,
    privado.oficina_necesita_plantilla(p_ahora), true, v.id,
    privado.texto_plano(coalesce(v.nombre, 'Cliente'), 60), privado.whatsapp_legible(v.telefono),
    privado.texto_plano('escribió: ' || p_texto, 900);
end;
$$;


-- Avisos de atenciones nuevas de este número (se envían después de la respuesta de Lizz)
create function public.puente_avisos_pendientes(p_telefono text, p_ahora timestamptz default now())
returns table (atencion_id bigint, para text, texto text, plantilla boolean, nombre text, whatsapp text, motivo text)
language sql stable set search_path = ''
as $$
  select a.id, null::text,
         '🙋 Solicitud de atención de ' || coalesce(a.nombre, 'un cliente') || ' (' || privado.whatsapp_legible(a.telefono)
           || '). Motivo: ' || coalesce(a.motivo, 'sin detalle')
           || '. Para contestarle, responda a este mensaje; para terminar la atención, responda listo.',
         privado.oficina_necesita_plantilla(p_ahora),
         privado.texto_plano(coalesce(a.nombre, 'un cliente'), 60),
         privado.whatsapp_legible(a.telefono),
         privado.texto_plano(coalesce(a.motivo, 'sin detalle'), 600)
  from public.atenciones a
  where a.telefono = p_telefono and a.estado = 'activa' and a.aviso_enviado_en is null;
$$;

-- Guarda el id del mensaje enviado a la oficina (para enrutar su "Responder")
create function public.puente_registrar_envio(p_atencion_id bigint, p_wamid text, p_es_aviso boolean)
returns void
language sql volatile set search_path = ''
as $$
  insert into public.atencion_mensajes (wamid, atencion_id)
  select p_wamid, p_atencion_id where nullif(p_wamid, '') is not null
  on conflict (wamid) do nothing;
  update public.atenciones set aviso_enviado_en = coalesce(aviso_enviado_en, now())
   where id = p_atencion_id and p_es_aviso and nullif(p_wamid, '') is not null;
$$;

-- Atenciones que vencen sin respuesta (en horario, 30 min): Lizz le avisa al cliente.
create function public.puente_vencidas(p_ahora timestamptz default now())
returns table (atencion_id bigint, para text, texto text)
language sql volatile set search_path = ''
as $$
  with vencen as (
    update public.atenciones a
       set estado = 'vencida', cerrada_en = p_ahora, cerrada_por = 'tiempo'
     where a.estado = 'activa' and a.primera_respuesta_en is null
       and privado.en_horario_oficina(p_ahora)
       and p_ahora - a.creada_en > make_interval(mins => coalesce((select c.minutos_espera from public.puente_config c where c.id = 1), 30))
    returning a.id, a.telefono
  )
  select v.id, v.telefono,
         'La oficina está ocupada en este momento; un asesor le escribirá apenas pueda. Mientras tanto, con gusto le ayudo en lo que necesite. — Lizz'
  from vencen v;
$$;

revoke execute on function privado.en_horario_oficina(timestamptz), privado.puente_aplica(text),
  privado.oficina_necesita_plantilla(timestamptz), privado.texto_plano(text, int) from public, anon, authenticated;
revoke execute on function public.puente_entrante(text, text, text, text, text, timestamptz),
  public.puente_avisos_pendientes(text, timestamptz), public.puente_registrar_envio(bigint, text, boolean),
  public.puente_vencidas(timestamptz) from public, anon, authenticated;
