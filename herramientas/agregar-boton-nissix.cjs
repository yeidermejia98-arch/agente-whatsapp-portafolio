// Agrega al flujo de NissiX el botón del panel (webhook que verifica al usuario del panel)
// y la sincronización de las 11:30 a. m. en los días de cobro. Uso: node agregar-boton-nissix.cjs flujo.json
const fs = require('fs');
const path = require('path');
const archivo = process.argv[2];
const crudo = JSON.parse(fs.readFileSync(archivo, 'utf8'));
const w = Array.isArray(crudo) ? crudo[0] : crudo;
if (w.nodes.some(n => n.name === 'Botón del panel')) { console.log('Ya tenía el botón'); process.exit(0); }

const SUPABASE = 'https://TU-PROYECTO.supabase.co';
const LLAVE = (fs.readFileSync(path.join(__dirname, '../panel/config.js'), 'utf8')
  .match(/sb_publishable_[A-Za-z0-9_-]+/) || [])[0];
if (!LLAVE) throw new Error('No encontré la publishable key en panel/config.js');
const pg = w.nodes.find(n => n.name === 'Importar alumnos').credentials;
const hoy12 = "((now() at time zone 'America/Bogota')::date + time '12:00') at time zone 'America/Bogota'";
const motivo = (m, posicion) => ({ id: 'motivo-' + m.replace(/\W+/g, '-'), name: 'Motivo: ' + m,
  type: 'n8n-nodes-base.noOp', typeVersion: 1, position: posicion, parameters: {} });
const responder = (codigo, cuerpo) => ({ respondWith: 'json', responseBody: JSON.stringify(cuerpo), options: { responseCode: codigo } });
const si = (id, izq, op, der) => ({ conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
  conditions: [{ id, leftValue: izq, rightValue: der, operator: op }], combinator: 'and' }, options: {} });

// Correr los nodos viejos a la derecha para dar espacio a los nuevos
for (const n of w.nodes) {
  if (n.name === 'Domingos 6 p. m.') n.position = [-220, 0];
  else if (n.name === 'Probar ahora') n.position = [-220, -160];
  else n.position = [n.position[0] + 220, n.position[1]];
}

w.nodes.push(
  { id: 'boton-panel', name: 'Botón del panel', type: 'n8n-nodes-base.webhook', typeVersion: 2, position: [-880, 260], webhookId: 'nissix-ahora',
    parameters: { httpMethod: 'POST', path: 'nissix-ahora', responseMode: 'responseNode', options: {} } },
  { id: 'quien-pulsa', name: '¿Quién lo pulsó?', type: 'n8n-nodes-base.httpRequest', typeVersion: 4.2, position: [-660, 260],
    parameters: { url: SUPABASE + '/auth/v1/user', sendHeaders: true, headerParameters: { parameters: [
      { name: 'apikey', value: LLAVE },
      { name: 'Authorization', value: "={{ $json.headers.authorization || '' }}" }] },
      options: { response: { response: { fullResponse: true, neverError: true } }, timeout: 15000 } } },
  { id: 'es-personal', name: '¿Es personal del CEA?', type: 'n8n-nodes-base.postgres', typeVersion: 2.5, position: [-440, 260], credentials: pg,
    parameters: { operation: 'executeQuery',
      query: "select exists(select 1 from public.personal where user_id = nullif($1, '')::uuid) as autorizado;",
      options: { queryReplacement: "={{ [ $json.statusCode === 200 && $json.body && $json.body.id ? $json.body.id : '' ] }}" } } },
  { id: 'autorizado', name: '¿Autorizado?', type: 'n8n-nodes-base.if', typeVersion: 2.2, position: [-220, 260],
    parameters: si('a1', '={{ $json.autorizado }}', { type: 'boolean', operation: 'true', singleValue: true }, '') },
  { id: 'resp-ok', name: 'Responder: sincronizando', type: 'n8n-nodes-base.respondToWebhook', typeVersion: 1.1, position: [0, 180],
    parameters: responder(202, { ok: true, mensaje: 'Sincronizando con NissiX' }) },
  { id: 'resp-no', name: 'Responder: no autorizado', type: 'n8n-nodes-base.respondToWebhook', typeVersion: 1.1, position: [0, 340],
    parameters: responder(401, { ok: false, mensaje: 'Inicia sesión en el panel' }) },
  { id: 'dias-cobro', name: 'Días de cobro 11:30 a. m.', type: 'n8n-nodes-base.scheduleTrigger', typeVersion: 1.2, position: [-660, 500],
    parameters: { rule: { interval: [{ field: 'days', triggerAtHour: 11, triggerAtMinute: 30 }] } } },
  { id: 'hay-cobro', name: '¿Hay cobros hoy?', type: 'n8n-nodes-base.postgres', typeVersion: 2.5, position: [-440, 500], credentials: pg,
    parameters: { operation: 'executeQuery', query: `select count(*)::int as alumnos from public.saldos_para_hoy(${hoy12});`, options: {} } },
  { id: 'si-cobro', name: '¿Alguno?', type: 'n8n-nodes-base.if', typeVersion: 2.2, position: [-220, 500],
    parameters: si('c1', '={{ $json.alumnos }}', { type: 'number', operation: 'gt' }, 0) },
  motivo('prueba manual', [0, -160]), motivo('domingo', [0, 0]),
  motivo('botón del panel', [220, 180]), motivo('antes del cobro', [0, 500]),
);

