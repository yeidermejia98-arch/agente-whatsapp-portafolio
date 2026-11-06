// Agrega el puente de atención humana al flujo de Lizz (flujos/agente-whatsapp.json).
// Uso: node puente.cjs <ruta del flujo>   (modifica el archivo; se puede ejecutar una sola vez)
const fs = require('fs');
const ruta = process.argv[2];
const w = JSON.parse(fs.readFileSync(ruta, 'utf8'));
if (w.nodes.some((n) => n.name === 'Puente: decidir')) { console.log('ya tenía el puente'); process.exit(0); }

const n = Object.fromEntries(w.nodes.map((x) => [x.name, x]));
const pg = n['Contexto'].credentials;                 // Supabase CEA
const wa = n['Responder por WhatsApp'].credentials;   // WhatsApp Cloud API
const msg = "$('WhatsApp Trigger').first().json.messages[0]";
const urlMensajes = '={{ $env.WHATSAPP_API_URL }}/{{ $env.WHATSAPP_PHONE_NUMBER_ID }}/messages';

// Cuerpo de envío: texto normal, o la plantilla atencion_humana si la oficina no escribió en 24 h
const cuerpoEnvio = `={{ JSON.stringify($json.plantilla
  ? { messaging_product: 'whatsapp', to: $json.para || $env.OFICINA_WHATSAPP, type: 'template',
      template: { name: 'atencion_humana', language: { code: 'es' },
        components: [{ type: 'body', parameters: [
          { type: 'text', text: $json.nombre }, { type: 'text', text: $json.whatsapp }, { type: 'text', text: $json.motivo } ] }] } }
  : { messaging_product: 'whatsapp', to: $json.para || $env.OFICINA_WHATSAPP, type: 'text', text: { body: $json.texto } }) }}`;

const nuevos = [
  {
    id: 'puente-01', name: 'Puente: decidir', type: 'n8n-nodes-base.postgres', typeVersion: 2.6,
    position: [n['Solo mensajes entrantes'].position[0] + 120, n['Solo mensajes entrantes'].position[1] + 220],
    credentials: pg,
    parameters: {
      operation: 'executeQuery',
      query: 'select * from public.puente_entrante($1, $2, $3, nullif($4, \'\'), $5);',
      options: { queryReplacement: `={{ [ ${msg}.from, ${msg}.type, ${msg}.text?.body ?? '', ${msg}.context?.id ?? '', $env.OFICINA_WHATSAPP ] }}` },
    },
  },
  {
    id: 'puente-02', name: '¿Lo atiende Lizz?', type: 'n8n-nodes-base.if', typeVersion: 2.2,
    position: [n['Solo mensajes entrantes'].position[0] + 340, n['Solo mensajes entrantes'].position[1] + 220],
    parameters: {
      conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
        conditions: [{ id: 'puente-c1', leftValue: '={{ $json.accion }}', rightValue: 'lizz', operator: { type: 'string', operation: 'equals' } }],
        combinator: 'and' },
      options: {},
    },
  },
  {
    id: 'puente-03', name: 'Puente: enviar', type: 'n8n-nodes-base.httpRequest', typeVersion: 4.2,
    position: [n['Solo mensajes entrantes'].position[0] + 560, n['Solo mensajes entrantes'].position[1] + 420],
    credentials: wa, onError: 'continueRegularOutput',
    parameters: { method: 'POST', url: urlMensajes, authentication: 'genericCredentialType', genericAuthType: 'httpHeaderAuth',
      sendBody: true, specifyBody: 'json', jsonBody: cuerpoEnvio, options: {} },
  },
  {
    id: 'puente-04', name: 'Puente: registrar envío', type: 'n8n-nodes-base.postgres', typeVersion: 2.6,
    position: [n['Solo mensajes entrantes'].position[0] + 780, n['Solo mensajes entrantes'].position[1] + 420],
    credentials: pg,
    parameters: { operation: 'executeQuery',
      query: 'select public.puente_registrar_envio($1, $2, false);',
      options: { queryReplacement: "={{ [ $('Puente: decidir').item.json.atencion_id, $json.messages?.[0]?.id ?? '' ] }}" } },
  },
  {
    id: 'puente-05', name: '¿Hay que registrarlo?', type: 'n8n-nodes-base.if', typeVersion: 2.2,
    position: [n['Solo mensajes entrantes'].position[0] + 670, n['Solo mensajes entrantes'].position[1] + 420],
    parameters: {
      conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
        conditions: [{ id: 'puente-c2', leftValue: "={{ $('Puente: decidir').item.json.registrar === true && !!$json.messages?.[0]?.id }}", rightValue: '',
          operator: { type: 'boolean', operation: 'true', singleValue: true } }],
        combinator: 'and' },
      options: {},
    },
  },
  // Después de que Lizz responde: si abrió una atención, avisar a la oficina
  {
    id: 'puente-06', name: 'Puente: avisos pendientes', type: 'n8n-nodes-base.postgres', typeVersion: 2.6,
    position: [n['Responder por WhatsApp'].position[0] + 220, n['Responder por WhatsApp'].position[1]],
    credentials: pg,
    parameters: { operation: 'executeQuery', query: 'select * from public.puente_avisos_pendientes($1);',
      options: { queryReplacement: `={{ [ ${msg}.from ] }}` } },
  },
  {
    id: 'puente-07', name: 'Puente: avisar a la oficina', type: 'n8n-nodes-base.httpRequest', typeVersion: 4.2,
    position: [n['Responder por WhatsApp'].position[0] + 440, n['Responder por WhatsApp'].position[1]],
    credentials: wa, onError: 'continueRegularOutput',
    parameters: { method: 'POST', url: urlMensajes, authentication: 'genericCredentialType', genericAuthType: 'httpHeaderAuth',
      sendBody: true, specifyBody: 'json', jsonBody: cuerpoEnvio, options: {} },
  },
  {
    id: 'puente-08', name: 'Puente: registrar aviso', type: 'n8n-nodes-base.postgres', typeVersion: 2.6,
    position: [n['Responder por WhatsApp'].position[0] + 660, n['Responder por WhatsApp'].position[1]],
    credentials: pg,
    parameters: { operation: 'executeQuery', query: 'select public.puente_registrar_envio($1, $2, true);',
      options: { queryReplacement: "={{ [ $('Puente: avisos pendientes').item.json.atencion_id, $json.messages?.[0]?.id ?? '' ] }}" } },
  },
  // Cada 5 minutos: atenciones sin respuesta en horario → Lizz le avisa al cliente
  {
    id: 'puente-09', name: 'Cada 5 min: atenciones vencidas', type: 'n8n-nodes-base.scheduleTrigger', typeVersion: 1.2,
    position: [n['WhatsApp Trigger'].position[0], n['WhatsApp Trigger'].position[1] + 700],
    parameters: { rule: { interval: [{ field: 'minutes', minutesInterval: 5 }] } },
  },
  {
    id: 'puente-10', name: 'Puente: vencidas', type: 'n8n-nodes-base.postgres', typeVersion: 2.6,
    position: [n['WhatsApp Trigger'].position[0] + 220, n['WhatsApp Trigger'].position[1] + 700],
    credentials: pg,
    parameters: { operation: 'executeQuery', query: 'select * from public.puente_vencidas();', options: {} },
  },
  {
    id: 'puente-11', name: 'Puente: avisar al cliente', type: 'n8n-nodes-base.httpRequest', typeVersion: 4.2,
    position: [n['WhatsApp Trigger'].position[0] + 440, n['WhatsApp Trigger'].position[1] + 700],
    credentials: wa, onError: 'continueRegularOutput',
    parameters: { method: 'POST', url: urlMensajes, authentication: 'genericCredentialType', genericAuthType: 'httpHeaderAuth',
      sendBody: true, specifyBody: 'json',
      jsonBody: "={{ JSON.stringify({ messaging_product: 'whatsapp', to: $json.para, type: 'text', text: { body: $json.texto } }) }}",
      options: {} },
  },
];
// Filtros: solo seguir si la consulta trajo una atención de verdad (no un ítem vacío)
const filtro = (id, nombre, pos) => ({
  id, name: nombre, type: 'n8n-nodes-base.filter', typeVersion: 2.2, position: pos,
  parameters: {
    conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
      conditions: [{ id: id + '-c', leftValue: '={{ $json.atencion_id }}', rightValue: '', operator: { type: 'number', operation: 'exists', singleValue: true } }],
      combinator: 'and' },
    options: {},
  },
});
nuevos.push(
  filtro('puente-12', '¿Hay aviso para la oficina?', [n['Responder por WhatsApp'].position[0] + 330, n['Responder por WhatsApp'].position[1] + 160]),
  filtro('puente-13', '¿Hay atenciones vencidas?', [n['WhatsApp Trigger'].position[0] + 330, n['WhatsApp Trigger'].position[1] + 860]),
);
w.nodes.push(...nuevos);

