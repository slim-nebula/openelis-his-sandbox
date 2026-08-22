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

// --- helpers ---------------------------------------------------------------

async function api(path, options = {}) {
  const response = await fetch(API + path, {
    headers: { 'Content-Type': 'application/json' },
    ...options,
  });
  if (!response.ok) {
    const body = await response.text();
    let message = body;
    try { message = JSON.parse(body).error ?? body; } catch { /* plain text */ }
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

function statusBadge(status) {
  const cls = {
    CREATED: 'wait',
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
        <td class="mono">${p.externalPatientId}</td>
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
    toast(`Created ${patient.externalPatientId}`);
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

async function selectPatient(patientId) {
  selectedPatient = await api(`/patients/${patientId}`);

  document.getElementById('detail').hidden = false;
  document.getElementById('detail-name').textContent =
    `${selectedPatient.firstName} ${selectedPatient.lastName}`;
  document.getElementById('detail-summary').innerHTML = `
    <dt>MRN</dt><dd>${selectedPatient.externalPatientId}</dd>
    <dt>Patient ID</dt><dd>${selectedPatient.patientId}</dd>
    <dt>Sex / DOB</dt><dd>${selectedPatient.sex} · ${selectedPatient.dateOfBirth}</dd>
    <dt>National ID</dt><dd>${selectedPatient.nationalId ?? '—'}</dd>`;

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
            <td>${o.testName}</td>
            <td>${statusBadge(o.orderStatus)}</td>
            <td>${fmtDate(o.createdAt)}</td>
          </tr>`
        )
        .join('')
    : '<tr><td colspan="4" class="empty">No orders yet.</td></tr>';

  const resultsBody = document.querySelector('#results tbody');
  resultsBody.innerHTML = results.length
    ? results
        .map(
          (r) => `<tr class="${isRetracted(r) ? 'retracted' : ''}">
            <td>${r.testName}</td>
            <td>${
              isRetracted(r)
                ? '<span class="withdrawn">withdrawn by the laboratory</span>'
                : `<strong>${r.resultValue ?? '—'}</strong> ${r.resultUnit ?? ''}`
            }</td>
            <td>${r.interpretation ?? '—'}</td>
            <td>${resultStatusBadge(r.resultStatus)}</td>
            <td>${fmtDate(r.releasedAt)}</td>
            <td class="mono">${r.openelisResultRef}</td>
          </tr>`
        )
        .join('')
    : '<tr><td colspan="6" class="empty">Nothing released yet. Validate and release the order in OpenELIS.</td></tr>';
}

// Orders move through the LIS asynchronously, so the view refreshes itself
// rather than making the tester reload.
function startPolling() {
  clearInterval(pollTimer);
  pollTimer = setInterval(() => refreshPatientData().catch(() => {}), 5000);
}

// --- ordering --------------------------------------------------------------

async function loadCatalogue() {
  const tests = await api('/test-catalogue');
  document.getElementById('test-select').innerHTML = tests
    .map((t) => `<option value="${t.testCode}">${t.testName} — LOINC ${t.loincCode}</option>`)
    .join('');
}

document.getElementById('order-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  if (!selectedPatient) return;

  try {
    const order = await api('/lab-orders', {
      method: 'POST',
      body: JSON.stringify({ ...formOf(event.target), patientId: selectedPatient.patientId }),
    });
    toast(`Order ${order.orderNumber} created — sending to OpenELIS`);
    await refreshPatientData();
  } catch (err) {
    toast(err.message, true);
  }
});

// --- boot ------------------------------------------------------------------

(async function boot() {
  await refreshHealth();
  setInterval(refreshHealth, 15000);
  try {
    await loadCatalogue();
    await loadPatients();
  } catch (err) {
    toast(`Startup failed: ${err.message}`, true);
  }
})();