const a = nodo => ({ node: nodo, type: 'main', index: 0 });
const c = w.connections;
c['Domingos 6 p. m.'] = { main: [[a('Motivo: domingo')]] };
c['Probar ahora'] = { main: [[a('Motivo: prueba manual')]] };
c['Botón del panel'] = { main: [[a('¿Quién lo pulsó?')]] };
c['¿Quién lo pulsó?'] = { main: [[a('¿Es personal del CEA?')]] };
c['¿Es personal del CEA?'] = { main: [[a('¿Autorizado?')]] };
c['¿Autorizado?'] = { main: [[a('Responder: sincronizando')], [a('Responder: no autorizado')]] };
c['Responder: sincronizando'] = { main: [[a('Motivo: botón del panel')]] };
c['Días de cobro 11:30 a. m.'] = { main: [[a('¿Hay cobros hoy?')]] };
c['¿Hay cobros hoy?'] = { main: [[a('¿Alguno?')]] };
c['¿Alguno?'] = { main: [[a('Motivo: antes del cobro')], []] };
for (const m of ['domingo', 'prueba manual', 'botón del panel', 'antes del cobro']) c['Motivo: ' + m] = { main: [[a('Iniciar sesión en NissiX')]] };

// Guardar el motivo en cada registro (éxito o error)
const expr = "($('Motivo: botón del panel').isExecuted ? 'botón del panel' : $('Motivo: antes del cobro').isExecuted ? 'antes del cobro' : $('Motivo: domingo').isExecuted ? 'domingo' : 'prueba manual')";
const ok = w.nodes.find(n => n.name === 'Registrar sincronización').parameters;
ok.query = "insert into public.sincronizaciones (ok, facturas, creados, actualizados, sin_telefono, detalle, motivo) values (true, $1, $2, $3, $4, nullif($5, ''), $6);";
ok.options.queryReplacement = ok.options.queryReplacement.replace(/\n\] \}\}$/, ',\n  ' + expr + '\n] }}');
if (!ok.options.queryReplacement.includes('isExecuted')) throw new Error('No pude agregar el motivo al registro');
const err = w.nodes.find(n => n.name === 'Registrar error').parameters;
err.query = 'insert into public.sincronizaciones (ok, detalle, motivo) values (false, $1, $2);';
err.options.queryReplacement = '={{ [ $json.detalle, ' + expr + ' ] }}';

// `n8n execute` (consola) arranca por el primer disparador de la lista: que sea "Probar ahora"
w.nodes.sort((x, y) => (y.name === 'Probar ahora') - (x.name === 'Probar ahora'));

w.name = 'Sincronizar alumnos desde NissiX (domingos, días de cobro y botón del panel)';
fs.writeFileSync(archivo, JSON.stringify(crudo, null, 2));
console.log('Listo:', w.nodes.length, 'nodos');
