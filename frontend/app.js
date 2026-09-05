/* ---------------------------------------------------------------------------
 * Minimal test client for the HIS sandbox.
 *
 * Everything goes through /api, which the reverse proxy forwards to Kong. The
 * frontend never talks to Kafka, the bridge or OpenELIS directly — if a result
 * shows up here, it genuinely travelled the whole path.
 * ------------------------------------------------------------------------- */

const API = '/api';
let selectedPatient = null;
let pollTimer = null;

// --- session ---------------------------------------------------------------
// The token is issued elsewhere — by IAM in the estate, by `make token` here —
// and this page only carries it. It is kept in localStorage so a reload does
// not end the session, which is what the estate's frontend does with it too.

const SESSION_KEY = 'his-sandbox-token';

const token = () => localStorage.getItem(SESSION_KEY) || '';

// Reads the payload for display only. Nothing is trusted from here: the claims
// shown are the ones the SERVER will verify, and a token edited in the console
// would simply be rejected on the next request.
function claimsOf(jwt) {
  try {
    const [, payload] = jwt.split('.');
    return JSON.parse(atob(payload.replace(/-/g, '+').replace(/_/g, '/')));
  } catch { return null; }
}

function renderSession() {
  const who = document.getElementById('session-who');
  const button = document.getElementById('signin-btn');
  const claims = token() ? claimsOf(token()) : null;

  // Shown, not editable, and shown from the same claims the server will verify.
  // The order is attributed to the signed-in user whatever this page displays —
  // this is a mirror of the decision, not the input to it.
  const provider = document.getElementById('order-provider');
  if (provider) {
    provider.textContent = claims
      ? `${claims.usr_full_name || claims.usr_name} (usr_id ${claims.usr_id})`
      : 'not signed in';
  }

  if (!claims) {
    who.textContent = 'not signed in';
    who.className = 'signed-out';
    button.textContent = 'Sign in';
    return;
  }

  const expired = claims.exp * 1000 < Date.now();
  who.textContent = expired
    ? `${claims.usr_name} — session expired`
    : `${claims.usr_full_name || claims.usr_name} (usr_id ${claims.usr_id})`;
  who.className = expired ? 'signed-out' : 'signed-in';
  button.textContent = 'Sign out';
}

// --- helpers ---------------------------------------------------------------

async function api(path, options = {}) {
  const current = token();
  const response = await fetch(API + path, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...(current ? { Authorization: `Bearer ${current}` } : {}),
      ...(options.headers || {}),
    },
  });

  // 401 means the session is gone — expired, revoked, or superseded because
  // somebody minted a second token for the same usr_id (running any test suite
  // does exactly that, since the suites sign in as user 1).
  //
  // DISCARD the token rather than merely re-rendering. Keeping a token the
  // server has already refused leaves the page looking signed in, so the button
  // offers "Sign out" instead of a paste prompt — and the fix, clicking it
  // twice, is not something anyone would guess. Dropping it makes the page tell
  // the truth and puts the prompt one click away.
  if (response.status === 401) {
    localStorage.removeItem(SESSION_KEY);
    renderSession();
    throw new Error(
      'Session ended — this token was expired, revoked, or replaced by a newer '
      + 'one for the same user. Run `make token USER=42` and sign in again.',
    );
  }

  if (!response.ok) {
    const body = await response.text();
    let message = body;
    try {
      const parsed = JSON.parse(body);
      message = parsed.error ?? parsed.message ?? body;
    } catch { /* plain text */ }
    throw new Error(message || `${response.status} ${response.statusText}`);
  }
  return response.status === 204 ? null : response.json();
}

function toast(message, bad = false) {
  const el = document.getElementById('toast');
  el.textContent = message;
  el.classList.toggle('bad', bad);
  el.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { el.hidden = true; }, 4500);
}

function formOf(form) {
  return Object.fromEntries(
    [...new FormData(form).entries()].map(([k, v]) => [k, v === '' ? null : v])
  );
}

