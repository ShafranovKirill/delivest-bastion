import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequestIdentity, createSession, createTracking, readConfig, submitLead } from '../src/lib/landing-client.mjs';

const id = (() => { let n = 0; return () => `id-${++n}`; })();

test('config accepts only allowlisted switches and a valid counter', () => {
  assert.deepEqual(readConfig({ tracking_enabled: true, metrika_enabled: true, metrika_counter_id: '123', token: 'secret' }), {
    tracking_enabled: true, metrika_enabled: true, metrika_counter_id: 123,
  });
  assert.equal(readConfig({ tracking_enabled: 'true', metrika_counter_id: '-1' }).tracking_enabled, false);
  assert.equal(readConfig({ metrika_counter_id: '12x' }).metrika_counter_id, null);
});

test('session preserves first attribution, slides for 30 minutes, then rotates', () => {
  const values = new Map();
  let time = 0;
  const storage = { getItem: key => values.get(key), setItem: (key, value) => values.set(key, value) };
  const location = { href: 'https://delivest.ru/?utm_source=direct&yclid=123&contact=private' };
  const session = createSession({ storage, location, referrer: 'https://ref.example/page?email=private', now: () => time, uuid: id });
  const first = session();
  assert.equal(first.utm_source, 'direct');
  assert.equal(first.referrer, 'https://ref.example/page');
  assert.equal(JSON.stringify(first).includes('private'), false);
  time += 29 * 60 * 1000;
  location.href = 'https://delivest.ru/?utm_source=other';
  assert.deepEqual(session(), first);
  time += 29 * 60 * 1000;
  assert.equal(session().session_id, first.session_id);
  time += 31 * 60 * 1000;
  assert.notEqual(session().session_id, first.session_id);
  assert.equal(session().utm_source, 'other');
});

test('attribution is bounded before sending a lead', () => {
  const session = createSession({
    location: { href: `https://delivest.ru/?utm_source=${'x'.repeat(1000)}` },
    referrer: `https://ref.example/${'y'.repeat(1000)}`,
    uuid: id,
  });
  assert.equal(session().utm_source.length, 300);
  assert.equal(session().referrer.length, 300);
});

test('Russian and emoji campaign labels stay within the backend byte limit', () => {
  for (const label of ['Реклама'.repeat(100), '🍕'.repeat(200)]) {
    const session = createSession({ location: { href: `https://delivest.ru/?utm_campaign=${encodeURIComponent(label)}` }, uuid: id });
    const campaign = session().utm_campaign;
    assert.ok(new TextEncoder().encode(campaign).length <= 300);
    assert.ok(label.startsWith(campaign));
    assert.ok(!campaign.includes('\uFFFD'));
  }
});

test('blocked storage falls back to memory', () => {
  const storage = { getItem() { throw Error('blocked'); }, setItem() { throw Error('blocked'); } };
  const session = createSession({ storage, location: { href: 'https://delivest.ru/?utm_campaign=fall' }, now: () => 1, uuid: id });
  assert.deepEqual(session(), session());
  const noStorage = createSession({ location: { href: 'https://delivest.ru/' }, now: () => 1, uuid: id });
  assert.deepEqual(noStorage(), noStorage());
});

test('request identity survives retry and changes only with payload or success', () => {
  const identity = createRequestIdentity(id);
  const first = identity.forPayload({ contact: 'a', intent: 'demo' });
  assert.equal(identity.forPayload({ contact: 'a', intent: 'demo' }), first);
  assert.notEqual(identity.forPayload({ contact: 'b', intent: 'demo' }), first);
  identity.succeeded();
  assert.notEqual(identity.forPayload({ contact: 'b', intent: 'demo' }), first);
});

