// Lizz atiende también a quien usa nombre de usuario en WhatsApp y oculta su número: Meta manda
// messages[0].from_user_id (BSUID) en vez de messages[0].from, y para responderle se usa
// "recipient" en lugar de "to". Uso: node soportar-usuarios-sin-numero.cjs flujo.json
const fs = require('fs');
const archivo = process.argv[2];
const crudo = JSON.parse(fs.readFileSync(archivo, 'utf8'));
const w = Array.isArray(crudo) ? crudo[0] : crudo;

const QUIEN = "($('WhatsApp Trigger').first().json.messages[0].from || $('WhatsApp Trigger').first().json.messages[0].from_user_id)";
// Destino: número → { to }, identificador de usuario (tiene letras y punto) → { recipient }
const destino = (expr) => `...(/^[0-9]+$/.test(String(${expr})) ? { to: ${expr} } : { recipient: ${expr} })`;

// Marca temporal para no volver a reemplazar dentro de lo ya reemplazado
const MARCA = '@@QUIEN@@';
const DE_RE = /\$\('WhatsApp Trigger'\)\.first\(\)\.json\.messages\[0\]\.from(?!_user_id)/g;
let cambios = 0;
const reemplazar = (s, a, b) => { const n = s.split(a).length - 1; cambios += n; return s.split(a).join(b); };

for (const n of w.nodes) {
  let p = JSON.stringify(n.parameters);
  if (p.includes('from_user_id')) continue; // ya adaptado

  if (n.name === 'Solo mensajes entrantes') {
    p = reemplazar(p, '{{ $json.messages?.[0]?.from }}', '{{ $json.messages?.[0]?.from || $json.messages?.[0]?.from_user_id }}');
  } else {
    p = p.replace(DE_RE, MARCA);
    // Envíos al cliente: "to: <quien>" y "to: $json.para"
    p = reemplazar(p, 'to: ' + MARCA + ',', destino(MARCA) + ',');
    p = reemplazar(p, 'to: $json.para,', destino('$json.para') + ',');
    p = reemplazar(p, 'to: $json.para || $env.OFICINA_WHATSAPP,', destino('($json.para || $env.OFICINA_WHATSAPP)') + ',');
    // Cualquier otro uso (base de datos, memoria)
    p = reemplazar(p, MARCA, QUIEN);
  }
  n.parameters = JSON.parse(p);
}

const quedan = JSON.stringify(w.nodes.map(n => n.parameters));
if (/(?<!\? \{ )to: (\$\('WhatsApp Trigger'\)|\(?\$json\.para)/.test(quedan)) throw new Error('Quedó un envío con "to" sin adaptar');
fs.writeFileSync(archivo, JSON.stringify(crudo, null, 2));
console.log('Listo:', cambios, 'cambios');