// The laboratory's own progress, shown UNDER the status rather than instead of
// it. A ward asking "where is my test?" wants the sample's position in the lab,
// and the accession number is what they will be asked for on the telephone.
function progressNote(order) {
  if (!order.labProgress && !order.labAccession) return '';

  const label = {
    IN_LABORATORY: 'in the laboratory',
    AWAITING_VALIDATION: 'result awaiting validation',
  }[order.labProgress] ?? order.labProgress;

  const parts = [];
  if (label) parts.push(label);
  if (order.labAccession) parts.push(`accession <span class="mono">${order.labAccession}</span>`);
  return `<div class="progress">${parts.join(' · ')}</div>`;
}

function statusBadge(status) {
  const cls = {
    CREATED: 'wait',
    // Not a failure and not progress: the order is correct and complete, and is
    // waiting on a physical act. The laboratory has not been told about it yet.
    AWAITING_COLLECTION: 'wait',
    SENT_TO_LIS: 'wait',
    ACCEPTED_BY_LIS: 'wait',
    RESULT_AVAILABLE: 'ok',
    REJECTED_BY_LIS: 'bad',
    FAILED: 'bad',
  }[status] ?? '';
  return `<span class="badge ${cls}">${status.replace(/_/g, ' ').toLowerCase()}</span>`;
}

// A result the laboratory has withdrawn must not read like an ordinary one.
// "entered-in-error" in small grey type beside a blank value is exactly how a
// retraction gets missed, so retracted rows are marked and struck through.
function resultStatusBadge(status) {
  const cls = {
    final: 'ok',
    amended: 'wait',
    corrected: 'wait',
    'entered-in-error': 'bad',
  }[status] ?? '';
  const label = status === 'entered-in-error' ? 'retracted' : status;
  return `<span class="badge ${cls}">${label}</span>`;
}

const isRetracted = (r) => r.resultStatus === 'entered-in-error';

// HL7 v3 ObservationInterpretation. The critical tier is a different class of
// event from the merely abnormal one - CLIA 42 CFR 493.1109(f) and ISO 15189
// 7.4.1.3 both oblige the laboratory to telephone it - so it must not look like
// an ordinary high.
//
// Keyed on the CODE, never on the label: "Critical high" is wording a laboratory
// may change, and a severity treatment that matches on words loses the red
// silently the day it does.
const CRITICAL = ['AA', 'HH', 'LL'];
const ABNORMAL = ['A', 'H', 'L', 'HU', 'LU'];

function interpretationCell(r) {
  const label = r.interpretation ?? '—';
  const code = (r.interpretationCode ?? '').toUpperCase();

  if (CRITICAL.includes(code)) {
    return `<span class="interp critical">⚠ CRITICAL — ${label}</span>`;
  }
  if (ABNORMAL.includes(code)) return `<span class="interp abnormal">${label}</span>`;

  // No code, or a code we do not recognise. Show the laboratory's own wording
  // plainly rather than inventing a severity we were not told - a made-up red is
  // as harmful as a missing one.
  return label;
}

// The ward's side of an order: has the specimen been drawn yet?
//
// Only an inpatient order has anything to do here. An outpatient order is drawn
// in the laboratory, so there is no ward action and saying "—" is the truth
// rather than an omission.
function collectionCell(o) {
  if (o.patientClass !== 'INPATIENT') return '<span class="muted-cell">drawn at the lab</span>';
  if (o.collectedAt) return `<span class="collected">${fmtDate(o.collectedAt)}</span>`;
  if (o.orderStatus !== 'AWAITING_COLLECTION') return '<span class="unrecorded">not recorded</span>';
  return `<button class="draw-btn" data-order="${o.orderNumber}">Record draw</button>`;
}

// Collection time, and where it came from.
//
// A result released five minutes ago may be from blood drawn six hours ago, and
// nothing on a released-time-only display says so (ISO 15189 7.4.1.7.a).
//
// "not recorded" is spelled out rather than left blank, because a blank cell
// cannot be told apart from a rendering fault — and because the alternative,
// quietly showing a received or released time in its place, would look exactly
// like an observed collection time and be believed.
function collectedCell(r) {
  if (!r.collectedAt) return '<span class="unrecorded">not recorded</span>';
  const from = r.collectionSource === 'ward' ? 'ward' : 'lab';
  return `${fmtDate(r.collectedAt)} <span class="source">${from}</span>`;
}