test('failed lead retries keep request ID; only acknowledged save emits success', async () => {
  const identity = createRequestIdentity(id);
  const requests = [];
  let savedGoals = 0;
  let attempt = 0;
  const fetcher = async (_url, options) => {
    requests.push(JSON.parse(options.body));
    attempt++;
    if (attempt === 1) throw Error('offline');
    return { ok: true, json: async () => ({ ok: true, saved: attempt === 3 }) };
  };
  const payload = { session_id: 's', contact: 'private', intent: 'demo', website: '' };
  const send = () => submitLead({ payload, identity, fetcher, onSaved: () => savedGoals++ });
  await assert.rejects(send());
  await send();
  assert.equal(requests[0].request_id, requests[1].request_id);
  assert.equal(savedGoals, 0);
  await send();
  assert.notEqual(requests[1].request_id, requests[2].request_id);
  assert.equal(savedGoals, 1);
});

test('analytics callback failure cannot turn a saved lead into a form error', async () => {
  const result = await submitLead({
    payload: { contact: 'private' }, identity: createRequestIdentity(id),
    fetcher: async () => ({ ok: true, json: async () => ({ ok: true, saved: true }) }),
    onSaved: () => { throw Error('analytics offline'); },
  });
  assert.equal(result.saved, true);
});

test('lead timeout preserves request ID for retry', async () => {
  const identity = createRequestIdentity(id);
  const requests = [];
  const fetcher = async (_url, options) => {
    requests.push(JSON.parse(options.body));
    if (requests.length === 1) {
      await new Promise((_, reject) => options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true }));
    }
    return { ok: true, json: async () => ({ ok: true, saved: true }) };
  };
  const options = { payload: { contact: 'private' }, identity, fetcher, timeoutMs: 10 };
  const keepAlive = setTimeout(() => {}, 30);
  try { await assert.rejects(submitLead(options)); } finally { clearTimeout(keepAlive); }
  await submitLead(options);
  assert.equal(requests[0].request_id, requests[1].request_id);
});

test('events contain only path and flat attribution; failures remain isolated', async () => {
  const posts = [];
  const fetcher = async (url, options) => {
    if (url.endsWith('/config')) return { ok: true, json: async () => ({ tracking_enabled: true, metrika_enabled: true, metrika_counter_id: '17' }) };
    posts.push(JSON.parse(options.body));
    throw Error('analytics offline');
  };
  let metrika;
  const tracking = createTracking({ fetcher, session: () => ({ session_id: 'session', utm_source: 'search', referrer: '' }), path: () => '/pricing', loadMetrika: value => { metrika = value; }, uuid: id });
  await tracking.track('lead_open');
  await tracking.track('invalid');
  assert.equal(metrika, 17);
  assert.equal(posts.length, 1);
  assert.deepEqual(posts[0], { event_id: posts[0].event_id, session_id: 'session', event: 'lead_open', path: '/pricing', utm_source: 'search', referrer: '' });
  assert.equal(JSON.stringify(posts[0]).includes('contact'), false);
});

test('failed config disables analytics without affecting calls', async () => {
  let posts = 0;
  const tracking = createTracking({ fetcher: async () => { posts++; throw Error('offline'); }, session: () => ({ session_id: 'a' }), path: () => '/' });
  await tracking.track('page_view');
  assert.equal(posts, 1);
});

test('Metrika loads independently when own tracking is disabled', async () => {
  let metrika;
  const calls = [];
  const tracking = createTracking({
    fetcher: async url => { calls.push(url); return { ok: true, json: async () => ({ tracking_enabled: false, metrika_enabled: true, metrika_counter_id: '123' }) }; },
    session: () => ({ session_id: 'a' }), path: () => '/', loadMetrika: id => { metrika = id; },
  });
  await tracking.track('lead_open');
  assert.equal(metrika, 123);
  assert.deepEqual(calls, ['/api/landing/config']);
});

test('hanging config reaches the deadline and does not hold tracking indefinitely', async () => {
  const tracking = createTracking({ fetcher: () => new Promise(() => {}), session: () => ({ session_id: 'a' }), path: () => '/' });
  await tracking.track('lead_open');
  assert.equal((await tracking.config).tracking_enabled, false);
});
