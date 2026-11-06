// Agrega al flujo de avisos de turnos el botón "Enviar ahora" del panel: un webhook que verifica
// al usuario del panel y envía los avisos pendientes aunque sea horario de descanso (9 p. m.–6 a. m.).
// Uso: node agregar-boton-avisos.cjs flujo.json
const fs = require('fs');
const path = require('path');
const archivo = process.argv[2];
const crudo = JSON.parse(fs.readFileSync(archivo, 'utf8'));
const w = Array.isArray(crudo) ? crudo[0] : crudo;
if (w.nodes.some(n => n.name === 'Botón Enviar ahora')) { console.log('Ya tenía el botón'); process.exit(0); }

const SUPABASE = 'https://TU-PROYECTO.supabase.co';
const LLAVE = (fs.readFileSync(path.join(__dirname, '../panel/config.js'), 'utf8')
  .match(/sb_publishable_[A-Za-z0-9_-]+/) || [])[0];
if (!LLAVE) throw new Error('No encontré la publishable key en panel/config.js');
const pendientes = w.nodes.find(n => n.name === 'Avisos pendientes');
const pg = pendientes.credentials;
const responder = (codigo, cuerpo) => ({ respondWith: 'json', responseBody: JSON.stringify(cuerpo), options: { responseCode: codigo } });

// El mismo nodo sirve a los dos caminos; solo el botón se salta el descanso
pendientes.parameters.query = 'select * from public.avisos_turnos_pendientes(now(), $1::boolean);';
pendientes.parameters.options = { queryReplacement: "={{ [ $('Botón Enviar ahora').isExecuted ] }}" };

for (const n of w.nodes) if (n.name !== 'Cada 5 minutos') n.position = [n.position[0] + 660, n.position[1]];
w.nodes.push(
  { id: 'boton-avisos', name: 'Botón Enviar ahora', type: 'n8n-nodes-base.webhook', typeVersion: 2, position: [0, 220], webhookId: 'avisos-ahora',
    parameters: { httpMethod: 'POST', path: 'avisos-ahora', responseMode: 'responseNode', options: {} } },
  { id: 'avisos-quien', name: '¿Quién lo pulsó?', type: 'n8n-nodes-base.httpRequest', typeVersion: 4.2, position: [220, 220],
    parameters: { url: SUPABASE + '/auth/v1/user', sendHeaders: true, headerParameters: { parameters: [
      { name: 'apikey', value: LLAVE },
      { name: 'Authorization', value: "={{ $json.headers.authorization || '' }}" }] },
      options: { response: { response: { fullResponse: true, neverError: true } }, timeout: 15000 } } },
  { id: 'avisos-personal', name: '¿Es personal del CEA?', type: 'n8n-nodes-base.postgres', typeVersion: 2.5, position: [440, 220], credentials: pg,
    parameters: { operation: 'executeQuery',
      query: "select exists(select 1 from public.personal where user_id = nullif($1, '')::uuid) as autorizado;",
      options: { queryReplacement: "={{ [ $json.statusCode === 200 && $json.body && $json.body.id ? $json.body.id : '' ] }}" } } },
  { id: 'avisos-autorizado', name: '¿Autorizado?', type: 'n8n-nodes-base.if', typeVersion: 2.2, position: [660, 220],
    parameters: { conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
      conditions: [{ id: 'a1', leftValue: '={{ $json.autorizado }}', rightValue: '', operator: { type: 'boolean', operation: 'true', singleValue: true } }],
      combinator: 'and' }, options: {} } },
  { id: 'avisos-resp-ok', name: 'Responder: enviando', type: 'n8n-nodes-base.respondToWebhook', typeVersion: 1.1, position: [880, 160],
    parameters: responder(202, { ok: true, mensaje: 'Enviando avisos' }) },
  { id: 'avisos-resp-no', name: 'Responder: no autorizado', type: 'n8n-nodes-base.respondToWebhook', typeVersion: 1.1, position: [880, 300],
    parameters: responder(401, { ok: false, mensaje: 'Inicia sesión en el panel' }) },
);

const a = nodo => ({ node: nodo, type: 'main', index: 0 });
const c = w.connections;
c['Botón Enviar ahora'] = { main: [[a('¿Quién lo pulsó?')]] };
c['¿Quién lo pulsó?'] = { main: [[a('¿Es personal del CEA?')]] };
c['¿Es personal del CEA?'] = { main: [[a('¿Autorizado?')]] };
c['¿Autorizado?'] = { main: [[a('Responder: enviando')], [a('Responder: no autorizado')]] };
c['Responder: enviando'] = { main: [[a('Avisos pendientes')]] };

w.name = 'Avisos de turnos (cada 5 min y botón Enviar ahora)';
fs.writeFileSync(archivo, JSON.stringify(crudo, null, 2));
console.log('Listo:', w.nodes.length, 'nodos');
