-- Por qué se sincronizó con NissiX: "domingo", "antes del cobro" (11:30 a. m. de los días
-- en que sale el recordatorio de saldo), "botón del panel" o "prueba manual".
alter table public.sincronizaciones add column motivo text;
