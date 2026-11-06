import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from './config.js';
import { normalizarTelefono, telefonoValido, prepararImportacion } from './excel.js';

const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);

const ZONA = 'America/Bogota';
const OFFSET_COLOMBIA = '-05:00'; // Colombia no cambia de hora en el año

const $ = (selector) => document.querySelector(selector);

// ─────────────────────────────── Utilidades ───────────────────────────────

// Crea un elemento con texto seguro (nunca innerHTML con datos del usuario).
function el(etiqueta, texto = '', clase = '') {
  const nodo = document.createElement(etiqueta);
  if (texto !== '') nodo.textContent = texto;
  if (clase) nodo.className = clase;
  return nodo;
}

function fila(celdas) {
  const tr = document.createElement('tr');
  for (const celda of celdas) {
    if (celda instanceof Node) {
      const td = document.createElement('td');
      td.append(celda);
      tr.append(td);
    } else {
      tr.append(el('td', String(celda ?? '')));
    }
  }
  return tr;
}

function filaVacia(tbody, columnas, texto) {
  const td = el('td', texto, 'vacio');
  td.colSpan = columnas;
  const tr = document.createElement('tr');
  tr.append(td);
  tbody.replaceChildren(tr);
}

const pesos = (valor) =>
  new Intl.NumberFormat('es-CO', { style: 'currency', currency: 'COP', maximumFractionDigits: 0 }).format(valor);

const fecha = (iso) =>
  new Intl.DateTimeFormat('es-CO', { timeZone: ZONA, weekday: 'short', day: 'numeric', month: 'short' }).format(new Date(iso));

const hora = (iso) =>
  new Intl.DateTimeFormat('es-CO', { timeZone: ZONA, hour: 'numeric', minute: '2-digit' }).format(new Date(iso));

const fechaHora = (iso) => `${fecha(iso)} · ${hora(iso)}`;

const TIPOS = { practica: 'Práctica', teorica: 'Teórica', examen: 'Examen', validacion: 'Validación' };

// Alumnos activos para la agenda: id → { id, nombre, documento, telefono, categoria }
const alumnosAgenda = new Map();
const etiquetaAlumno = (a) => (a.documento ? `${a.nombre} · CC ${a.documento}` : a.nombre);

// "C1 + A2" → ['C1', 'A2']
const categoriasDe = (texto) => [...new Set(String(texto ?? '').toUpperCase().match(/[ABC][1-3]/g) ?? [])];

function llenarCategorias(select, categoria) {
  const cats = categoriasDe(categoria);
  const vacia = el('option', cats.length ? 'Elige la categoría…' : 'Sin categoría registrada');
  vacia.value = '';
  select.replaceChildren(vacia, ...cats.map((c) => {
    const opcion = el('option', c);
    opcion.value = c;
    return opcion;
  }));
  if (cats.length === 1) select.value = cats[0];
}

function avisar(texto, tipo = 'ok') {
  const aviso = $('#aviso');
  aviso.textContent = texto;
  aviso.className = `aviso global ${tipo}`;
  if (tipo === 'ok') setTimeout(() => { if (aviso.textContent === texto) aviso.textContent = ''; }, 4000);
}

// Traduce los errores de la base de datos a algo entendible.
function explicarError(error) {
  if (error.code === '23P01') {
    if (String(error.message).includes('vehiculo')) return 'Ese vehículo ya está ocupado en ese horario.';
    return 'Ese horario se cruza con otro turno del instructor o del alumno.';
  }
  if (error.code === '23505') return 'Ya existe un alumno con ese número de WhatsApp o esa cédula.';
  if (error.code === '23514') return 'Algún dato no es válido (revisa el teléfono, los valores y las horas).';
  if (error.code === '42501') return 'Tu usuario no tiene permiso para esto.';
  return error.message;
}

// Envía un formulario sin permitir doble clic.
function alEnviar(form, accion) {
  form.addEventListener('submit', async (evento) => {
    evento.preventDefault();
    const boton = form.querySelector('button[type="submit"]');
    boton.disabled = true;
    try {
      const datos = Object.fromEntries(new FormData(form));
      const error = await accion(datos, form);
      if (error) avisar(explicarError(error), 'error');
    } finally {
      boton.disabled = false;
    }
  });
}

// ─────────────────────────────── Ingreso ───────────────────────────────

alEnviar($('#form-ingreso'), async ({ correo, clave }) => {
  const { error } = await supabase.auth.signInWithPassword({ email: correo, password: clave });
  if (error) $('#aviso-ingreso').textContent = 'Correo o contraseña incorrectos.';
});

$('#salir').addEventListener('click', () => supabase.auth.signOut());

supabase.auth.onAuthStateChange((_evento, sesion) => {
  // setTimeout: Supabase recomienda no llamar la base dentro de este aviso directamente.
  setTimeout(() => mostrarVista(sesion), 0);
});

let panelCargado = false;

async function mostrarVista(sesion) {
  if (!sesion) {
    panelCargado = false;
    $('#vista-panel').hidden = true;
    $('#vista-ingreso').hidden = false;
    return;
  }
  // ¿Este usuario está registrado como personal del CEA?
  const { data } = await supabase.from('personal').select('nombre').maybeSingle();
  if (!data) {
    $('#aviso-ingreso').textContent = 'Tu usuario no está autorizado. Pide que te agreguen a la tabla "personal".';
    await supabase.auth.signOut();
    return;
  }
  $('#usuario-nombre').textContent = data.nombre ?? '';
  $('#vista-ingreso').hidden = true;
  $('#vista-panel').hidden = false;
  if (!panelCargado) {
    panelCargado = true;
    await recargarTodo();
  }
}

// ─────────────────────────────── Pestañas ───────────────────────────────

for (const boton of document.querySelectorAll('[data-pestana]')) {
  boton.addEventListener('click', () => {
    for (const otro of document.querySelectorAll('[data-pestana]')) {
      const activo = otro === boton;
      otro.setAttribute('aria-selected', String(activo));
      $('#' + otro.dataset.pestana).hidden = !activo;
    }
    // Título de la sección = texto del botón, sin el contador
    $('#titulo-pagina').textContent = [...boton.childNodes]
      .filter((n) => n.nodeType === Node.TEXT_NODE).map((n) => n.textContent).join('').trim();
    if (boton.dataset.pestana === 'mensajes') cargarMensajes();
    if (boton.dataset.pestana === 'importar') cargarSincronizaciones();
    if (boton.dataset.pestana === 'faq') cargarFaq();
    if (boton.dataset.pestana === 'humano') cargarHumano();
    if (boton.dataset.pestana === 'matriculas') cargarMatriculas();
  });
}

// ─────────────────────────────── Carga de datos ───────────────────────────────

async function recargarTodo() {
  await Promise.all([cargarAlumnos(), cargarInstructores(), cargarVehiculos(), cargarTurnos(), cargarPagos(), cargarHumano(), cargarMatriculas(), cargarSincronizaciones(), cargarAvisosEnEspera()]);
  await cargarSemana();
}

// ─────────────────────── Avisos en espera (horario de descanso) ───────────────────────

// De 9 p. m. a 6 a. m. los avisos de WhatsApp esperan a las 6 a. m.; con "Enviar ahora" salen ya.
function esHorarioDeDescanso() {
  const hora = Number(new Intl.DateTimeFormat('en-US', { timeZone: ZONA, hour: 'numeric', hourCycle: 'h23' }).format(new Date()));
  return hora < 6 || hora > 20;
}

async function avisosEnEspera() {
  const { data, error } = await supabase.rpc('avisos_en_espera');
  return error ? null : data;
}

