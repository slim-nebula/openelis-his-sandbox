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

  // 401 means the session is gone — expired, revoked, or never present. Saying
  // so plainly beats "Authorization token is required" appearing in a toast
  // over an empty patient list.
  if (response.status === 401) {
    renderSession();
    throw new Error('Not signed in. Run `make token` and use the Sign in button.');
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
