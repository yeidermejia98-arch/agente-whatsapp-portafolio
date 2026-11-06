-- El aviso de comprobante a la oficina muestra el WhatsApp del alumno legible y con enlace directo:
-- "+57 300 000 0000 · wa.me/573000000000"

-- 573000000000 → "+57 300 000 0000 · wa.me/573000000000"
create function privado.whatsapp_legible(p_telefono text)
returns text
language sql immutable set search_path = ''
as $$
  select case when p_telefono ~ '^57[0-9]{10}$'
              then '+57 ' || substr(p_telefono, 3, 3) || ' ' || substr(p_telefono, 6, 3) || ' ' || substr(p_telefono, 9)
              else '+' || p_telefono end
         || ' · wa.me/' || p_telefono;
$$;
revoke execute on function privado.whatsapp_legible(text) from public, anon, authenticated;

create or replace function public.agente_comprobante_recibido(p_telefono text, p_tipo text)
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
    perform public.agente_pedir_humano(p_telefono, '', 'Comprobante sin matrícula',
      'Envió un archivo (posible comprobante) sin haber registrado nombre y cédula con Lizz.');
    return query select null::bigint, 'Sin registrar'::text, 'Sin registrar'::text, 'Sin registrar'::text,
                        'Sin registrar'::text, privado.whatsapp_legible(p_telefono), false;
    return;
  end if;

  return query select m.id, m.nombre, m.cedula, m.categoria,
                      coalesce(public.formato_pesos(m.cuota_inicial), 'Sin dato'), privado.whatsapp_legible(p_telefono), true;
end;
$$;
revoke execute on function public.agente_comprobante_recibido(text, text) from public, anon, authenticated;