async function cargarAvisosEnEspera() {
  const caja = $('#avisos-espera');
  const avisos = esHorarioDeDescanso() ? await avisosEnEspera() : [];
  caja.hidden = !avisos?.length;
  if (caja.hidden) return;
  const nombres = [...new Set(avisos.map((a) => a.nombre))];
  $('#avisos-espera-texto').textContent =
    `${avisos.length === 1 ? '1 aviso espera' : `${avisos.length} avisos esperan`} hasta las 6 a. m. (${nombres.join(', ')}).`;
}

$('#enviar-avisos-ahora').addEventListener('click', async () => {
  const boton = $('#enviar-avisos-ahora');
  const { data: { session } } = await supabase.auth.getSession();
  if (!session) return avisar('Tu sesión venció. Vuelve a entrar al panel.', 'error');
  if (!confirm('¿Enviar ahora por WhatsApp los avisos que esperan? Saldrán aunque sea horario de descanso.')) return;

  boton.disabled = true;
  boton.textContent = 'Enviando…';
  try {
    const r = await fetch('/webhook/avisos-ahora', { method: 'POST', headers: { Authorization: `Bearer ${session.access_token}` } });
    if (!r.ok) throw new Error(r.status === 401 ? 'tu sesión venció, vuelve a entrar al panel.' : `el servidor respondió ${r.status}.`);
    // Se envían en segundos; se espera a que ya no quede ninguno pendiente
    for (let i = 0; i < 20; i++) {
      await new Promise((listo) => setTimeout(listo, 3000));
      const quedan = await avisosEnEspera();
      if (quedan && !quedan.length) {
        avisar('Avisos enviados por WhatsApp. Puedes verlos en Mensajes enviados.');
        return;
      }
    }
    avisar('Algunos avisos no salieron todavía. Revisa Mensajes enviados en unos minutos.', 'error');
  } catch (e) {
    avisar(`No se pudieron enviar: ${e.message}`, 'error');
  } finally {
    boton.disabled = false;
    boton.textContent = 'Enviar ahora';
    await cargarAvisosEnEspera();
  }
});

function llenarSelect(select, opciones, textoVacio) {
  const primera = el('option', textoVacio);
  primera.value = '';
  select.replaceChildren(primera, ...opciones.map(({ id, nombre }) => {
    const opcion = el('option', nombre);
    opcion.value = id;
    return opcion;
  }));
}

// Todos los alumnos (saldo + datos), para la tabla y los buscadores.
let listaAlumnos = [];