// A clinician may have acted on the value this one replaced, and needs to know
// what it said to judge whether that decision still stands (ISO 15189 7.4.1.8).
// Shown only for a correction: on a retraction the value is withdrawn outright,
// and reprinting the old number there would invite someone to keep using it.
function supersededNote(r) {
  const corrected = r.resultStatus === 'corrected' || r.resultStatus === 'amended';
  if (!corrected || !r.previousValue) return '';
  const when = r.previousReleasedAt ? ` on ${fmtDate(r.previousReleasedAt)}` : '';
  return `<div class="superseded">corrected from <strong>${r.previousValue}</strong>${when}</div>`;
}

const fmtDate = (v) => (v ? new Date(v).toLocaleString() : '—');

// --- health ----------------------------------------------------------------

async function refreshHealth() {
  const el = document.getElementById('health');
  try {
    const health = await api('/health');
    el.textContent = `edge → kong → ${health.component}: ${health.status}`;
  } catch (err) {
    el.textContent = `API unreachable: ${err.message}`;
  }
}

// --- patients --------------------------------------------------------------

async function loadPatients(query = '') {
  const patients = await api(`/patients/search?q=${encodeURIComponent(query)}`);
  const body = document.querySelector('#patients tbody');

  if (!patients.length) {
    body.innerHTML = '<tr><td colspan="5" class="empty">No patients match.</td></tr>';
    return;
  }

  body.innerHTML = patients
    .map(
      (p) => `<tr>
        <td class="mono">${p.mrn}</td>
        <td>${p.firstName} ${p.lastName}</td>
        <td>${p.sex}</td>
        <td>${p.dateOfBirth}</td>
        <td><button class="link" data-select="${p.patientId}">Open</button></td>
      </tr>`
    )
    .join('');

  body.querySelectorAll('[data-select]').forEach((button) =>
    button.addEventListener('click', () => selectPatient(button.dataset.select))
  );
}

document.getElementById('patient-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  try {
    const patient = await api('/patients', {
      method: 'POST',
      body: JSON.stringify(formOf(event.target)),
    });
    toast(`Created ${patient.mrn}`);
    event.target.reset();
    await loadPatients();
    await selectPatient(patient.patientId);
  } catch (err) {
    toast(err.message, true);
  }
});

document.getElementById('search-btn').addEventListener('click', () =>
  loadPatients(document.getElementById('patient-search').value)
);

document.getElementById('patient-search').addEventListener('keydown', (event) => {
  if (event.key === 'Enter') loadPatients(event.target.value);
});

// --- selected patient ------------------------------------------------------

// The encounter the clinician is currently working inside.
//
// Deliberately NOT a box on the order form. A doctor does not retype the visit
// for each test - they are inside a visit and place several orders within it,
// which is exactly the one-visit-many-orders shape the API is built around.
// Putting it on the form would teach the opposite.
//
// It lives only in this page. A real HIS takes the visit from its own
// admissions or encounter module; there is none here, so the sandbox mints one
// so the concept is visible rather than theoretical.
let currentVisit = null;

const newVisitNumber = () => {
  const stamp = new Date().toISOString().slice(0, 10).replace(/-/g, '');
  const suffix = Math.random().toString(16).slice(2, 6).toUpperCase();
  return `V-${stamp}-${suffix}`;
};

function renderVisit() {
  const el = document.getElementById('current-visit');
  if (el) el.textContent = currentVisit ?? '—';
}

