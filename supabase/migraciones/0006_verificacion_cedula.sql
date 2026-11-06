-- El agente reconoce a un alumno que escribe desde un número NO registrado,
-- con su cédula + su nombre completo.
--
-- Protecciones:
--   - Máximo 3 intentos fallidos por número en 24 h, y 5 contra un mismo alumno (desde cualquier número).
--   - Nunca revela si una cédula existe: ante cualquier fallo responde lo mismo.
--   - El nombre se compara sin tildes ni mayúsculas y exige al menos 3 palabras
--     (o todas, si el nombre registrado tiene menos).
--   - La verificación vale 24 h para ese número.
--   - Si el alumno cambia su número, queda un aviso en "Atención humana" para que la oficina lo revise.

create table public.verificaciones (
  id        bigint generated always as identity primary key,
  telefono  text not null,            -- número desde el que escribe
  alumno_id bigint references public.alumnos (id) on delete cascade,  -- null si la cédula no existe
  ok        boolean not null,
  creado_en timestamptz not null default now()
);
create index verificaciones_telefono_idx on public.verificaciones (telefono, creado_en desc);
create index verificaciones_alumno_idx   on public.verificaciones (alumno_id, creado_en desc);

alter table public.verificaciones enable row level security;
create policy personal_lee on public.verificaciones
  for select to authenticated using ((select privado.es_personal()));
revoke all on public.verificaciones from anon;
revoke insert, update, delete on public.verificaciones from authenticated;

-- "José  PÉREZ-Díaz" → {jose, perez, diaz}
create function privado.palabras_nombre(texto text)
returns text[]
language sql immutable set search_path = ''
as $$
  select coalesce(array_agg(distinct p), '{}')
  from unnest(regexp_split_to_array(
         trim(regexp_replace(translate(lower(coalesce(texto, '')), 'áéíóúüñàèìòù', 'aeiouunaeiou'),
                             '[^a-z]+', ' ', 'g')), '\s+')) p
  where p <> '';
$$;

-- ¿El nombre que escribió la persona corresponde al registrado?
create function privado.nombre_coincide(escrito text, registrado text)
returns boolean
language sql immutable set search_path = ''
as $$
  with e as (select privado.palabras_nombre(escrito) as w),
       r as (select privado.palabras_nombre(registrado) as w)
  select cardinality(e.w) >= least(3, cardinality(r.w))
     and e.w <@ r.w
  from e, r;
$$;

-- Alumno con el que habla este número: por su número registrado o por una verificación de hoy.
create function privado.alumno_de_telefono(p_telefono text)
returns table (alumno_id bigint, verificado_por text)
language sql stable set search_path = ''
as $$
  select alumno_id, verificado_por from (
    select id as alumno_id, 'numero_registrado' as verificado_por, 1 as prioridad, now() as cuando
    from public.alumnos where telefono = p_telefono
    union all
    select v.alumno_id, 'cedula_y_nombre', 2, v.creado_en
    from public.verificaciones v
    where v.telefono = p_telefono and v.ok and v.creado_en > now() - interval '24 hours'
  ) x
  order by prioridad, cuando desc
  limit 1;
$$;

-- Datos de un alumno, en el formato que lee el agente.
create function privado.datos_alumno(p_alumno_id bigint, p_verificado_por text)
returns table (nombre text, categoria text, saldo_pendiente text, saldo_segun text,
               proximas_clases text, verificado_por text, numero_registrado text)
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
         ), 'no tiene clases agendadas'),
         p_verificado_por,
         -- solo los 2 últimos dígitos: suficiente para que el alumno lo reconozca
         case when a.telefono is null then 'ninguno'
              else 'terminado en ' || right(a.telefono, 2) end
  from public.alumnos a
  join public.saldos s on s.alumno_id = a.id
  where a.id = p_alumno_id;
$$;

-- Datos del alumno con el que habla este número (por su número o por una verificación de hoy).
drop function public.agente_datos_alumno(text);
create function public.agente_datos_alumno(p_telefono text)
returns table (nombre text, categoria text, saldo_pendiente text, saldo_segun text,
               proximas_clases text, verificado_por text, numero_registrado text)
language sql stable set search_path = ''
as $$
  select d.* from privado.alumno_de_telefono(p_telefono) q
  cross join lateral privado.datos_alumno(q.alumno_id, q.verificado_por) d;
$$;

-- El agente llama esto con la cédula y el nombre que escribió la persona.
create function public.agente_verificar_identidad(p_telefono text, p_cedula text, p_nombre text)
returns text
language plpgsql volatile set search_path = ''
as $$
declare
  v_alumno public.alumnos%rowtype;
  v_ok boolean;
begin
  if (select count(*) from public.verificaciones
      where telefono = p_telefono and not ok and creado_en > now() - interval '24 hours') >= 3 then
    return 'BLOQUEADO: demasiados intentos fallidos desde este número. No lo intentes de nuevo: usa pasar_a_humano.';
  end if;

  select * into v_alumno from public.alumnos
  where documento = regexp_replace(coalesce(p_cedula, ''), '[^0-9A-Za-z]', '', 'g');

  if v_alumno.id is not null and (select count(*) from public.verificaciones
      where alumno_id = v_alumno.id and not ok and creado_en > now() - interval '24 hours') >= 5 then
    return 'BLOQUEADO: no es posible verificar esta identidad por chat en este momento. Usa pasar_a_humano.';
  end if;

  v_ok := v_alumno.id is not null and privado.nombre_coincide(p_nombre, v_alumno.nombre);
  insert into public.verificaciones (telefono, alumno_id, ok) values (p_telefono, v_alumno.id, v_ok);

  if not v_ok then
    -- Mismo mensaje exista o no la cédula
    return 'NO_COINCIDE: los datos no coinciden con ningún alumno. Pide revisar la cédula y el nombre completo '
        || '(nombre y apellidos como en la matrícula). Intentos fallidos restantes hoy: '
        || greatest(0, 3 - (select count(*) from public.verificaciones
                            where telefono = p_telefono and not ok and creado_en > now() - interval '24 hours'));
  end if;

  return 'VERIFICADO. Datos del alumno: ' ||
         (select row_to_json(d)::text from privado.datos_alumno(v_alumno.id, 'cedula_y_nombre') d);
end;
$$;

-- Tras verificarse desde un número nuevo, el alumno acepta que ese sea su número para los recordatorios.
create function public.agente_actualizar_telefono(p_telefono text)
returns text
language plpgsql volatile set search_path = ''
as $$
declare
  v_alumno_id bigint;
  v_verificado_por text;
  v_anterior text;
  v_nombre text;
begin
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

revoke execute on function public.agente_datos_alumno(text)                          from public, anon, authenticated;
revoke execute on function public.agente_verificar_identidad(text, text, text)       from public, anon, authenticated;
revoke execute on function public.agente_actualizar_telefono(text)                   from public, anon, authenticated;
revoke execute on function privado.palabras_nombre(text)                             from public, anon, authenticated;
revoke execute on function privado.nombre_coincide(text, text)                       from public, anon, authenticated;
revoke execute on function privado.alumno_de_telefono(text)                          from public, anon, authenticated;
revoke execute on function privado.datos_alumno(bigint, text)                        from public, anon, authenticated;