// "José Núñez" → "jose nunez" (para buscar sin importar tildes ni mayúsculas)
const sinTildes = (texto) => String(texto ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();

function coincide(a, consulta) {
  const q = sinTildes(consulta).trim();
  if (!q) return true;
  const digitos = q.replace(/\D/g, '');
  return q.split(/\s+/).every((parte) => sinTildes(a.nombre).includes(parte))
    || (digitos.length >= 3 && (String(a.documento ?? '').includes(digitos) || String(a.telefono ?? '').includes(digitos)));
}

async function cargarAlumnos() {
  const [saldos, alumnos] = await Promise.all([
    supabase.from('saldos').select('*').order('nombre'),
    supabase.from('alumnos').select('id, documento, categoria, finalizado_en, whatsapp_fallo'),
  ]);
  const error = saldos.error ?? alumnos.error;
  if (error) return avisar(explicarError(error), 'error');
  const datos = new Map(alumnos.data.map((a) => [a.id, a]));

  listaAlumnos = saldos.data.map((s) => ({
    ...s,
    id: s.alumno_id,
    documento: datos.get(s.alumno_id)?.documento ?? null,
    categoria: datos.get(s.alumno_id)?.categoria ?? null,
    finalizado_en: datos.get(s.alumno_id)?.finalizado_en ?? null,
    whatsapp_fallo: datos.get(s.alumno_id)?.whatsapp_fallo ?? null,
  }));
  const activos = listaAlumnos.filter((a) => !a.finalizado_en);

  // Agenda: solo alumnos activos
  alumnosAgenda.clear();
  for (const a of activos) alumnosAgenda.set(a.id, a);
  llenarSelect($('#form-turno select[name="alumno_id"]'), activos.map((a) => ({ id: a.id, nombre: a.nombre })), 'Elige un alumno…');
  // Pagos: todos (un finalizado puede pagar lo que debe)
  llenarSelect($('#form-pago select[name="alumno_id"]'), listaAlumnos.map((a) => ({ id: a.id, nombre: a.nombre })), 'Elige un alumno…');

  pintarAlumnos();
}

function pintarAlumnos() {
  const consulta = $('#buscar-alumno').value;
  const filtro = document.querySelector('input[name="filtro-alumnos"]:checked')?.value ?? 'activos';
  const visibles = listaAlumnos.filter((a) => {
    if (filtro === 'activos' && a.finalizado_en) return false;
    if (filtro === 'finalizados' && !a.finalizado_en) return false;
    if (filtro === 'con-saldo' && !(a.saldo > 0)) return false;
    if (filtro === 'sin-whatsapp' && a.telefono && !a.whatsapp_fallo) return false;
    return coincide(a, consulta);
  });
  $('#conteo-alumnos').textContent = `${visibles.length} de ${listaAlumnos.length} alumnos`;

  const tbody = $('#lista-alumnos');
  if (!listaAlumnos.length) return filaVacia(tbody, 8, 'Aún no hay alumnos.');
  if (!visibles.length) return filaVacia(tbody, 8, 'Ningún alumno coincide con la búsqueda.');
  tbody.replaceChildren(...visibles.map((a) => {
    const tr = fila([
      a.nombre, a.documento ?? '—',
      a.categoria ? el('span', a.categoria, 'chip') : '—',
      celdaWhatsapp(a),
      pesos(a.valor_curso), pesos(a.pagado),
    ]);
    tr.children[4].className = tr.children[5].className = 'numero';
    const saldo = el('td', pesos(a.saldo), 'numero');
    if (a.saldo > 0) saldo.classList.add('etiqueta', 'pendiente');
    if (a.origen_saldo === 'facturacion' && a.saldo_actualizado_en) {
      saldo.title = `Según NissiX (actualizado ${fechaHora(a.saldo_actualizado_en)})`;
    }
    tr.append(saldo);

    const accion = el('button', a.finalizado_en ? 'Reactivar' : 'Finalizar', 'secundario pequeno');
    accion.type = 'button';
    accion.title = a.finalizado_en
      ? `Finalizado el ${fecha(a.finalizado_en)}. Vuelve a aparecer en la agenda.`
      : 'Terminó su proceso: deja de aparecer en la agenda';
    accion.addEventListener('click', () => cambiarFinalizado(a, accion));
    const celda = document.createElement('td');
    celda.append(accion);
    tr.append(celda);
    if (a.finalizado_en) tr.classList.add('finalizado');
    return tr;
  }));
}

async function cambiarFinalizado(alumno, boton) {
  boton.disabled = true;
  const finalizado_en = alumno.finalizado_en ? null : new Date().toISOString();
  const { error } = await supabase.from('alumnos').update({ finalizado_en }).eq('id', alumno.id);
  boton.disabled = false;
  if (error) return avisar(explicarError(error), 'error');
  avisar(finalizado_en
    ? `${alumno.nombre} quedó finalizado. Ya no aparece en la agenda (está en “Finalizados”).`
    : `${alumno.nombre} está activo otra vez.`);
  await cargarAlumnos();
}

$('#buscar-alumno').addEventListener('input', pintarAlumnos);
for (const radio of document.querySelectorAll('input[name="filtro-alumnos"]')) radio.addEventListener('change', pintarAlumnos);

// WhatsApp del alumno: el número, o un campo para escribirlo si falta o si WhatsApp avisó
// que a ese número no le llegan los mensajes (p. ej., error 131026: no tiene WhatsApp).
function celdaWhatsapp(a) {
  if (!a.telefono) return editorTelefono(a.id, 'Falta WhatsApp');
  if (!a.whatsapp_fallo) return a.telefono;
  const caja = el('span', '', 'whatsapp-fallo');
  const alerta = el('span', '⚠ No recibe WhatsApp', 'etiqueta error');
  alerta.title = `WhatsApp no entregó el último mensaje a este número (${a.whatsapp_fallo}). `
    + 'Lo más común: el número no tiene WhatsApp. Pide el número correcto y escríbelo aquí.';
  caja.append(el('span', a.telefono, 'tachado'), alerta, editorTelefono(a.id, 'Número correcto'));
  return caja;
}

// Campo para escribir o corregir el WhatsApp. Un número guardado aquí queda fijo: la
// sincronización con NissiX ya no lo cambia (alumnos.telefono_manual).
function editorTelefono(alumnoId, placeholder) {
  const caja = el('span', '', 'editor-telefono');
  const input = document.createElement('input');
  input.inputMode = 'tel';
  input.placeholder = placeholder;
  input.title = 'Celular de Colombia (300 000 0000) o de otro país con su indicativo (+34 612 345 678)';
  input.setAttribute('aria-label', 'WhatsApp del alumno');
  const boton = el('button', 'Guardar', 'secundario');
  boton.type = 'button';
  boton.addEventListener('click', async () => {
    input.value = input.value.replace(/^\s*00/, '+');   // 0034… es lo mismo que +34…
    const telefono = normalizarTelefono(input.value);
    // Válido: celular colombiano (10 dígitos, ya convertido a 57…) o cualquier número con
    // indicativo (11 dígitos o más, con o sin "+"). Uno corto sin indicativo (p. ej., 612 345 678
    // de España) no se sabe de qué país es.
    const sinIndicativo = !input.value.trim().startsWith('+') && telefono.length < 11;
    if (!telefonoValido(telefono) || sinIndicativo) {
      return avisar('Escribe un celular de Colombia (300 000 0000) o, si es de otro país, con su indicativo: +34 612 345 678.', 'error');
    }
    boton.disabled = true;
    const { error } = await supabase.from('alumnos')
      .update({ telefono, telefono_manual: true, whatsapp_fallo: null }).eq('id', alumnoId);
    boton.disabled = false;
    if (error) return avisar(explicarError(error), 'error');
    avisar('WhatsApp guardado. Ya puede recibir recordatorios, y la sincronización con NissiX no lo cambiará.');
    await cargarAlumnos();
  });
  input.addEventListener('keydown', (e) => { if (e.key === 'Enter') boton.click(); });
  caja.append(input, boton);
  return caja;
}

async function cargarInstructores() {
  const { data, error } = await supabase.from('instructores').select('id, nombre').eq('activo', true).order('nombre');
  if (error) return avisar(explicarError(error), 'error');

  llenarSelect($('#form-turno select[name="instructor_id"]'), data, 'Sin instructor');

  // Selector de la agenda semanal: conserva el instructor que se estaba viendo.
  const selector = $('#semana-instructor');
  const antes = selector.value;
  selector.replaceChildren(...data.map(({ id, nombre }) => {
    const opcion = el('option', nombre);
    opcion.value = id;
    return opcion;
  }));
  if (antes && data.some((i) => String(i.id) === antes)) selector.value = antes;

  const lista = $('#lista-instructores');
  lista.replaceChildren(...(data.length ? data.map((i) => el('li', i.nombre)) : [el('li', 'Aún no hay instructores.', 'vacio')]));
}

// Vehículos: se eligen en cada turno (no están fijos a un instructor).
const nombreVehiculo = (v) => (v.descripcion ? `${v.placa} · ${v.descripcion}` : v.placa);

async function cargarVehiculos() {
  const { data, error } = await supabase.from('vehiculos').select('id, placa, descripcion').eq('activo', true).order('placa');
  if (error) return avisar(explicarError(error), 'error');

  const opciones = data.map((v) => ({ id: v.id, nombre: nombreVehiculo(v) }));
  llenarSelect($('#dialogo-vehiculo'), opciones, 'Sin vehículo');
  llenarSelect($('#form-turno select[name="vehiculo_id"]'), opciones, 'Sin vehículo');
  $('#lista-vehiculos').replaceChildren(...(data.length
    ? data.map((v) => el('li', nombreVehiculo(v)))
    : [el('li', 'Aún no hay vehículos.', 'vacio')]));
}

async function cargarTurnos() {
  const desde = new Date();
  desde.setHours(0, 0, 0, 0);
  const hasta = new Date(desde.getTime() + 14 * 24 * 60 * 60 * 1000);

  const { data, error } = await supabase
    .from('turnos')
    .select('id, inicio, tipo, categoria, estado, recordatorio_enviado_en, alumnos(nombre), instructores(nombre)')
    .gte('inicio', desde.toISOString())
    .lt('inicio', hasta.toISOString())
    .order('inicio');
  if (error) return avisar(explicarError(error), 'error');

  const tbody = $('#lista-turnos');
  if (!data.length) return filaVacia(tbody, 7, 'No hay turnos en los próximos 14 días.');

  tbody.replaceChildren(...data.map((t) => {
    const recordatorio = t.recordatorio_enviado_en
      ? el('span', 'Enviado ✓', 'etiqueta ok')
      : el('span', t.estado === 'agendado' ? 'Pendiente' : '—', 'etiqueta pendiente');
    return fila([
      fecha(t.inicio), hora(t.inicio), t.alumnos?.nombre, t.instructores?.nombre ?? 'Sin asignar',
      [TIPOS[t.tipo], t.categoria].filter(Boolean).join(' · '), selectorEstado(t), recordatorio,
    ]);
  }));
}

function selectorEstado(turno) {
  const select = document.createElement('select');
  select.setAttribute('aria-label', 'Estado del turno');
  for (const [valor, texto] of [['agendado', 'Agendado'], ['asistio', 'Asistió'], ['falto', 'Faltó'], ['cancelado', 'Cancelado']]) {
    const opcion = el('option', texto);
    opcion.value = valor;
    opcion.selected = valor === turno.estado;
    select.append(opcion);
  }
  select.addEventListener('change', async () => {
    const { error } = await supabase.from('turnos').update({ estado: select.value }).eq('id', turno.id);
    if (error) {
      avisar(explicarError(error), 'error');
      select.value = turno.estado;
    } else {
      turno.estado = select.value;
      avisar('Estado actualizado.');
    }
  });
  return select;
}

// ─────────────────────────────── Agenda semanal ───────────────────────────────
// Como el Excel de agendamiento: un instructor a la vez, lunes a domingo en columnas
// y horas en filas. Todo se calcula en hora de Colombia, sin importar la del computador.

const HORA_INICIO = 6;  // primera fila: 6:00 a. m.
const HORA_FIN = 20;    // última fila termina a las 8:00 p. m.
const DIAS = ['Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado', 'Domingo'];

// Fechas como texto "AAAA-MM-DD" (día de Colombia); se suman días en UTC para no cruzar zonas.
const hoyColombia = () => new Intl.DateTimeFormat('en-CA', { timeZone: ZONA }).format(new Date());
const sumarDias = (dia, n) => {
  const d = new Date(`${dia}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};
const lunesDe = (dia) => sumarDias(dia, -((new Date(`${dia}T12:00:00Z`).getUTCDay() + 6) % 7));
const instante = (dia, horaDecimal) => {
  const h = String(Math.floor(horaDecimal)).padStart(2, '0');
  const m = String(Math.round((horaDecimal % 1) * 60)).padStart(2, '0');
  return new Date(`${dia}T${h}:${m}:00${OFFSET_COLOMBIA}`);
};
// Día y hora (decimal) en Colombia de un instante ISO
function enColombia(iso) {
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-CA', {
    timeZone: ZONA, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(new Date(iso)).map((x) => [x.type, x.value]));
  return { dia: `${p.year}-${p.month}-${p.day}`, hora: Number(p.hour) + Number(p.minute) / 60 };
}
const etiquetaHora = (h) => new Intl.DateTimeFormat('es-CO', { hour: 'numeric', minute: '2-digit', timeZone: 'UTC' })
  .format(new Date(Date.UTC(2000, 0, 1, Math.floor(h), Math.round((h % 1) * 60))));

// "2:00" / "10:30" (sin a. m./p. m.), para que quepa dentro del bloque del turno
const horaCorta = (h) => `${((Math.floor(h) + 11) % 12) + 1}:${String(Math.round((h % 1) * 60)).padStart(2, '0')}`;

let semanaLunes = lunesDe(hoyColombia());

async function cargarSemana() {
  const contenedor = $('#semana');
  const instructorId = Number($('#semana-instructor').value);
  const domingo = sumarDias(semanaLunes, 6);
  $('#semana-titulo').textContent =
    `Semana del ${fecha(instante(semanaLunes, 12).toISOString())} al ${fecha(instante(domingo, 12).toISOString())}`;
  if (!instructorId) {
    contenedor.replaceChildren(el('p', 'Agrega un instructor en la pestaña Instructores.', 'vacio'));
    return;
  }

  const { data, error } = await supabase
    .from('turnos')
    .select('id, inicio, fin, tipo, categoria, estado, alumnos(nombre, documento), vehiculos(placa)')
    .eq('instructor_id', instructorId)
    .neq('estado', 'cancelado')
    .gte('inicio', instante(semanaLunes, 0).toISOString())
    .lt('inicio', instante(sumarDias(semanaLunes, 7), 0).toISOString())
    .order('inicio');
  if (error) return avisar(explicarError(error), 'error');

  const celdas = [el('div', '', 'semana-esquina')];
  const hoy = hoyColombia();
  DIAS.forEach((nombre, i) => {
    const dia = sumarDias(semanaLunes, i);
    const cabecera = el('div', '', 'semana-dia' + (dia === hoy ? ' hoy' : ''));
    cabecera.append(el('strong', nombre), el('span', fecha(instante(dia, 12).toISOString()).replace(/^\S+\s/, '')));
    cabecera.style.gridColumn = String(i + 2);
    celdas.push(cabecera);
  });

  const ahora = new Date();
  for (let h = HORA_INICIO; h < HORA_FIN; h++) {
    const fila = h - HORA_INICIO + 2;
    const etiqueta = el('div', etiquetaHora(h), 'semana-hora');
    etiqueta.style.gridRow = String(fila);
    celdas.push(etiqueta);
    DIAS.forEach((_, i) => {
      const dia = sumarDias(semanaLunes, i);
      const libre = el('button', '', 'semana-libre');
      libre.type = 'button';
      libre.style.gridRow = String(fila);
      libre.style.gridColumn = String(i + 2);
      libre.setAttribute('aria-label', `Agendar ${DIAS[i]} ${etiquetaHora(h)}`);
      if (instante(dia, h + 1) <= ahora) libre.disabled = true;
      else libre.addEventListener('click', () => abrirDialogoNuevo(dia, h));
      celdas.push(libre);
    });
  }

  for (const t of data) {
    const ini = enColombia(t.inicio);
    const fin = enColombia(t.fin);
    const col = DIAS.findIndex((_, i) => sumarDias(semanaLunes, i) === ini.dia);
    if (col < 0) continue;
    const desde = Math.max(ini.hora, HORA_INICIO);
    const hasta = Math.min(fin.dia === ini.dia ? fin.hora : HORA_FIN, HORA_FIN);
    const bloque = el('button', '', `semana-turno ${t.tipo} ${t.estado}`);
    bloque.type = 'button';
    bloque.style.gridColumn = String(col + 2);
    bloque.style.gridRow = `${Math.floor(desde) - HORA_INICIO + 2} / ${Math.ceil(hasta) - HORA_INICIO + 2}`;
    const estado = { asistio: ' ✓', falto: ' ✗' }[t.estado] ?? '';
    bloque.append(
      el('span', `${horaCorta(ini.hora)} – ${horaCorta(fin.hora)}${estado}`, 'semana-turno-hora'),
      el('strong', t.alumnos?.nombre ?? '—'),
      el('span', [t.categoria, TIPOS[t.tipo], t.vehiculos?.placa].filter(Boolean).join(' · ')),
    );
    bloque.addEventListener('click', () => abrirDialogoExistente(t));
    celdas.push(bloque);
  }

  contenedor.style.gridTemplateRows = `auto repeat(${HORA_FIN - HORA_INICIO}, 3.4rem)`;
  contenedor.replaceChildren(...celdas);
}

$('#semana-instructor').addEventListener('change', cargarSemana);
$('#semana-anterior').addEventListener('click', () => { semanaLunes = sumarDias(semanaLunes, -7); cargarSemana(); });
$('#semana-siguiente').addEventListener('click', () => { semanaLunes = sumarDias(semanaLunes, 7); cargarSemana(); });
$('#semana-hoy').addEventListener('click', () => { semanaLunes = lunesDe(hoyColombia()); cargarSemana(); });

// ── Ventana para agendar un turno nuevo o ver uno existente ──
const dialogo = $('#dialogo-turno');
let enDialogo = null; // { dia, hora } si es nuevo · { turno } si existe

function abrirDialogoNuevo(dia, hora) {
  enDialogo = { dia, hora };
  const instructor = $('#semana-instructor').selectedOptions[0]?.textContent ?? '';
  $('#dialogo-titulo').textContent = 'Agendar turno';
  $('#dialogo-cuando').textContent = `${fecha(instante(dia, 12).toISOString())} · ${etiquetaHora(hora)} · ${instructor}`;
  $('#dialogo-nuevo').hidden = false;
  $('#dialogo-existente').hidden = true;
  elegirAlumno(null);
  $('#dialogo-duracion').value = '120';
  $('#dialogo-tipo').value = 'practica';
  $('#dialogo-vehiculo').value = '';
  // Repetir: por defecto solo el día donde se hizo clic
  const columna = DIAS.findIndex((_, i) => sumarDias(lunesDe(dia), i) === dia);
  for (const caja of document.querySelectorAll('#dialogo-dias input')) caja.checked = Number(caja.value) === columna;
  $('#dialogo-semanas').value = '1';
  actualizarResumen();
  $('#dialogo-guardar').textContent = 'Agendar';
  $('#dialogo-error').textContent = '';
  dialogo.showModal();
  $('#dialogo-alumno').focus();
}

// Turnos que se van a crear: días marcados × semanas, a la misma hora; nunca en el pasado.
function turnosDeLaSerie() {
  const lunes = lunesDe(enDialogo.dia);
  const dias = [...document.querySelectorAll('#dialogo-dias input:checked')].map((c) => Number(c.value));
  const semanas = Number($('#dialogo-semanas').value);
  const minutos = Number($('#dialogo-duracion').value);
  const ahora = new Date();
  const lista = [];
  for (let s = 0; s < semanas; s++) {
    for (const d of dias) {
      const dia = sumarDias(lunes, s * 7 + d);
      const inicio = instante(dia, enDialogo.hora);
      if (inicio <= ahora) continue;
      lista.push({ dia, inicio, fin: new Date(inicio.getTime() + minutos * 60 * 1000) });
    }
  }
  return lista.sort((a, b) => a.inicio - b.inicio);
}

function actualizarResumen() {
  if (!enDialogo || enDialogo.turno) return;
  const serie = turnosDeLaSerie();
  const hasta = serie.length ? enColombia(serie[0].fin.toISOString()).hora : enDialogo.hora;
  const franja = `${etiquetaHora(enDialogo.hora)} a ${etiquetaHora(hasta)}`;
  $('#dialogo-resumen').textContent = !serie.length
    ? 'Marca al menos un día que no haya pasado.'
    : serie.length === 1
      ? `Se agendará 1 turno de ${franja}.`
      : `Se agendarán ${serie.length} turnos de ${franja}: ${serie.map((t) => fecha(t.inicio.toISOString())).join(', ')}. ` +
        'El alumno recibe una sola confirmación (la del primero) y un recordatorio 3 horas antes de cada clase.';
  $('#dialogo-guardar').textContent = serie.length > 1 ? `Agendar ${serie.length} turnos` : 'Agendar';
}
for (const control of ['#dialogo-dias', '#dialogo-semanas', '#dialogo-duracion']) {
  $(control).addEventListener('change', actualizarResumen);
}

// Antes de guardar la serie: ¿alguna fecha choca con otro turno del instructor, del alumno o del vehículo?
async function chequearChoques(serie, alumnoId, instructorId, vehiculoId) {
  const quienes = [`instructor_id.eq.${instructorId}`, `alumno_id.eq.${alumnoId}`];
  if (vehiculoId) quienes.push(`vehiculo_id.eq.${vehiculoId}`);
  const { data, error } = await supabase
    .from('turnos')
    .select('inicio, fin, instructor_id, alumno_id, vehiculo_id')
    .neq('estado', 'cancelado')
    .lt('inicio', serie[serie.length - 1].fin.toISOString())
    .gt('fin', serie[0].inicio.toISOString())
    .or(quienes.join(','));
  if (error) return { error };
  const choques = [];
  for (const t of serie) {
    const otro = data.find((o) => new Date(o.inicio) < t.fin && t.inicio < new Date(o.fin));
    if (!otro) continue;
    const motivo = otro.instructor_id === instructorId ? 'instructor ocupado'
      : otro.alumno_id === alumnoId ? 'el alumno ya tiene clase' : 'vehículo ocupado';
    choques.push(`${fecha(t.inicio.toISOString())} (${motivo})`);
  }
  return { choques };
}

function abrirDialogoExistente(turno) {
  enDialogo = { turno };
  const ini = enColombia(turno.inicio);
  const fin = enColombia(turno.fin);
  $('#dialogo-titulo').textContent = turno.alumnos?.nombre ?? 'Turno';
  $('#dialogo-cuando').textContent =
    `${fecha(turno.inicio)} · ${etiquetaHora(ini.hora)} a ${etiquetaHora(fin.hora)}`;
  $('#dialogo-detalle').textContent = [
    turno.alumnos?.documento ? `CC ${turno.alumnos.documento}` : null,
    turno.categoria ? `Categoría ${turno.categoria}` : null,
    TIPOS[turno.tipo],
    turno.vehiculos?.placa ? `Vehículo ${turno.vehiculos.placa}` : 'Sin vehículo',
  ].filter(Boolean).join(' · ');
  $('#dialogo-nuevo').hidden = true;
  $('#dialogo-existente').hidden = false;
  $('#dialogo-estado').value = turno.estado;
  $('#dialogo-guardar').textContent = 'Guardar';
  $('#dialogo-error').textContent = '';
  dialogo.showModal();
}

// ── Buscador de alumno con sugerencias propias (la lista del navegador no se
//    actualizaba mientras estaba abierta). Filtra al escribir, sin importar tildes. ──
let alumnoElegido = null;
let sugerenciaActiva = -1;

function elegirAlumno(alumno) {
  alumnoElegido = alumno;
  $('#dialogo-alumno').value = alumno ? etiquetaAlumno(alumno) : '';
  llenarCategorias($('#dialogo-categoria'), alumno?.categoria);
  cerrarSugerencias();
}

function cerrarSugerencias() {
  $('#dialogo-sugerencias').hidden = true;
  $('#dialogo-alumno').setAttribute('aria-expanded', 'false');
  $('#dialogo-alumno').removeAttribute('aria-activedescendant');
  sugerenciaActiva = -1;
}

function mostrarSugerencias() {
  const consulta = $('#dialogo-alumno').value;
  const lista = $('#dialogo-sugerencias');
  const resultados = [...alumnosAgenda.values()].filter((a) => coincide(a, consulta)).slice(0, 8);
  sugerenciaActiva = resultados.length ? 0 : -1;
  lista.replaceChildren(...(resultados.length ? resultados.map((a, i) => {
    const li = el('li', '');
    li.id = `sugerencia-${a.id}`;
    li.setAttribute('role', 'option');
    li.setAttribute('aria-selected', String(i === 0));
    li.append(document.createTextNode(a.nombre), el('span', [a.categoria, a.documento ? `CC ${a.documento}` : null].filter(Boolean).join(' · ')));
    // mousedown (no click) para que el campo no pierda el foco antes de elegir
    li.addEventListener('mousedown', (e) => { e.preventDefault(); elegirAlumno(a); });
    return li;
  }) : [el('li', 'Ningún alumno activo coincide', 'sin-resultados')]));
  lista.hidden = false;
  $('#dialogo-alumno').setAttribute('aria-expanded', 'true');
  marcarSugerencia();
}

function marcarSugerencia() {
  const items = [...$('#dialogo-sugerencias').querySelectorAll('[role="option"]')];
  items.forEach((li, i) => li.setAttribute('aria-selected', String(i === sugerenciaActiva)));
  const activa = items[sugerenciaActiva];
  if (activa) {
    $('#dialogo-alumno').setAttribute('aria-activedescendant', activa.id);
    activa.scrollIntoView({ block: 'nearest' });
  }
}

$('#dialogo-alumno').addEventListener('input', () => {
  // Si cambia el texto, ya no vale el alumno elegido antes
  if (alumnoElegido && $('#dialogo-alumno').value !== etiquetaAlumno(alumnoElegido)) {
    alumnoElegido = null;
    llenarCategorias($('#dialogo-categoria'), '');
  }
  mostrarSugerencias();
});
$('#dialogo-alumno').addEventListener('focus', () => { if (!alumnoElegido) mostrarSugerencias(); });
$('#dialogo-alumno').addEventListener('blur', cerrarSugerencias);
$('#dialogo-alumno').addEventListener('keydown', (e) => {
  const items = [...$('#dialogo-sugerencias').querySelectorAll('[role="option"]')];
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault();
    if ($('#dialogo-sugerencias').hidden) return mostrarSugerencias();
    if (!items.length) return;
    sugerenciaActiva = (sugerenciaActiva + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
    marcarSugerencia();
  } else if (e.key === 'Enter') {
    e.preventDefault(); // no enviar el formulario
    const id = items[sugerenciaActiva]?.id.replace('sugerencia-', '');
    if (id) elegirAlumno(alumnosAgenda.get(Number(id)));
  } else if (e.key === 'Escape' && !$('#dialogo-sugerencias').hidden) {
    e.preventDefault(); // cierra la lista, no la ventana
    cerrarSugerencias();
  }
});
$('#dialogo-cerrar').addEventListener('click', () => dialogo.close());

$('#dialogo-guardar').addEventListener('click', async () => {
  const boton = $('#dialogo-guardar');
  const mostrarError = (texto) => { $('#dialogo-error').textContent = texto; };
  boton.disabled = true;
  try {
    if (enDialogo?.turno) {
      const { error } = await supabase.from('turnos').update({ estado: $('#dialogo-estado').value }).eq('id', enDialogo.turno.id);
      if (error) return mostrarError(explicarError(error));
      avisar('Turno actualizado.');
    } else {
      const alumno = alumnoElegido;
      if (!alumno) return mostrarError('Elige el alumno de la lista: escribe su nombre, cédula o teléfono y selecciónalo.');
      const categoria = $('#dialogo-categoria').value;
      if (categoriasDe(alumno.categoria).length && !categoria) return mostrarError('Elige la categoría de esta práctica.');
      const serie = turnosDeLaSerie();
      if (!serie.length) return mostrarError('Marca al menos un día que no haya pasado.');
      const instructorId = Number($('#semana-instructor').value);
      const vehiculoId = $('#dialogo-vehiculo').value ? Number($('#dialogo-vehiculo').value) : null;

      const revision = await chequearChoques(serie, alumno.id, instructorId, vehiculoId);
      if (revision.error) return mostrarError(explicarError(revision.error));
      if (revision.choques.length) {
        return mostrarError(`No se agendó nada. Estas fechas chocan: ${revision.choques.join(', ')}. Desmárcalas o cambia la hora.`);
      }

      // Todo o nada: se guardan en una sola operación.
      const { error } = await supabase.from('turnos').insert(serie.map((t) => ({
        alumno_id: alumno.id,
        instructor_id: instructorId,
        inicio: t.inicio.toISOString(),
        fin: t.fin.toISOString(),
        tipo: $('#dialogo-tipo').value,
        categoria: categoria || null,
        vehiculo_id: vehiculoId,
      })));
      if (error) return mostrarError(explicarError(error));
      const cuando = esHorarioDeDescanso()
        ? 'a las 6 a. m. (o ya mismo con "Enviar ahora", arriba en la Agenda)'
        : 'en unos minutos';
      avisar(serie.length === 1
        ? `Turno agendado. El alumno recibirá la confirmación por WhatsApp ${cuando}.`
        : `${serie.length} turnos agendados. El alumno recibirá una confirmación por WhatsApp ${cuando} y un recordatorio 3 horas antes de cada clase.`);
    }
    dialogo.close();
    await Promise.all([cargarSemana(), cargarTurnos(), cargarAvisosEnEspera()]);
  } finally {
    boton.disabled = false;
  }
});

async function cargarPagos() {
  const { data, error } = await supabase
    .from('pagos')
    .select('fecha, valor, medio, nota, alumnos(nombre)')
    .order('creado_en', { ascending: false })
    .limit(30);
  if (error) return avisar(explicarError(error), 'error');

  const tbody = $('#lista-pagos');
  if (!data.length) return filaVacia(tbody, 5, 'Aún no hay pagos.');
  tbody.replaceChildren(...data.map((p) => {
    const tr = fila([p.fecha, p.alumnos?.nombre, pesos(p.valor), p.medio, p.nota]);
    tr.children[2].className = 'numero';
    return tr;
  }));
}

async function cargarMensajes() {
  const { data, error } = await supabase
    .from('mensajes')
    .select('enviado_en, tipo, ok, error, entrega, entrega_error, alumnos(nombre)')
    .order('enviado_en', { ascending: false })
    .limit(50);
  if (error) return avisar(explicarError(error), 'error');

  const tbody = $('#lista-mensajes');
  if (!data.length) return filaVacia(tbody, 4, 'Todavía no se ha enviado ningún mensaje.');
  const tipos = {
    confirmacion_turno: 'Confirmación de turno (al agendar)',
    recordatorio_dia_anterior: 'Recordatorio (día anterior; ya no se usa)',
    recordatorio_3h: 'Recordatorio (3 horas antes)',
    recordatorio_turno: 'Recordatorio de turno',
    recordatorio_saldo: 'Recordatorio de saldo',
  };
  tbody.replaceChildren(...data.map((m) => {
    // ok = Meta lo aceptó; entrega = lo que WhatsApp avisó después (enviado, entregado, leído o fallido)
    const estados = {
      leido: ['Leído ✓✓', 'etiqueta ok'],
      entregado: ['Entregado ✓', 'etiqueta ok'],
      fallido: ['No entregado ✗', 'etiqueta error'],
    };
    const [texto, clase] = !m.ok ? ['Falló', 'etiqueta error'] : (estados[m.entrega] ?? ['Enviado', 'etiqueta']);
    const resultado = el('span', texto, clase);
    if (!m.ok && m.error) resultado.title = m.error;
    if (m.entrega === 'fallido') {
      resultado.title = `${m.entrega_error ?? ''}: normalmente el número no tiene WhatsApp. Corrígelo en Alumnos y saldos.`;
    }
    return fila([fechaHora(m.enviado_en), m.alumnos?.nombre ?? '—', tipos[m.tipo], resultado]);
  }));
}

// n8n trae de NissiX los alumnos de los últimos 90 días: los domingos, a las 11:30 a. m. de los
// días de cobro y cuando alguien pulsa "Actualizar saldos desde NissiX".
async function cargarSincronizaciones() {
  const { data, error } = await supabase
    .from('sincronizaciones')
    .select('*')
    .order('creado_en', { ascending: false })
    .limit(10);
  if (error) return avisar(explicarError(error), 'error');

  pintarUltimaSincronizacion(data.find((s) => s.ok));
  const tbody = $('#lista-sincronizaciones');
  if (!data.length) return filaVacia(tbody, 5, 'Todavía no se ha sincronizado con NissiX.');
  tbody.replaceChildren(...data.map((s) => {
    const resultado = s.ok ? el('span', 'Correcta ✓', 'etiqueta ok') : el('span', 'Falló', 'etiqueta error');
    const cifras = s.ok
      ? `${s.facturas ?? 0} facturas · ${s.creados ?? 0} nuevos · ${s.actualizados ?? 0} actualizados · ${s.sin_telefono ?? 0} sin WhatsApp`
      : '—';
    return fila([fechaHora(s.creado_en), s.motivo ?? 'domingo', resultado, cifras, s.detalle ?? '']);
  }));
}

function pintarUltimaSincronizacion(s) {
  const texto = s ? `Última actualización desde NissiX: ${fechaHora(s.creado_en)}` : '';
  document.querySelectorAll('.ultima-nissix').forEach((p) => { p.textContent = texto; });
}

async function ultimaSincronizacion() {
  const { data } = await supabase.from('sincronizaciones')
    .select('id, ok, creados, actualizados, detalle').order('id', { ascending: false }).limit(1);
  return data?.[0] ?? null;
}

// El botón llama al webhook de n8n (mismo dominio del panel), que verifica la sesión y responde
// de una vez; la sincronización tarda 1–2 minutos, así que se espera a que aparezca su registro.
async function sincronizarNissixAhora() {
  const botones = document.querySelectorAll('.boton-nissix');
  const { data: { session } } = await supabase.auth.getSession();
  if (!session) return avisar('Tu sesión venció. Vuelve a entrar al panel.', 'error');

  const antes = await ultimaSincronizacion();
  botones.forEach((b) => { b.disabled = true; b.textContent = 'Actualizando desde NissiX… (1–2 min)'; });
  const restaurar = () => botones.forEach((b) => { b.disabled = false; b.textContent = 'Actualizar saldos desde NissiX'; });

  try {
    const r = await fetch('/webhook/nissix-ahora', { method: 'POST', headers: { Authorization: `Bearer ${session.access_token}` } });
    if (!r.ok) throw new Error(r.status === 401 ? 'tu sesión venció, vuelve a entrar al panel.' : `el servidor respondió ${r.status}.`);
  } catch (e) {
    restaurar();
    return avisar(`No se pudo iniciar la actualización: ${e.message}`, 'error');
  }

  const limite = Date.now() + 5 * 60 * 1000;
  while (Date.now() < limite) {
    await new Promise((listo) => setTimeout(listo, 5000));
    const s = await ultimaSincronizacion();
    if (!s || s.id === antes?.id) continue;
    restaurar();
    await Promise.all([cargarAlumnos(), cargarSincronizaciones()]);
    return s.ok
      ? avisar(`Saldos actualizados desde NissiX: ${s.creados ?? 0} nuevos, ${s.actualizados ?? 0} actualizados.`)
      : avisar(`NissiX no respondió bien: ${s.detalle ?? 'error desconocido'}`, 'error');
  }
  restaurar();
  avisar('La actualización está tardando más de lo normal. Revisa en unos minutos la sección Importar y NissiX.', 'error');
}

document.querySelectorAll('.boton-nissix').forEach((b) => b.addEventListener('click', sincronizarNissixAhora));

// ─────────────────────────────── Info del agente ───────────────────────────────

async function cargarFaq() {
  const { data, error } = await supabase.from('faq').select('*').order('tema').order('id');
  if (error) return avisar(explicarError(error), 'error');

  const lista = $('#lista-faq');
  if (!data.length) {
    return lista.replaceChildren(el('p', 'Todavía no hay información. Empieza por precios, requisitos, horarios y medios de pago.', 'vacio'));
  }
  lista.replaceChildren(...data.map((f) => {
    const item = el('article', '', 'faq' + (f.activo ? '' : ' inactiva'));
    const cabecera = el('div', '', 'faq-cabecera');
    cabecera.append(el('span', f.tema, 'etiqueta'), el('strong', f.pregunta));
    const acciones = el('div', '', 'faq-acciones');
    const alternar = el('button', f.activo ? 'Ocultar al agente' : 'Mostrar al agente', 'secundario');
    alternar.type = 'button';
    alternar.addEventListener('click', async () => {
      const { error } = await supabase.from('faq')
        .update({ activo: !f.activo, actualizado_en: new Date().toISOString() }).eq('id', f.id);
      if (error) return avisar(explicarError(error), 'error');
      await cargarFaq();
    });
    const borrar = el('button', 'Borrar', 'secundario');
    borrar.type = 'button';
    borrar.addEventListener('click', async () => {
      if (!confirm(`¿Borrar "${f.pregunta}"? El agente dejará de saberlo.`)) return;
      const { error } = await supabase.from('faq').delete().eq('id', f.id);
      if (error) return avisar(explicarError(error), 'error');
      await cargarFaq();
    });
    acciones.append(alternar, borrar);
    item.append(cabecera, el('p', f.respuesta), acciones);
    return item;
  }));
}

// ─────────────────────────────── Atención humana ───────────────────────────────

async function cargarHumano() {
  const { data, error } = await supabase
    .from('solicitudes_humano').select('*').eq('estado', 'pendiente').order('creado_en', { ascending: false });
  if (error) return avisar(explicarError(error), 'error');

  const contador = $('#contador-humano');
  contador.textContent = data.length;
  contador.hidden = data.length === 0;

  const tbody = $('#lista-humano');
  if (!data.length) return filaVacia(tbody, 6, 'No hay solicitudes pendientes.');
  tbody.replaceChildren(...data.map((s) => {
    // Abre el chat de esa persona en el WhatsApp de quien use el panel
    const enlace = el('a', `+${s.telefono}`);
    enlace.href = `https://wa.me/${s.telefono}`;
    enlace.target = '_blank';
    enlace.rel = 'noopener';
    const atender = el('button', 'Marcar atendida', 'secundario');
    atender.type = 'button';
    atender.addEventListener('click', async () => {
      const { error } = await supabase.from('solicitudes_humano')
        .update({ estado: 'atendida', atendida_en: new Date().toISOString() }).eq('id', s.id);
      if (error) return avisar(explicarError(error), 'error');
      avisar('Solicitud marcada como atendida.');
      await cargarHumano();
    });
    const tr = fila([fechaHora(s.creado_en), s.nombre ?? '—', enlace, s.motivo, s.resumen ?? '', atender]);
    tr.children[4].className = 'texto-largo';
    return tr;
  }));
}