async function selectPatient(patientId) {
  selectedPatient = await api(`/patients/${patientId}`);

  // A new patient selection starts a new encounter. Carrying the previous
  // patient's visit over would file one patient's results against another's.
  currentVisit = newVisitNumber();

  document.getElementById('detail').hidden = false;
  document.getElementById('detail-name').textContent =
    `${selectedPatient.firstName} ${selectedPatient.lastName}`;
  document.getElementById('detail-summary').innerHTML = `
    <dt>MRN</dt><dd>${selectedPatient.mrn}</dd>
    <dt>Patient ID</dt><dd>${selectedPatient.patientId}</dd>
    <dt>Sex / DOB</dt><dd>${selectedPatient.sex} · ${selectedPatient.dateOfBirth}</dd>
    <dt>National ID</dt><dd>${selectedPatient.nationalId ?? '—'}</dd>`;
  renderVisit();

  await refreshPatientData();
  startPolling();
}

async function refreshPatientData() {
  if (!selectedPatient) return;
  const id = selectedPatient.patientId;

  const [orders, results] = await Promise.all([
    api(`/patients/${id}/lab-orders`),
    api(`/patients/${id}/results`),
  ]);

  const ordersBody = document.querySelector('#orders tbody');
  ordersBody.innerHTML = orders.length
    ? orders
        .map(
          (o) => `<tr>
            <td class="mono">${o.orderNumber}</td>
            <td class="mono visit-cell${o.visitNumber === currentVisit ? ' current' : ''}">${o.visitNumber ?? '—'}</td>
            <td>${o.testName}</td>
            <td>${statusBadge(o.orderStatus)}${progressNote(o)}</td>
            <td>${fmtDate(o.createdAt)}</td>
            <td>${collectionCell(o)}</td>
          </tr>`
        )
        .join('')
    : '<tr><td colspan="6" class="empty">No orders yet.</td></tr>';

  const resultsBody = document.querySelector('#results tbody');
  resultsBody.innerHTML = results.length
    ? results
        .map(
          (r) => `<tr class="${isRetracted(r) ? 'retracted' : ''}">
            <td>${r.testName}</td>
            <td class="specimen">${
              // Two orders for the same LOINC on different specimens share a
              // test name — "HIV VIRAL LOAD" for both plasma and dried blood
              // spot — and are different examinations. Without this column a
              // clinician cannot tell which one they are reading.
              r.specimenType ?? '—'
            }</td>
            <td>${
              isRetracted(r)
                ? '<span class="withdrawn">withdrawn by the laboratory</span>'
                : `<strong>${r.resultValue ?? '—'}</strong> ${r.resultUnit ?? ''}`
            }${supersededNote(r)}</td>
            <td class="range">${
              // A value without its range is not interpretable: 5.4 is a normal
              // potassium in one laboratory and a reportable one in another.
              // Suppressed on a retraction for the same reason the value is —
              // there is nothing left to interpret.
              isRetracted(r) ? '—' : (r.referenceRange ?? '—')
            }</td>
            <td>${isRetracted(r) ? '—' : interpretationCell(r)}</td>
            <td>${resultStatusBadge(r.resultStatus)}</td>
            <td class="collected">${collectedCell(r)}</td>
            <td>${fmtDate(r.releasedAt)}</td>
            <td class="mono visit-cell${r.visitNumber === currentVisit ? ' current' : ''}">${r.visitNumber ?? '—'}</td>
            <td class="mono">${r.orderNumber ?? '—'}</td>
            <td class="mono accession">${
              // Next to the order number because they are the two numbers a
              // person quotes — but they are quoted to different people. Ours
              // identifies the order in this system; this one identifies it in
              // the LABORATORY's, and it is the only one the technician who
              // answers the phone can look up.
              r.labAccession ?? '—'
            }</td>
            <td class="mono">${r.openelisResultRef}</td>
          </tr>`
        )
        .join('')
    : '<tr><td colspan="12" class="empty">Nothing released yet. Validate and release the order in OpenELIS.</td></tr>';
}

// Orders move through the LIS asynchronously, so the view refreshes itself
// rather than making the tester reload.
function startPolling() {
  clearInterval(pollTimer);
  pollTimer = setInterval(() => refreshPatientData().catch(() => {}), 5000);
}

// --- ordering --------------------------------------------------------------

