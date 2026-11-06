-- Si una persona ya tiene una solicitud pendiente, lo nuevo se AGREGA en vez de reemplazarla.
-- Antes: una foto enviada después de registrar la matrícula borraba la cédula y la categoría.

create or replace function public.agente_pedir_humano(p_telefono text, p_nombre_perfil text,
                                                      p_motivo text, p_resumen text)
returns text
language plpgsql volatile set search_path = ''
as $$
declare
  v_alumno public.alumnos%rowtype;
  v_id bigint;
  v_hora text := to_char(now() at time zone 'America/Bogota', 'DD/MM HH12:MI am');
begin
  select * into v_alumno from public.alumnos where telefono = p_telefono;

  update public.solicitudes_humano s
     set motivo    = case when position(p_motivo in s.motivo) > 0 then s.motivo
                          else s.motivo || ' + ' || p_motivo end,
         resumen   = concat_ws(E'\n', s.resumen, '[' || v_hora || '] ' || p_resumen),
         creado_en = now()
   where s.telefono = p_telefono and s.estado = 'pendiente'
  returning s.id into v_id;

  if v_id is null then
    insert into public.solicitudes_humano (telefono, nombre, alumno_id, motivo, resumen)
    values (p_telefono, coalesce(v_alumno.nombre, nullif(trim(p_nombre_perfil), '')), v_alumno.id,
            p_motivo, '[' || v_hora || '] ' || p_resumen)
    returning id into v_id;
  end if;

  return 'Solicitud #' || v_id || ' registrada. La oficina del CEA contactará a la persona.';
end;
$$;

revoke execute on function public.agente_pedir_humano(text, text, text, text) from public, anon, authenticated;