// ─────────────────────────────── Matrículas por WhatsApp ───────────────────────────────

const ESTADOS_MATRICULA = {
  pendiente_pago: ['Esperando pago', 'pendiente'],
  comprobante_recibido: ['Comprobante recibido: verificar', 'error'],
  confirmada: ['Confirmada ✓', 'ok'],
  rechazada: ['Rechazada', ''],
};

async function cargarMatriculas() {
  const { data, error } = await supabase
    .from('matriculas').select('*').order('creado_en', { ascending: false }).limit(60);
  if (error) return avisar(explicarError(error), 'error');

  const porVerificar = data.filter((m) => m.estado === 'comprobante_recibido').length;
  const contador = $('#contador-matriculas');
  contador.textContent = porVerificar;
  contador.hidden = porVerificar === 0;

  const tbody = $('#lista-matriculas');
  if (!data.length) return filaVacia(tbody, 8, 'Todavía no hay matrículas por WhatsApp.');
  tbody.replaceChildren(...data.map((m) => {
    const enlace = el('a', `+${m.telefono}`);
    enlace.href = `https://wa.me/${m.telefono}`;
    enlace.target = '_blank';
    enlace.rel = 'noopener';
    const [textoEstado, claseEstado] = ESTADOS_MATRICULA[m.estado];
    const acciones = el('span', '', 'faq-acciones');
    if (m.estado === 'pendiente_pago' || m.estado === 'comprobante_recibido') {
      const confirmar = el('button', 'Confirmar pago');
      confirmar.type = 'button';
      confirmar.addEventListener('click', async () => {
        if (!confirm(`¿Ya verificaste en el banco la transferencia de ${pesos(m.cuota_inicial ?? 0)} de ${m.nombre}?`)) return;
        confirmar.disabled = true;
        const { data: mensaje, error } = await supabase.rpc('confirmar_matricula', { p_matricula_id: m.id });
        if (error) { confirmar.disabled = false; return avisar(explicarError(error), 'error'); }
        avisar(mensaje);
        await Promise.all([cargarMatriculas(), cargarAlumnos(), cargarPagos()]);
      });
      const rechazar = el('button', 'Rechazar', 'secundario');
      rechazar.type = 'button';
      rechazar.addEventListener('click', async () => {
        if (!confirm(`¿Rechazar la matrícula de ${m.nombre}? (por ejemplo, si el pago no llegó)`)) return;
        const { error } = await supabase.from('matriculas')
          .update({ estado: 'rechazada', revisada_en: new Date().toISOString() }).eq('id', m.id);
        if (error) return avisar(explicarError(error), 'error');
        avisar('Matrícula rechazada. Escríbele al alumno para explicarle el motivo.');
        await cargarMatriculas();
      });
      acciones.append(confirmar, rechazar);
    }
    const tr = fila([
      fechaHora(m.creado_en), m.nombre, m.cedula, m.categoria,
      m.cuota_inicial == null ? '—' : pesos(m.cuota_inicial), enlace,
      el('span', textoEstado, `etiqueta ${claseEstado}`), acciones,
    ]);
    tr.children[4].className = 'numero';
    return tr;
  }));
}

