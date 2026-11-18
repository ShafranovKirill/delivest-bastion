const SESSION_KEY = 'delivest.landing.session';
const SESSION_LIFETIME = 30 * 60 * 1000;
const ATTRIBUTION_KEYS = ['utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term', 'yclid'];
const ATTRIBUTION_LIMIT = 300;
// Keep the request within the backend's byte limits, including Cyrillic and emoji.
function boundedAttribution(value) {
  let result = '';
  let bytes = 0;
  const encoder = new TextEncoder();
  for (const character of value) {
    const size = encoder.encode(character).length;
    if (bytes + size > ATTRIBUTION_LIMIT) break;
    result += character;
    bytes += size;
  }
  return result;
}

export const GOALS = ['lead_open', 'lead_success', 'contact_telegram', 'contact_vk', 'contact_phone'];

export function readConfig(value) {
  const rawCounter = value?.metrika_counter_id;
  const counter = typeof rawCounter === 'string' && /^\d+$/.test(rawCounter) ? Number(rawCounter) : rawCounter;
  return {
    tracking_enabled: value?.tracking_enabled === true,
    metrika_enabled: value?.metrika_enabled === true,
    metrika_counter_id: Number.isSafeInteger(counter) && counter > 0 ? counter : null,
  };
}

export function createSession({ storage, location, referrer = '', now = Date.now, uuid = () => crypto.randomUUID() }) {
  let memory;
  const get = () => {
    if (memory) return memory;
    try { return JSON.parse(storage?.getItem(SESSION_KEY) || 'null'); } catch { return null; }
  };
  const put = value => {
    memory = value;
    try { storage?.setItem(SESSION_KEY, JSON.stringify(value)); } catch { /* in-memory fallback */ }
  };
  const attribution = () => {
    const params = new URL(location.href).searchParams;
    const values = Object.fromEntries(ATTRIBUTION_KEYS.map(key => [key, boundedAttribution(params.get(key) || '')]));
    let safeReferrer = '';
    try { const url = new URL(referrer); safeReferrer = url.origin + url.pathname; } catch { /* no referrer */ }
    return { ...values, referrer: boundedAttribution(safeReferrer) };
  };
  return () => {
    const time = now();
    const previous = get();
    const valid = previous && typeof previous.id === 'string' && previous.attribution && typeof previous.touched === 'number'
      && time >= previous.touched && time - previous.touched < SESSION_LIFETIME;
    const current = valid ? { ...previous, touched: time } : { id: uuid(), touched: time, attribution: attribution() };
    put(current);
    return { session_id: current.id, ...current.attribution };
  };
}

export function createRequestIdentity(uuid = () => crypto.randomUUID()) {
  let pending;
  return {
    forPayload(payload) {
      const fingerprint = JSON.stringify(payload);
      if (!pending || pending.fingerprint !== fingerprint) pending = { fingerprint, id: uuid() };
      return pending.id;
    },
    succeeded() { pending = undefined; },
  };
}

export async function submitLead({ payload, identity, fetcher, onSaved = () => {}, timeoutMs = 10000 }) {
  const request_id = identity.forPayload(payload);
  const response = await fetcher('/api/landing/leads', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    signal: AbortSignal.timeout(timeoutMs),
    body: JSON.stringify({ request_id, ...payload }),
  });
  if (!response.ok) {
    const error = new Error(`Lead request failed: ${response.status}`);
    error.status = response.status;
    throw error;
  }
  const result = await response.json();
  if (result?.ok !== true || typeof result.saved !== 'boolean') throw new Error('Invalid lead response');
  identity.succeeded();
  if (result.saved) {
    try { onSaved(); } catch { /* analytics must not affect the saved lead */ }
  }
  return result;
}

export function createTracking({ fetcher, session, path, loadMetrika = () => {}, uuid = () => crypto.randomUUID() }) {
  const config = Promise.race([
    Promise.resolve().then(() => fetcher('/api/landing/config', { signal: AbortSignal.timeout(1500) }))
      .then(response => response.ok ? response.json() : null).then(readConfig).catch(() => readConfig(null)),
    new Promise(resolve => setTimeout(() => resolve(readConfig(null)), 1600)),
  ]).then(value => {
    if (value.metrika_enabled && value.metrika_counter_id) {
      try { loadMetrika(value.metrika_counter_id); } catch { /* analytics is optional */ }
    }
    return value;
  });
  const track = async event => {
    if (event !== 'page_view' && !GOALS.includes(event)) return;
    try {
      const settings = await config;
      if (!settings.tracking_enabled) return;
      const { session_id, ...attribution } = session();
      await fetcher('/api/landing/events', {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, keepalive: true,
        body: JSON.stringify({ event_id: uuid(), session_id, event, path: path(), ...attribution }),
      });
    } catch { /* tracking must not affect the form or navigation */ }
  };
  return { track, config };
}
