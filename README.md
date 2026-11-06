# Agente de WhatsApp para una escuela de conducción

Sistema para una escuela de conducción: un panel web para la secretaría, recordatorios automáticos por WhatsApp y un agente de IA que responde a los alumnos.

Este repositorio es una versión de portafolio: no incluye datos, números de teléfono, claves ni configuración de servidor de la institución para la que se construyó. Los valores de ejemplo están marcados como `300 000 0000`, `TU-PROYECTO` o `TU_CLAVE`.

## Qué hace

1. **Panel web** (`panel/`): la secretaría agenda turnos, registra alumnos y pagos, y ve los saldos.
   - **Agenda semanal** por instructor: clic en una hora libre para agendar, con alumno, categoría, vehículo, duración (1–3 h), tipo de clase y repetición en varios días.
   - La base de datos **impide cruces** de instructor, alumno o vehículo.
   - **Alumnos**: buscador, filtros y finalización (los finalizados salen de la agenda; no se borra nada).
   - **Sincronización** de alumnos, teléfonos y saldos desde un sistema de gestión externo, con n8n.
2. **Recordatorios automáticos por WhatsApp** (n8n):
   - **Turnos:** una confirmación al agendar y un recordatorio antes del primer turno del día. No se envía en horario nocturno.
   - **Saldos:** un recordatorio periódico a quien tenga saldo pendiente.
3. **Agente de IA por WhatsApp** (n8n + Claude Haiku), flujo `flujos/agente-whatsapp.json`:
   - responde preguntas generales **solo** con la información que la secretaría carga en el panel;
   - reconoce al alumno por su número y le informa su saldo y su agenda, sin mostrar datos de otras personas;
   - atiende a personas nuevas y reenvía comprobantes a la oficina;
   - **pasa a un humano** cuando hace falta: la oficina conversa con el alumno desde su propio WhatsApp.

Tecnologías y decisiones: [`docs/decisiones/0001-tecnologias.md`](docs/decisiones/0001-tecnologias.md).

## Cómo funciona

```
 Secretaría                         Supabase (base de datos)                  n8n (en Docker)                    WhatsApp
┌──────────────┐  agenda turnos   ┌──────────────────────────┐   programado  ┌───────────────────────┐  plantilla  ┌─────────┐
│ Panel web    │ ───────────────▶ │ alumnos, turnos, pagos   │ ◀──────────── │ Recordatorio de turnos │ ──────────▶ │ Alumno  │
│ (panel/)     │  registra pagos  │ saldos (vista)           │               │ Recordatorio de saldos │             │         │
└──────────────┘                  │ mensajes (registro)      │ ◀──────────── └───────────────────────┘             └─────────┘
                                  └──────────────────────────┘   guarda si se envió o falló
```

- Solo reciben mensajes los alumnos que **autorizaron el tratamiento de datos** (Ley 1581 de 2012).
- Cada envío queda registrado y el panel lo muestra.

## Estructura

| Carpeta | Contenido |
|---|---|
| `panel/` | Panel web (HTML, CSS y JavaScript, sin compilar) |
| `supabase/migraciones/` | Tablas, reglas de seguridad y funciones; se pegan en el SQL Editor de Supabase |
| `flujos/` | Flujos de n8n para importar |
| `herramientas/` | Scripts que adaptan los flujos de n8n |
| `docs/` | Decisiones y demostración visual del agente |

## Puesta en marcha

### 1. Supabase
1. Crea un proyecto en supabase.com.
2. **SQL Editor**: pega `supabase/migraciones/0001_turnos_saldos_recordatorios.sql` y ejecútalo. Después ejecuta las migraciones siguientes en orden.
3. **Authentication → Users → Add user**: crea el usuario de la secretaría (correo y contraseña).
4. **Authentication → Sign In / Providers**: desactiva **Allow new users to sign up**.
5. En el SQL Editor, autoriza a ese usuario en el panel:
   ```sql
   insert into public.personal (user_id, nombre)
   select id, 'Secretaría' from auth.users where email = 'CORREO-DE-LA-SECRETARIA';
   ```

### 2. Panel
1. Copia `panel/config.ejemplo.js` como `panel/config.js` y pega la URL y la clave publicable del proyecto (**Project Settings → API**).
2. Sírvelo con un servidor estático, por ejemplo `npx http-server panel -p 8090`, y entra a http://localhost:8090.
3. Crea los instructores, luego los alumnos, y agenda turnos.

### 3. WhatsApp (Meta)
1. En developers.facebook.com crea una app de tipo **Business** y agrega **WhatsApp**.
2. Registra un número de prueba como destinatario.
3. Copia el identificador del número de teléfono y genera un token de acceso permanente (el temporal dura 24 horas).
4. Crea las plantillas de mensaje que usan los recordatorios y espera su aprobación.

### 4. n8n
1. Levanta n8n con Docker (imagen oficial `docker.n8n.io/n8nio/n8n`) y define tu dominio público en la variable `WEBHOOK_URL`.
2. Crea las credenciales:
   - **Postgres**: datos de Supabase (**Connect → Session pooler**), con SSL activado.
   - **Header Auth** (*WhatsApp Cloud API*): `Authorization: Bearer TU_TOKEN`.
3. Importa los flujos de `flujos/` (**Workflows → Import from file**), asigna las credenciales en cada nodo y prueba con **Execute workflow**.
4. Actívalos con el interruptor **Active**.

Los valores de `TU-PROYECTO`, `TU_CLAVE` y los números de teléfono de ejemplo deben reemplazarse por los propios antes de usar los flujos.

## Integración continua

`.github/workflows/verificar.yml` revisa en cada cambio la sintaxis de JavaScript del panel y de las herramientas, que los flujos de n8n sean JSON válido con nodos, y que no se cuelen claves ni archivos privados.