// ─────────────────────────────── Formularios ───────────────────────────────

alEnviar($('#form-faq'), async (d, form) => {
  const { error } = await supabase.from('faq').insert({
    tema: d.tema.trim(), pregunta: d.pregunta.trim(), respuesta: d.respuesta.trim(),
  });
  if (error) return error;
  form.reset();
  avisar('Guardado. El agente ya lo sabe desde el próximo mensaje.');
  await cargarFaq();
});

alEnviar($('#form-turno'), async (d, form) => {
  const inicio = new Date(`${d.fecha}T${d.hora}:00${OFFSET_COLOMBIA}`);
  const fin = new Date(inicio.getTime() + Number(d.duracion) * 60 * 1000);
  if (inicio < new Date()) return { message: 'No se puede agendar en una fecha u hora que ya pasó.' };

  const { error } = await supabase.from('turnos').insert({
    alumno_id: Number(d.alumno_id),
    instructor_id: d.instructor_id ? Number(d.instructor_id) : null,
    inicio: inicio.toISOString(),
    fin: fin.toISOString(),
    tipo: d.tipo,
    categoria: d.categoria || null,
    vehiculo_id: d.vehiculo_id ? Number(d.vehiculo_id) : null,
  });
  if (error) return error;
  form.reset();
  llenarCategorias(form.querySelector('select[name="categoria"]'), '');
  await cargarSemana();
  avisar('Turno agendado. El alumno recibirá la confirmación por WhatsApp en unos minutos y un recordatorio 3 horas antes.');
  await cargarTurnos();
});

