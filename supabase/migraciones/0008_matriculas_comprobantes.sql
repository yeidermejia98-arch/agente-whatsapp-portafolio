-- Matrículas por WhatsApp y comprobantes de pago.
--
-- 1. Lizz registra la matrícula (nombre, cédula, categoría, valor y cuota) en cuanto la persona da sus datos.
-- 2. Cuando la persona envía el comprobante (foto o PDF), n8n lo reenvía a la oficina con esos datos.
-- 3. La oficina verifica la transferencia y, en el panel, confirma el pago: se crea el alumno
--    (con su WhatsApp, para los recordatorios) y se registra el pago de la cuota inicial.

create table public.matriculas (
  id                      bigint generated always as identity primary key,
  telefono                text not null,                 -- WhatsApp desde el que se inscribió
  nombre                  text not null,
  cedula                  text not null,
  categoria               text not null,                 -- A2, B1, C1, A2 + B1…
  valor_total             numeric(12, 0) check (valor_total >= 0),
  cuota_inicial           numeric(12, 0) check (cuota_inicial >= 0),
  estado                  text not null default 'pendiente_pago'
                            check (estado in ('pendiente_pago', 'comprobante_recibido', 'confirmada', 'rechazada')),
  comprobante_tipo        text check (comprobante_tipo in ('image', 'document')),
  comprobante_recibido_en timestamptz,
  alumno_id               bigint references public.alumnos (id) on delete set null,
  creado_en               timestamptz not null default now(),
  revisada_en             timestamptz
);
create index matriculas_telefono_idx on public.matriculas (telefono, creado_en desc);
create index matriculas_estado_idx   on public.matriculas (estado, creado_en desc);

alter table public.matriculas enable row level security;
create policy personal_lee on public.matriculas
  for select to authenticated using ((select privado.es_personal()));
create policy personal_revisa on public.matriculas
  for update to authenticated using ((select privado.es_personal())) with check ((select privado.es_personal()));
revoke all on public.matriculas from anon;


-- Lizz registra (o corrige) la matrícula abierta de este número.
create function public.agente_registrar_matricula(p_telefono text, p_nombre text, p_cedula text,
                                                  p_categoria text, p_valor_total numeric, p_cuota numeric)
returns text
language plpgsql volatile set search_path = ''
as $$
declare
  v_id bigint;
  v_cedula text := regexp_replace(coalesce(p_cedula, ''), '[^0-9A-Za-z]', '', 'g');
begin
  if v_cedula = '' or nullif(trim(p_nombre), '') is null then
    return 'FALTAN_DATOS: pide el nombre completo y el número de cédula.';
  end if;

  update public.matriculas
     set nombre = trim(p_nombre), cedula = v_cedula, categoria = trim(p_categoria),
         valor_total = p_valor_total, cuota_inicial = p_cuota
   where telefono = p_telefono and estado in ('pendiente_pago', 'comprobante_recibido')
  returning id into v_id;

  if v_id is null then
    insert into public.matriculas (telefono, nombre, cedula, categoria, valor_total, cuota_inicial)
    values (p_telefono, trim(p_nombre), v_cedula, trim(p_categoria), p_valor_total, p_cuota)
    returning id into v_id;
  end if;

  return 'MATRICULA_REGISTRADA #' || v_id || '. Pídele que envíe la foto o el PDF del comprobante por este mismo chat.';
end;
$$;

-- n8n llama esto al recibir una foto o un PDF: marca la matrícula y devuelve los datos para avisar a la oficina.
create function public.agente_comprobante_recibido(p_telefono text, p_tipo text)
returns table (matricula_id bigint, nombre text, cedula text, categoria text, cuota text, whatsapp text, registrada boolean)
language plpgsql volatile set search_path = ''
as $$
declare
  m public.matriculas%rowtype;
begin
  update public.matriculas
     set estado = 'comprobante_recibido', comprobante_tipo = p_tipo, comprobante_recibido_en = now()
   where id = (select id from public.matriculas
               where telefono = p_telefono and estado in ('pendiente_pago', 'comprobante_recibido')
               order by creado_en desc limit 1)
  returning * into m;

  if m.id is null then
    -- Envió un archivo sin haber dado sus datos: igual se reenvía, marcado para que la oficina lo identifique.
    perform public.agente_pedir_humano(p_telefono, '', 'Comprobante sin matrícula',
      'Envió un archivo (posible comprobante) sin haber registrado nombre y cédula con Lizz.');
    return query select null::bigint, 'Sin registrar'::text, 'Sin registrar'::text, 'Sin registrar'::text,
                        'Sin registrar'::text, '+' || p_telefono, false;
    return;
  end if;

  return query select m.id, m.nombre, m.cedula, m.categoria,
                      coalesce(public.formato_pesos(m.cuota_inicial), 'Sin dato'), '+' || p_telefono, true;
end;
$$;

-- La oficina confirma el pago desde el panel: crea (o actualiza) el alumno y registra la cuota.
create function public.confirmar_matricula(p_matricula_id bigint)
returns text
language plpgsql volatile security invoker set search_path = ''
as $$
declare
  m public.matriculas%rowtype;
  v_alumno bigint;
begin
  select * into m from public.matriculas where id = p_matricula_id for update;
  if m.id is null then raise exception 'La matrícula no existe o no tienes permiso para verla.'; end if;
  if m.estado = 'confirmada' then return 'Esta matrícula ya estaba confirmada.'; end if;

  insert into public.alumnos as a (documento, nombre, telefono, categoria, valor_curso, autoriza_datos)
  values (m.cedula, m.nombre, m.telefono, m.categoria, coalesce(m.valor_total, 0), true)
  on conflict (documento) do update set
    nombre = excluded.nombre,
    categoria = excluded.categoria,
    valor_curso = excluded.valor_curso,
    telefono = coalesce(a.telefono, excluded.telefono),
    autoriza_datos = true
  returning id into v_alumno;

  if coalesce(m.cuota_inicial, 0) > 0 then
    insert into public.pagos (alumno_id, valor, medio, nota)
    values (v_alumno, m.cuota_inicial, 'Transferencia', 'Cuota inicial (matrícula por WhatsApp #' || m.id || ')');
  end if;

  update public.matriculas set estado = 'confirmada', alumno_id = v_alumno, revisada_en = now()
   where id = m.id;

  return 'Pago confirmado: ' || m.nombre || ' ya es alumno del CEA.';
end;
$$;

revoke execute on function public.agente_registrar_matricula(text, text, text, text, numeric, numeric) from public, anon, authenticated;
revoke execute on function public.agente_comprobante_recibido(text, text)                               from public, anon, authenticated;
revoke execute on function public.confirmar_matricula(bigint)                                           from public, anon;
grant  execute on function public.confirmar_matricula(bigint)                                           to authenticated;
