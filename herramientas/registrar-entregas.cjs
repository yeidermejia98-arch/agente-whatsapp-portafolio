// WhatsApp avisa por el mismo webhook de Lizz si cada mensaje se envió, entregó, leyó o falló.
// Antes esos avisos ("statuses") se descartaban; este script agrega una rama que los guarda en
// mensajes.entrega (migración 0022). Uso: node registrar-entregas.cjs flujo.json
const fs = require('fs');
const archivo = process.argv[2];
const crudo = JSON.parse(fs.readFileSync(archivo, 'utf8'));
const w = Array.isArray(crudo) ? crudo[0] : crudo;
if (w.nodes.some(n => n.name === 'Estados de entrega')) { console.log('Ya tenía la rama de entregas'); process.exit(0); }

const disparador = w.nodes.find(n => n.name === 'WhatsApp Trigger');
// La copia del repositorio no trae credenciales; la exportada del servidor sí
const pg = (w.nodes.find(n => /postgres/i.test(n.type) && n.credentials?.postgres) || {}).credentials;
const [x, y] = disparador.position;

w.nodes.push(
  { id: 'estados-entrega', name: 'Estados de entrega', type: 'n8n-nodes-base.code', typeVersion: 2, position: [x + 220, y + 400],
    parameters: { jsCode: [
      '// Un elemento por cada estado (sent, delivered, read, failed); si no hay, la rama no sigue',
      'const salida = [];',
      'for (const item of $input.all()) {',
      '  for (const s of item.json.statuses || []) {',
      '    const e = s.errors && s.errors[0];',
      "    salida.push({ json: { id: s.id, estado: s.status, error: e ? `${e.code} ${e.title || ''}`.trim() : '' } });",
      '  }',
      '}',
      'return salida;',
    ].join('\n') } },
  { id: 'registrar-entrega', name: 'Registrar entrega', type: 'n8n-nodes-base.postgres', typeVersion: 2.5, position: [x + 440, y + 400], credentials: pg,
    parameters: { operation: 'executeQuery', query: 'select public.registrar_estado_whatsapp($1, $2, $3);',
      options: { queryReplacement: '={{ [ $json.id, $json.estado, $json.error ] }}' } } },
);

const salida = w.connections['WhatsApp Trigger'].main[0];
salida.push({ node: 'Estados de entrega', type: 'main', index: 0 });
w.connections['Estados de entrega'] = { main: [[{ node: 'Registrar entrega', type: 'main', index: 0 }]] };

fs.writeFileSync(archivo, JSON.stringify(crudo, null, 2));
console.log('Listo:', w.nodes.length, 'nodos');
