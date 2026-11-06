-- Lizz responde por la agenda práctica igual que los recordatorios: por día, con el
-- horario completo (bloques seguidos unidos), la categoría, el tipo, el instructor y el
-- vehículo. Antes recibía solo las 5 próximas horas de inicio, sin categoría ni vehículo.
-- Muestra los próximos 7 días con clase. Ejemplo de lo que recibe Lizz:
--   "lunes 5 de octubre: 7:00 a. m. a 12:00 p. m. (práctica C1, instructor INSTRUCTOR 1,
--    vehículo AAA-111); martes 6 de octubre: …"

create or replace function privado.datos_alumno(p_alumno_id bigint, p_verificado_por text)
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
           with turnos as (
             select t.inicio, (t.inicio at time zone 'America/Bogota')::date as dia,
                    case t.tipo when 'practica' then 'práctica' when 'teorica' then 'teórica'
                                when 'validacion' then 'validación' else t.tipo end
                      || coalesce(' ' || t.categoria, '') as que,
                    coalesce(i.nombre, 'por asignar') as instructor,
                    v.placa
             from public.turnos t
             left join public.instructores i on i.id = t.instructor_id
             left join public.vehiculos v on v.id = t.vehiculo_id
             where t.alumno_id = a.id and t.estado = 'agendado' and t.inicio > now()
           ),
           dias as (
             select dia, min(inicio) as primero,
                    string_agg(distinct que, ' y ') as que,
                    string_agg(distinct instructor, ' y ') as instructor,
                    string_agg(distinct placa, ' y ') as placas
             from turnos group by dia order by dia limit 7
           )
           select string_agg(
                    public.fecha_larga(d.primero) || ': ' || privado.horario_del_dia(a.id, d.dia)
                    || ' (' || d.que || ', instructor ' || d.instructor
                    || coalesce(', vehículo ' || d.placas, '') || ')',
                    '; ' order by d.dia)
           from dias d
         ), 'no tiene clases agendadas'),
         p_verificado_por,
         -- solo los 2 últimos dígitos: suficiente para que el alumno lo reconozca
         case when a.telefono is null then 'ninguno'
              else 'terminado en ' || right(a.telefono, 2) end
  from public.alumnos a
  join public.saldos s on s.alumno_id = a.id
  where a.id = p_alumno_id;
$$;
