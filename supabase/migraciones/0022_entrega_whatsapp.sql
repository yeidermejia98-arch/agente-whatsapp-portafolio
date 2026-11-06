-- Saber si el WhatsApp de verdad llegó. Que Meta acepte un mensaje (mensajes.ok) no significa
-- que se entregó: si el número no tiene WhatsApp, Meta avisa después por el webhook con el
-- estado "failed" (p. ej., error 131026). Antes esos avisos se descartaban y el panel decía
-- "Entregado". Ahora se guardan y el panel muestra qué alumnos no reciben WhatsApp.
-- Además, un número corregido a mano ya no lo pisa la sincronización con NissiX.

alter table public.mensajes
  add column entrega text check (entrega in ('enviado', 'entregado', 'leido', 'fallido')),
  add column entrega_error text,
  add column entrega_en timestamptz;

alter table public.alumnos add column telefono_manual boolean not null default false;
alter table public.alumnos add column whatsapp_fallo text;
comment on column public.alumnos.whatsapp_fallo is
  'Último error de entrega de WhatsApp (p. ej., 131026: el número no tiene WhatsApp). Se borra al cambiar el número o cuando un mensaje llega.';
comment on column public.alumnos.telefono_manual is
  'El número lo corrigió la oficina o el alumno (por Lizz): la importación de NissiX/Excel no lo cambia.';

-- Lo llama n8n con cada estado que manda WhatsApp (sent, delivered, read, failed).
-- No retrocede: un mensaje leído no vuelve a "entregado"; uno fallido queda fallido.
create function public.registrar_estado_whatsapp(p_wa_message_id text, p_estado text, p_error text default null)
returns void
language sql volatile set search_path = ''
as $$
  with actualizado as (
  update public.mensajes m
     set entrega       = e.estado,
         entrega_error = case when e.estado = 'fallido' then left(nullif(p_error, ''), 300) else m.entrega_error end,
         entrega_en    = now()
    from (select case p_estado when 'sent' then 'enviado' when 'delivered' then 'entregado'
                               when 'read' then 'leido' when 'failed' then 'fallido' end as estado) e
   where m.wa_message_id = p_wa_message_id
     and e.estado is not null
     and m.entrega is distinct from 'fallido'
     and array_position(array['enviado', 'entregado', 'leido', 'fallido'], e.estado)
         >= coalesce(array_position(array['enviado', 'entregado', 'leido', 'fallido'], m.entrega), 0)
  returning m.alumno_id, m.entrega, m.entrega_error
  )
  -- En la ficha del alumno: falló → se marca; entregado o leído → se limpia
  update public.alumnos a
     set whatsapp_fallo = case when u.entrega = 'fallido' then coalesce(u.entrega_error, 'No entregado') end
    from actualizado u
   where a.id = u.alumno_id and u.entrega in ('entregado', 'leido', 'fallido');
$$;
revoke execute on function public.registrar_estado_whatsapp(text, text, text) from public, anon, authenticated;

-- Importación (Excel o NissiX): igual que en 0003, salvo el teléfono corregido a mano.
create or replace function public.importar_alumnos(filas jsonb, autorizan boolean)
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
      -- no borra un teléfono ya guardado, y no cambia uno corregido a mano
      telefono             = case when a.telefono_manual then a.telefono
                                  else coalesce(excluded.telefono, a.telefono) end,
      whatsapp_fallo       = case when a.telefono_manual or coalesce(excluded.telefono, a.telefono) = a.telefono
                                  then a.whatsapp_fallo end,   -- número nuevo: se vuelve a intentar
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

-- Cuando el alumno cambia su número hablando con Lizz, también queda protegido (igual que en 0020).
create or replace function public.agente_actualizar_telefono(p_telefono text)
returns text
language plpgsql volatile set search_path = ''
as $$
declare
  v_alumno_id bigint;
  v_verificado_por text;
  v_anterior text;
  v_nombre text;
begin
  if p_telefono !~ '^[1-9][0-9]{7,14}$' then
    return 'NO_PERMITIDO: WhatsApp no nos muestra el número de esta persona (usa nombre de usuario). '
        || 'Pídele que escriba su número de celular y usa pasar_a_humano para que la oficina lo actualice.';
  end if;

  select alumno_id, verificado_por into v_alumno_id, v_verificado_por
  from privado.alumno_de_telefono(p_telefono);

  if v_alumno_id is null or v_verificado_por <> 'cedula_y_nombre' then
    return 'NO_PERMITIDO: la persona debe verificarse primero con cédula y nombre desde este número.';
  end if;
  if exists (select 1 from public.alumnos where telefono = p_telefono and id <> v_alumno_id) then
    return 'NO_PERMITIDO: este número ya está registrado a nombre de otro alumno. Usa pasar_a_humano.';
  end if;

  select telefono, nombre into v_anterior, v_nombre from public.alumnos where id = v_alumno_id;
  update public.alumnos set telefono = p_telefono, telefono_manual = true, whatsapp_fallo = null where id = v_alumno_id;

  insert into public.solicitudes_humano (telefono, nombre, alumno_id, motivo, resumen)
  values (p_telefono, v_nombre, v_alumno_id, 'Cambio de número (revisar)',
          'Se verificó con cédula y nombre y cambió su WhatsApp de '
          || coalesce('+' || v_anterior, 'ninguno') || ' a +' || p_telefono
          || '. Si no fue el alumno, corrígelo en la base y contáctalo.');

  return 'ACTUALIZADO: desde ahora los recordatorios llegarán a este número.';
end;
$$;
revoke execute on function public.agente_actualizar_telefono(text) from public, anon, authenticated;