alEnviar($('#form-alumno'), async (d, form) => {
  const telefono = normalizarTelefono(d.telefono);
  if (!telefonoValido(telefono)) return { message: 'Escribe un número de WhatsApp válido, por ejemplo 300 000 0000.' };

  const { error } = await supabase.from('alumnos').insert({
    nombre: d.nombre.trim(),
    documento: d.documento.replace(/[\s.]/g, '') || null,
    telefono,
    categoria: d.categoria,
    valor_curso: Number(d.valor_curso),
    autoriza_datos: d.autoriza_datos === 'on',
  });
  if (error) return error;
  form.reset();
  avisar(d.autoriza_datos === 'on'
    ? 'Alumno guardado.'
    : 'Alumno guardado. Ojo: sin autorización de datos NO recibirá recordatorios.');
  await cargarAlumnos();
});

alEnviar($('#form-pago'), async (d, form) => {
  const { error } = await supabase.from('pagos').insert({
    alumno_id: Number(d.alumno_id),
    valor: Number(d.valor),
    medio: d.medio,
    nota: d.nota.trim() || null,
  });
  if (error) return error;
  form.reset();
  avisar('Pago registrado. El saldo ya está actualizado.');
  await Promise.all([cargarPagos(), cargarAlumnos()]);
});

// ─────────────────────────────── Importar Excel ───────────────────────────────

