// Accepts contact requests from the landing form and forwards them to Telegram.
// No dependencies: the bot token stays on the server, the page only posts JSON to /api/lead.
import http from 'node:http';

const PORT = Number(process.env.PORT || 3000);
const TOKEN = process.env.TELEGRAM_BOT_TOKEN || '';
const CHAT_ID = process.env.TELEGRAM_CHAT_ID || '';
const TZ = process.env.APP_TIMEZONE || 'Europe/Moscow';

const WINDOW_MS = 10 * 60 * 1000;
const MAX_PER_WINDOW = 5;
const hits = new Map();

if (!TOKEN || !CHAT_ID) console.warn('TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID is empty: requests will be rejected');

const limited = ip => {
  const now = Date.now();
  const recent = (hits.get(ip) || []).filter(t => now - t < WINDOW_MS);
  recent.push(now);
  hits.set(ip, recent);
  return recent.length > MAX_PER_WINDOW;
};
setInterval(() => {
  const now = Date.now();
  for (const [ip, list] of hits) if (list.every(t => now - t >= WINDOW_MS)) hits.delete(ip);
}, WINDOW_MS).unref();

const escape = s => s.replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' })[c]);
const clean = (v, max) => (typeof v === 'string' ? v.replace(/\s+/g, ' ').trim().slice(0, max) : '');

const send = (res, status, body) => {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(body));
};

const readJson = req => new Promise((resolve, reject) => {
  let size = 0;
  const chunks = [];
  req.on('data', c => {
    size += c.length;
    if (size > 4096) { reject(new Error('too large')); req.destroy(); return; }
    chunks.push(c);
  });
  req.on('end', () => {
    try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); } catch { reject(new Error('bad json')); }
  });
  req.on('error', reject);
});

http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/api/health') return send(res, 200, { ok: true });
  if (req.method !== 'POST' || req.url !== '/api/lead') return send(res, 404, { ok: false });

  let data;
  try { data = await readJson(req); } catch { return send(res, 400, { ok: false, error: 'bad_request' }); }

  // Bots fill the hidden field; pretend success so they do not retry
  if (clean(data.website, 200)) return send(res, 200, { ok: true });

  const contact = clean(data.contact, 120);
  const name = clean(data.name, 80);
  const intent = data.intent === 'pricing' ? 'Расчёт подключения' : 'Демонстрация Delivest';
  if (contact.length < 5) return send(res, 400, { ok: false, error: 'contact' });

  const ip = String(req.headers['x-real-ip'] || req.socket.remoteAddress || '');
  if (limited(ip)) return send(res, 429, { ok: false, error: 'rate' });
  if (!TOKEN || !CHAT_ID) return send(res, 503, { ok: false, error: 'not_configured' });

  const time = new Date().toLocaleString('ru-RU', { timeZone: TZ, dateStyle: 'short', timeStyle: 'short' });
  const text = [
    '<b>Новая заявка с лендинга</b>',
    `Запрос: ${intent}`,
    `Контакт: ${escape(contact)}`,
    `Имя: ${name ? escape(name) : '—'}`,
    `Время: ${time}`,
  ].join('\n');

  try {
    const r = await fetch(`https://api.telegram.org/bot${TOKEN}/sendMessage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: CHAT_ID, text, parse_mode: 'HTML', disable_web_page_preview: true }),
      signal: AbortSignal.timeout(8000),
    });
    if (!r.ok) throw new Error(`telegram ${r.status}: ${await r.text()}`);
    console.log(`lead sent from ${ip}`);
    send(res, 200, { ok: true });
  } catch (e) {
    console.error('lead failed:', e.message);
    send(res, 502, { ok: false, error: 'send' });
  }
}).listen(PORT, () => console.log(`lead service on :${PORT}`));
