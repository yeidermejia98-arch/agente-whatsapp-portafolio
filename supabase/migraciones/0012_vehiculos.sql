-- Vehículos: no están fijos a un instructor. Cada turno elige su vehículo,
-- y la base no deja usar el mismo vehículo en dos turnos a la misma hora.

create table public.vehiculos (
  id          bigint generated always as identity primary key,
  placa       text not null unique check (placa ~ '^[A-Z0-9-]{5,8}$'),
  descripcion text,                                 -- p. ej. "Moto A2", "Carro B1"
  activo      boolean not null default true
);
alter table public.vehiculos enable row level security;
create policy personal_gestiona on public.vehiculos
  for all to authenticated using ((select privado.es_personal())) with check ((select privado.es_personal()));
revoke all on public.vehiculos from anon;

-- Placas del Excel de agendamiento
insert into public.vehiculos (placa, descripcion) values
  ('AAA-111', 'Moto A2'),
  ('AAA-222', null),
  ('AAA-333', null),
  ('AAA-444', null),
  ('AAA-555', null)
on conflict (placa) do nothing;

alter table public.turnos add column vehiculo_id bigint references public.vehiculos (id);
alter table public.turnos add constraint turnos_sin_cruce_vehiculo
  exclude using gist (vehiculo_id with =, tstzrange(inicio, fin) with &&)
  where (estado <> 'cancelado');

-- La placa ya no va en el instructor (0011 la había puesto ahí).
alter table public.instructores drop column vehiculo;