// --- the test picker -------------------------------------------------------
//
// Searchable rather than a dropdown, because the menu is the laboratory's and
// can be long, and because several entries differ only by specimen. The visible
// input holds what the user typed; the SUBMITTED value is a hidden field that
// only ever changes when an option is actually chosen. That split matters: a
// half-typed "HIV" must never be submittable as a test code, so typing clears
// the selection and the form refuses until something real is picked.

let catalogue = [];
let activeOption = -1;

async function loadCatalogue() {
  catalogue = await api('/test-catalogue');
}

const comboInput = () => document.getElementById('test-search');
const comboCode = () => document.getElementById('test-code');
const comboList = () => document.getElementById('test-options');

function closeOptions() {
  comboList().hidden = true;
  comboInput().setAttribute('aria-expanded', 'false');
  activeOption = -1;
}

function matchesFor(term) {
  const q = term.trim().toLowerCase();
  // An empty box shows the whole menu — the doctor may not know what to type,
  // and an empty list would read as "the laboratory offers nothing".
  const hits = q === ''
    ? catalogue
    : catalogue.filter((t) =>
        t.testName.toLowerCase().includes(q) ||
        t.testCode.toLowerCase().includes(q) ||
        (t.loincCode ?? '').toLowerCase().includes(q) ||
        (t.specimenType ?? '').toLowerCase().includes(q));
  return hits.slice(0, 50);
}

function renderOptions(term) {
  const list = comboList();
  const hits = matchesFor(term);

  if (hits.length === 0) {
    list.innerHTML = '<li class="combo-empty">No test matches — the menu comes '
      + 'from the laboratory, so an unlisted test is one it does not offer.</li>';
  } else {
    list.innerHTML = hits
      .map((t, i) => `<li role="option" id="test-opt-${i}" data-code="${t.testCode}"
             class="${i === activeOption ? 'active' : ''}">
             <span class="combo-name">${t.testName}</span>
             <span class="combo-meta">${t.specimenType ?? '—'} · LOINC ${t.loincCode}</span>
           </li>`)
      .join('');
  }
  list.hidden = false;
  comboInput().setAttribute('aria-expanded', 'true');
  return hits;
}

function chooseOption(test) {
  comboInput().value = `${test.testName} (${test.specimenType ?? '—'})`;
  comboCode().value = test.testCode;
  comboInput().setCustomValidity('');
  closeOptions();
}

function wireTestCombo() {
  const input = comboInput();
  const list = comboList();

  input.addEventListener('input', () => {
    // Typing invalidates any previous choice. Without this, editing the text
    // after picking would submit the OLD code while showing new text.
    comboCode().value = '';
    input.setCustomValidity('Choose a test from the list.');
    activeOption = -1;
    renderOptions(input.value);
  });

  input.addEventListener('focus', () => renderOptions(input.value));

  input.addEventListener('keydown', (event) => {
    const hits = matchesFor(input.value);
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      if (list.hidden) renderOptions(input.value);
      const step = event.key === 'ArrowDown' ? 1 : -1;
      activeOption = (activeOption + step + hits.length) % Math.max(hits.length, 1);
      renderOptions(input.value);
    } else if (event.key === 'Enter' && !list.hidden && activeOption >= 0 && hits[activeOption]) {
      event.preventDefault();
      chooseOption(hits[activeOption]);
    } else if (event.key === 'Escape') {
      closeOptions();
    }
  });

  list.addEventListener('mousedown', (event) => {
    // mousedown, not click: blur would close the list before click landed.
    const item = event.target.closest('li[data-code]');
    if (!item) return;
    event.preventDefault();
    const test = catalogue.find((t) => t.testCode === item.dataset.code);
    if (test) chooseOption(test);
  });

  document.addEventListener('click', (event) => {
    if (!document.getElementById('test-combo').contains(event.target)) closeOptions();
  });
}

