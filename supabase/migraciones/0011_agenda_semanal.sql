-- Agenda semanal por instructor (vista tipo calendario en el panel, como el Excel
-- "AGENDAMIENTO CEA AA": una hoja por instructor y vehículo, días en columnas, bloques en filas).

-- Vehículo con el que el instructor da la práctica (placa), para mostrarlo en la agenda.
alter table public.instructores add column vehiculo text;

-- En el Excel también se agenda "Validación".
alter table public.turnos drop constraint turnos_tipo_check;
alter table public.turnos add constraint turnos_tipo_check
  check (tipo in ('practica', 'teorica', 'examen', 'validacion'));

-- Categoría del turno: un alumno puede estar haciendo varias (p. ej. "C1 + A2") y cada
-- práctica corresponde a una sola.
alter table public.turnos add column categoria text check (categoria ~ '^[ABC][1-3]$');

-- Instructores del Excel (el panel permite desactivar los que ya no trabajen).
update public.instructores set vehiculo = 'AAA-111' where nombre = 'INSTRUCTOR 1';
insert into public.instructores (nombre, vehiculo)
select v.nombre, v.vehiculo
from (values ('INSTRUCTOR 2', 'AAA-222'),
             ('INSTRUCTOR 3', 'AAA-333'),
             ('INSTRUCTOR 4', 'AAA-444'),
             ('INSTRUCTOR 5', 'AAA-555')) as v (nombre, vehiculo)
where not exists (select 1 from public.instructores i where i.nombre = v.nombre);
