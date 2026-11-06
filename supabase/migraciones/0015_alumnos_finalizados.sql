-- Alumnos que ya terminaron su proceso: se marcan como finalizados (no se borran,
-- para conservar su historial de turnos, pagos y mensajes). El panel los oculta de
-- la agenda y de la lista; se pueden ver con un filtro y reactivar.
-- La sincronización con NissiX no toca esta marca.

alter table public.alumnos add column finalizado_en timestamptz;

create index alumnos_activos_idx on public.alumnos (nombre) where finalizado_en is null;