let importacion = null; // alumnos listos para importar, tras la vista previa

$('#archivo-excel').addEventListener('change', async (evento) => {
  const archivo = evento.target.files[0];
  $('#vista-previa').hidden = true;
  importacion = null;
  if (!archivo) return;

  try {
    // SheetJS (lector de Excel) se descarga solo cuando se usa esta pestaña.
    const XLSX = await import('https://cdn.sheetjs.com/xlsx-0.20.3/package/xlsx.mjs');
    const libro = XLSX.read(await archivo.arrayBuffer());
    const hoja = libro.Sheets[libro.SheetNames[0]];
    const filas = XLSX.utils.sheet_to_json(hoja, { defval: '', raw: true });

    const { data: guardados, error } = await supabase.from('alumnos').select('documento, telefono').not('documento', 'is', null);
    if (error) return avisar(explicarError(error), 'error');
    const existentes = new Map(guardados.map((a) => [a.documento, a.telefono]));

    const resultado = prepararImportacion(filas, existentes);
    if (resultado.error) return avisar(resultado.error, 'error');
    mostrarVistaPrevia(resultado.alumnos);
  } catch (e) {
    avisar(`No se pudo leer el archivo: ${e.message}`, 'error');
  }
});

function mostrarVistaPrevia(alumnos) {
  importacion = alumnos;
  const conError = alumnos.filter((a) => a.errores.length).length;
  const actualizan = alumnos.filter((a) => a.existe).length;
  const sinWhatsapp = alumnos.filter((a) => !a.telefonoFinal).length;
  const saldoTotal = alumnos.reduce((suma, a) => suma + (a.saldo ?? 0), 0);

  $('#resumen-importacion').textContent =
    `${alumnos.length} alumnos · ${alumnos.length - actualizan} nuevos · ${actualizan} se actualizan · ` +
    `saldo total ${pesos(saldoTotal)} · ${sinWhatsapp} sin WhatsApp` +
    (conError ? ` · ${conError} con errores (no se importan)` : '');

  $('#lista-importacion').replaceChildren(...alumnos.map((a) => {
    const resultado = a.errores.length
      ? el('span', `✗ ${a.errores.join('; ')}`, 'etiqueta error')
      : el('span', (a.existe ? 'Se actualiza' : 'Nuevo') + (a.avisos.length ? ` · ⚠ ${a.avisos.join('; ')}` : ''),
        a.avisos.length ? 'etiqueta pendiente' : 'etiqueta ok');
    const tr = fila([
      a.documento, a.nombre, a.categoria ?? '—',
      a.valor === null ? '—' : pesos(a.valor), pesos(a.saldo ?? 0),
      a.telefonoFinal ?? '—', resultado,
    ]);
    tr.children[3].className = tr.children[4].className = 'numero';
    return tr;
  }));

  $('#confirmar-importacion').textContent = `Importar ${alumnos.length - conError} alumnos`;
  $('#confirmar-importacion').disabled = alumnos.length === conError;
  $('#vista-previa').hidden = false;
}

