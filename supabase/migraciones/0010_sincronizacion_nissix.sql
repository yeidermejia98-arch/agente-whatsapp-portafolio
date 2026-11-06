-- Sincronización semanal con NissiX (sistema de facturación del CEA).
--
-- Cada domingo n8n consulta en NissiX las facturas de los últimos 90 días (procesos vigentes),
-- lee el detalle de cada una (teléfono, categoría, saldo) y llama a importar_alumnos().
-- Aquí queda el registro de cada corrida para verlo en el panel (pestaña Importar).

create table public.sincronizaciones (
  id           bigint generated always as identity primary key,
  origen       text not null default 'nissix',
  ok           boolean not null,
  facturas     int,                    -- facturas leídas en NissiX
  creados      int,                    -- alumnos nuevos
  actualizados int,                    -- alumnos que ya existían (saldo, categoría…)
  sin_telefono int,                    -- quedaron sin WhatsApp: no reciben recordatorios
  detalle      text,                   -- error o avisos (p. ej. facturas con teléfono mal escrito)
  creado_en    timestamptz not null default now()
);
create index sincronizaciones_fecha_idx on public.sincronizaciones (creado_en desc);

alter table public.sincronizaciones enable row level security;
create policy personal_lee on public.sincronizaciones
  for select to authenticated using ((select privado.es_personal()));
revoke all on public.sincronizaciones from anon;