document.getElementById('order-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  if (!selectedPatient) return;

  try {
    const order = await api('/lab-orders', {
      method: 'POST',
      // The visit rides along with every order placed during it. This is the
      // one identifier the laboratory never sees: it is filed against locally
      // when the result comes back, by way of the order number.
      body: JSON.stringify({
        ...formOf(event.target),
        patientId: selectedPatient.patientId,
        ...(currentVisit ? { visitNumber: currentVisit } : {}),
      }),
    });
    toast(
      order.orderStatus === 'AWAITING_COLLECTION'
        // Say what is NOT happening. A nurse who assumes the laboratory already
        // has this order will not go and draw the blood.
        ? `Order ${order.orderNumber} created — waiting for the specimen to be drawn. `
          + 'It reaches the laboratory when the draw is recorded.'
        : `Order ${order.orderNumber} created — sending to OpenELIS`,
    );
    await refreshPatientData();
  } catch (err) {
    toast(err.message, true);
  }
});

// The patient came back another day. A new encounter, same patient record —
// which is the case the visit exists for: results from today must not appear
// on last month's page.
document.getElementById('new-visit-btn').addEventListener('click', async () => {
  if (!selectedPatient) return;
  currentVisit = newVisitNumber();
  renderVisit();
  toast(`New visit ${currentVisit} — orders from now on file against it`);
  await refreshPatientData();
});

// Tell the doctor what their choice means before they submit, not after.
document.getElementById('patient-class').addEventListener('change', (event) => {
  document.getElementById('class-hint').textContent =
    event.target.value === 'INPATIENT'
      ? 'The order waits on the ward until a nurse records the draw, then goes to the laboratory carrying that time.'
      : 'The laboratory draws the specimen and reports the collection time back.';
});

// Recording the bedside draw. Delegated, because the rows are re-rendered by
// the poll every five seconds and a handler bound to a row would not survive it.
document.getElementById('orders').addEventListener('click', async (event) => {
  const button = event.target.closest('.draw-btn');
  if (!button) return;

  // Defaulted to now for convenience, but shown for confirmation and editable:
  // a nurse records a round after finishing it, and "now" would quietly be
  // minutes or hours wrong on every tube but the last.
  const suggested = new Date();
  const entered = window.prompt(
    'When was the specimen drawn?\n\nISO-8601, e.g. ' + suggested.toISOString(),
    suggested.toISOString(),
  );
  if (!entered) return;

  try {
    const order = await api(`/lab-orders/${button.dataset.order}/collection`, {
      method: 'POST',
      body: JSON.stringify({ collectedAt: entered.trim() }),
    });
    toast(`Draw recorded — order ${order.orderNumber} released to the laboratory`);
    await refreshPatientData();
  } catch (err) {
    toast(err.message, true);
  }
});

document.getElementById('signin-btn').addEventListener('click', async () => {
  if (token()) {
    // Local only. The Redis session stays until it expires or someone calls
    // IAM's logout — this page cannot revoke a token, and pretending otherwise
    // would teach the wrong thing about where sessions live.
    localStorage.removeItem(SESSION_KEY);
    renderSession();
    toast('Signed out of this browser');
    return;
  }

  const pasted = window.prompt(
    'Paste a token from `make token`:\n\n' +
    'There is no login form because there is no IAM in the sandbox. In the ' +
    'estate this token arrives from /api/auth/login.'
  );
  if (!pasted) return;

  const trimmed = pasted.trim();
  if (!claimsOf(trimmed)) {
    toast('That does not look like a JWT', true);
    return;
  }

  localStorage.setItem(SESSION_KEY, trimmed);
  renderSession();

  try {
    await loadCatalogue();
    await loadPatients();
    toast('Signed in');
  } catch (err) {
    toast(err.message, true);
  }
});

// --- boot ------------------------------------------------------------------

(async function boot() {
  renderSession();
  wireTestCombo();
  await refreshHealth();
  setInterval(refreshHealth, 15000);

  if (!token()) {
    toast('Not signed in — run `make token`, then use the Sign in button', true);
    return;
  }

  try {
    await loadCatalogue();
    await loadPatients();
  } catch (err) {
    toast(`Startup failed: ${err.message}`, true);
  }
})();