$('#confirmar-importacion').addEventListener('click', async () => {
  if (!importacion) return;
  const boton = $('#confirmar-importacion');
  boton.disabled = true;
  const filas = importacion
    .filter((a) => !a.errores.length)
    .map(({ documento, nombre, categoria, valor, saldo, telefono }) => ({ documento, nombre, categoria, valor, saldo, telefono }));

  const { data, error } = await supabase.rpc('importar_alumnos', { filas, autorizan: $('#autorizan').checked });
  boton.disabled = false;
  if (error) return avisar(explicarError(error), 'error');

  const { creados, actualizados, sin_telefono } = data[0];
  avisar(`Importación lista: ${creados} nuevos, ${actualizados} actualizados.` +
    (sin_telefono ? ` ${sin_telefono} no tienen WhatsApp: agrégalo en "Alumnos y saldos".` : ''));
  $('#vista-previa').hidden = true;
  $('#archivo-excel').value = '';
  importacion = null;
  await cargarAlumnos();
});

alEnviar($('#form-instructor'), async (d, form) => {
  const { error } = await supabase.from('instructores').insert({ nombre: d.nombre.trim().toUpperCase() });
  if (error) return error;
  form.reset();
  avisar('Instructor guardado.');
  await cargarInstructores();
  await cargarSemana();
});

alEnviar($('#form-vehiculo'), async (d, form) => {
  const placa = d.placa.trim().toUpperCase().replace(/\s+/g, '');
  if (!/^[A-Z0-9-]{5,8}$/.test(placa)) return { message: 'Escribe la placa como ABC-123 o ABC-12D.' };
  const { error } = await supabase.from('vehiculos').insert({ placa, descripcion: d.descripcion.trim() || null });
  if (error) return error.code === '23505' ? { message: 'Ese vehículo ya está registrado.' } : error;
  form.reset();
  avisar('Vehículo guardado.');
  await cargarVehiculos();
});

// Formulario de turno: la categoría se elige entre las que tiene el alumno.
$('#form-turno select[name="alumno_id"]').addEventListener('change', (e) => {
  const alumno = [...alumnosAgenda.values()].find((a) => String(a.id) === e.target.value);
  llenarCategorias($('#form-turno select[name="categoria"]'), alumno?.categoria);
});
