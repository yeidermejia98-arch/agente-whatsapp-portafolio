// Convierte las filas del "Listado de Facturas" (o cualquier Excel con columnas parecidas)
// en alumnos listos para importar. No toca la pantalla ni la base: solo transforma datos.

// "300 000 0000" → "573001234567" (formato que exige WhatsApp)
export function normalizarTelefono(texto) {
  const digitos = String(texto ?? '').replace(/\D/g, '');
  if (digitos.length === 10 && digitos.startsWith('3')) return '57' + digitos;
  return digitos;
}

export const telefonoValido = (telefono) => /^[1-9]\d{7,14}$/.test(telefono);

// "Nombre Cliente" → "nombre cliente" (sin tildes, para reconocer encabezados)
const normal = (texto) =>
  String(texto).normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim();

const COLUMNAS = {
  documento: /\b(doc|documento|cedula|identificacion|nit)\b/,
  nombre: /nombre/,
  tramite: /tramite|categoria/,
  valor: /valor/,
  saldo: /saldo/,
  telefono: /tel|cel|movil|whats/,
};

export function detectarColumnas(encabezados) {
  const columnas = {};
  for (const [campo, patron] of Object.entries(COLUMNAS)) {
    columnas[campo] = encabezados.find((h) => patron.test(normal(h)));
  }
  return columnas;
}

// "225.000,00 COP" → 225000 · "485.000 COP" → 485000 · 485000 → 485000
export function leerPesos(valor) {
  if (typeof valor === 'number') return Math.round(valor);
  const texto = String(valor ?? '').replace(/[^\d,.-]/g, '');
  if (!texto) return null;
  const numero = Number(texto.replace(/\./g, '').replace(',', '.'));
  return Number.isFinite(numero) ? Math.round(numero) : null;
}

// "CEA: C1-Inicial + A2-Inicial\nCRC: EXAM …" → "C1 + A2"
export function leerCategoria(tramite) {
  const texto = String(tramite ?? '');
  const lineaCea = texto.match(/CEA:([^\n]*)/i)?.[1] ?? texto;
  const categorias = lineaCea.match(/\b[ABC]\s?[1-3]\b/gi) ?? [];
  const unicas = [...new Set(categorias.map((c) => c.replace(/\s/g, '').toUpperCase()))];
  return unicas.length ? unicas.join(' + ') : null;
}

const leerDocumento = (valor) => String(valor ?? '').replace(/[\s.]/g, '').trim();

// filas: objetos {encabezado: valor} (como los entrega SheetJS con sheet_to_json)
// existentes: Map documento → teléfono guardado (o null)
export function prepararImportacion(filas, existentes = new Map()) {
  const encabezados = Object.keys(filas[0] ?? {});
  const col = detectarColumnas(encabezados);
  const faltan = ['documento', 'nombre', 'saldo'].filter((c) => !col[c]);
  if (faltan.length) {
    return { error: `No encontré las columnas: ${faltan.join(', ')}. Revisa que el archivo sea el listado de facturas.` };
  }

  const alumnos = [];
  const vistosDoc = new Set();
  const vistosTel = new Map();

  for (const fila of filas) {
    const documento = leerDocumento(fila[col.documento]);
    if (!documento) continue; // filas vacías o la de "Total:"

    const telefonoCrudo = col.telefono ? String(fila[col.telefono] ?? '').trim() : '';
    const telefono = telefonoCrudo ? normalizarTelefono(telefonoCrudo) : null;
    const alumno = {
      documento,
      nombre: String(fila[col.nombre] ?? '').replace(/\s+/g, ' ').trim(),
      categoria: col.tramite ? leerCategoria(fila[col.tramite]) : null,
      valor: col.valor ? leerPesos(fila[col.valor]) : null,
      saldo: leerPesos(fila[col.saldo]),
      telefono,
      errores: [],
      avisos: [],
    };

    if (!alumno.nombre) alumno.errores.push('sin nombre');
    if (alumno.saldo === null || alumno.saldo < 0) alumno.errores.push('saldo no válido');
    if (alumno.valor !== null && alumno.saldo !== null && alumno.saldo > alumno.valor) {
      alumno.avisos.push('el saldo es mayor que el valor');
    }
    if (vistosDoc.has(documento)) alumno.errores.push('cédula repetida en el archivo');
    vistosDoc.add(documento);

    if (telefono) {
      if (!telefonoValido(telefono)) alumno.errores.push(`teléfono no válido (${telefonoCrudo})`);
      else if (vistosTel.has(telefono)) alumno.errores.push(`mismo teléfono que ${vistosTel.get(telefono)}`);
      else vistosTel.set(telefono, alumno.nombre);
    }

    alumno.existe = existentes.has(documento);
    const telefonoGuardado = existentes.get(documento) ?? null;
    alumno.telefonoFinal = telefono ?? telefonoGuardado;
    if (!alumno.telefonoFinal) alumno.avisos.push('falta WhatsApp: no recibirá recordatorios');

    alumnos.push(alumno);
  }

  return { alumnos, columnas: col };
}
