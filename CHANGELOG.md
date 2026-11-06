# Historial de versiones

Cambios relevantes del agente de WhatsApp del [Nombre del CEA].
El formato sigue [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y el proyecto usa
[versionado semántico](https://semver.org/lang/es/): `MAYOR.MENOR.PARCHE`.

- **MAYOR:** cambios que obligan a reinstalar o migrar el servidor.
- **MENOR:** funciones nuevas (panel, Lizz, recordatorios, integraciones).
- **PARCHE:** correcciones.

## [Sin publicar]

## [1.1.0] — 2026-10-12

### Agregado
- Botón **Enviar ahora** en la Agenda: en horario de descanso (9 p. m.–6 a. m.) muestra los avisos que esperan y los envía de inmediato.

### Corregido
- El panel decía "Entregado" aunque WhatsApp no entregara el mensaje (número sin WhatsApp, error 131026). Ahora Lizz guarda los avisos de entrega: *Mensajes enviados* muestra Enviado, Entregado, Leído o **No entregado**, y *Alumnos y saldos* marca **⚠ No recibe WhatsApp** con un filtro **Sin WhatsApp** para corregir el número (acepta números de otro país con indicativo, p. ej. +34).
- Un número corregido a mano (en el panel o con Lizz) ya no lo cambia la sincronización con NissiX.

## [1.0.0] — 2026-10-09

Primera versión publicada en GitHub. Corresponde a lo que está en producción.

### Agregado
- **Panel web** con el logo de [Nombre del CEA]: agenda semanal por instructor (categoría y vehículo por turno, series de 1–3 h), alumnos con filtros y finalizados, pagos, matrículas, atención humana, información de Lizz, mensajes enviados, instructores y vehículos.
- **Lizz** (n8n + Claude Haiku 4.5): responde con la información del panel, saldo y agenda del alumno, matrículas, comprobantes, verificación por cédula y memoria de la conversación.
- **Puente de atención humana:** la oficina conversa con el cliente desde su propio WhatsApp.
- **Recordatorios por WhatsApp:** confirmación por jornada al agendar y aviso 3 horas antes; saldo cada 8 días y los 15 y 30.
- **Sincronización con NissiX:** domingos 6 p. m., 11:30 a. m. de los días de cobro y botón *Actualizar saldos desde NissiX* en el panel.
- **Servidor 24/7** en Hetzner (Docker: PostgreSQL, n8n, Caddy, ngrok).
- Flujo de trabajo GitHub Flow: plantilla de PR, GitHub Actions (*Verificar*) y Dependabot.

### Corregido
- Lizz responde a quien usa nombre de usuario de WhatsApp y oculta su número.

### Seguridad
- Datos reales de alumnos reemplazados por datos inventados en pruebas, demo y todo el historial de git.