// Los IF que leían $json ahora leen el mensaje original (su entrada pasa a ser la del puente)
n['¿Es texto?'].parameters.conditions.conditions[0].leftValue = `={{ ${msg}.type }}`;
n['¿Es foto o documento?'].parameters.conditions.conditions[0].leftValue = `={{ ['image', 'document'].includes(${msg}.type) }}`;

const c = w.connections;
const a = (nodo, i = 0) => ({ node: nodo, type: 'main', index: i });
c['Solo mensajes entrantes'] = { main: [[a('Puente: decidir')]] };
c['Puente: decidir'] = { main: [[a('¿Lo atiende Lizz?')]] };
c['¿Lo atiende Lizz?'] = { main: [[a('¿Es texto?')], [a('Puente: enviar')]] };
c['Puente: enviar'] = { main: [[a('¿Hay que registrarlo?')]] };
c['¿Hay que registrarlo?'] = { main: [[a('Puente: registrar envío')], []] };
c['Responder por WhatsApp'] = { main: [[a('Puente: avisos pendientes')]] };
c['Puente: avisos pendientes'] = { main: [[a('¿Hay aviso para la oficina?')]] };
c['¿Hay aviso para la oficina?'] = { main: [[a('Puente: avisar a la oficina')]] };
c['Puente: avisar a la oficina'] = { main: [[a('Puente: registrar aviso')]] };
c['Cada 5 min: atenciones vencidas'] = { main: [[a('Puente: vencidas')]] };
c['Puente: vencidas'] = { main: [[a('¿Hay atenciones vencidas?')]] };
c['¿Hay atenciones vencidas?'] = { main: [[a('Puente: avisar al cliente')]] };

fs.writeFileSync(ruta, JSON.stringify(w, null, 2) + '\n');
console.log('puente agregado:', nuevos.length, 'nodos');
