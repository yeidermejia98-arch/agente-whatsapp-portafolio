-- WhatsApp ya permite nombres de usuario: si la persona oculta su número y nunca nos ha escrito
-- (o no le hemos escrito en 30 días), Meta no envía el teléfono sino un identificador del usuario
-- (BSUID, p. ej. "CO.1108258192140131"). El agente lo usa en lugar del teléfono: estas funciones lo
-- comparan como texto y funcionan igual. Solo cambian las dos que suponían un número.

-- En los avisos a la oficina: sin número no hay wa.me; se indica que respondan por el puente.
create or replace function privado.whatsapp_legible(p_telefono text)
returns text
language sql immutable set search_path = ''
as $$
  select case
    when p_telefono !~ '^[0-9]+$' then 'usuario de WhatsApp sin número visible (responda por aquí)'
    when p_telefono ~ '^57[0-9]{10}$'
      then '+57 ' || substr(p_telefono, 3, 3) || ' ' || substr(p_telefono, 6, 3) || ' ' || substr(p_telefono, 9)
           || ' · wa.me/' || p_telefono
    else '+' || p_telefono || ' · wa.me/' || p_telefono end;
$$;
revoke execute on function privado.whatsapp_legible(text) from public, anon, authenticated;

-- El teléfono del alumno debe ser un número: con un identificador de usuario no se puede cambiar.
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
  update public.alumnos set telefono = p_telefono where id = v_alumno_id;

  -- Aviso para que la oficina lo revise
  insert into public.solicitudes_humano (telefono, nombre, alumno_id, motivo, resumen)
  values (p_telefono, v_nombre, v_alumno_id, 'Cambio de número (revisar)',
          'Se verificó con cédula y nombre y cambió su WhatsApp de '
          || coalesce('+' || v_anterior, 'ninguno') || ' a +' || p_telefono
          || '. Si no fue el alumno, corrígelo en la base y contáctalo.');

  return 'ACTUALIZADO: desde ahora los recordatorios llegarán a este número.';
end;
$$;
revoke execute on function public.agente_actualizar_telefono(text) from public, anon, authenticated;
