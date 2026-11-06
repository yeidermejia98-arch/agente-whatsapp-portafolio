# 0001 — Tecnologías del agente de WhatsApp para el CEA

- **Fecha:** 2026-09-25
- **Estado:** aceptada

## Contexto

Un CEA (escuela de conducción) recibe por WhatsApp las mismas preguntas todos los días (precios, requisitos, horarios), pierde clientes que escriben fuera de horario y tiene alumnos que faltan a clases agendadas. Se quiere un agente de IA que atienda por WhatsApp las 24 horas, agende clases, envíe recordatorios y pase a una persona lo que no sepa resolver.

## Decisión

| Capa | Tecnología |
|---|---|
| Canal | WhatsApp Cloud API (oficial de Meta) — único canal |
| Orquestador | n8n Community Edition en Docker |
| Base de datos interna de n8n | PostgreSQL en Docker |
| Modelo de IA | Claude Haiku 4.5 (`claude-haiku-4-5`) vía API de Anthropic |
| Datos del negocio | Supabase (PostgreSQL) |
| Memoria del chat | Postgres Chat Memory (en Supabase) |
| Túnel HTTPS (desarrollo) | ngrok con dominio fijo gratuito |
| Versiones | Git + GitHub (flujos de n8n exportados en `flujos/`) |
| Producción | VPS pequeño con Docker (después de la prueba piloto) |

Alcance de la versión 1: preguntas frecuentes, agendamiento, paso a humano **y** recordatorios de clase.

## Por qué

- **WhatsApp Cloud API y no una API no oficial** (Evolution API, WAHA): las no oficiales violan los términos de WhatsApp y pueden hacer que bloqueen el número del negocio.
- **n8n:** nodos nativos de WhatsApp y de agente de IA; se ve el flujo completo sin escribir un backend desde cero.
- **Claude Haiku 4.5:** rápido y barato, y sigue bien las reglas y el uso de herramientas; importante para no inventar precios ni requisitos.
- **Supabase en vez de Google Sheets:** una restricción en la base de datos impide agendar dos clases a la misma hora con el mismo instructor; es además el stack de [Nombre del CEA] y del curso (semanas 15–18).

## Consecuencias

- **Regla de las 24 h de WhatsApp:** responder a un cliente dentro de las 24 h después de su último mensaje es gratis y libre. Los **recordatorios** los inicia el CEA, así que exigen una **plantilla aprobada por Meta** (categoría *utility*) y **Meta los cobra** por mensaje.
- **Durante el desarrollo** se usa el número de prueba de Meta (máx. 5 destinatarios registrados). Para usar el número real hace falta verificar el negocio en Meta.
- **n8n en el PC** solo funciona mientras el PC y ngrok estén encendidos; para la prueba piloto real se debe pasar a un VPS.
- **Costos:** consumo de Claude (pocos dólares al mes en el prototipo) + plantillas de recordatorio. Lo demás es gratis en el nivel usado.
- **Datos personales:** se guardan nombre y teléfono de alumnos → aplicar la Ley 1581 de 2012 (aviso de privacidad y autorización de tratamiento de datos en el primer mensaje).
