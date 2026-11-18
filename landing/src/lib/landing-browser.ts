import { createSession, createTracking } from './landing-client.mjs';

const session = createSession({
  storage: (() => { try { return window.localStorage; } catch { return undefined; } })(),
  location: window.location,
  referrer: document.referrer,
});

function loadMetrika(counter: number) {
  type Metrika = ((...args: unknown[]) => void) & { a?: unknown[]; l?: number };
  const current = window as Window & { ym?: Metrika };
  if (!current.ym) {
    const queue: Metrika = (...args) => { (queue.a ||= []).push(args); };
    queue.l = Date.now();
    current.ym = queue;
    const script = document.createElement('script');
    script.async = true;
    script.src = 'https://mc.yandex.ru/metrika/tag.js';
    document.head.append(script);
  }
  current.ym(counter, 'init', { clickmap: false, trackLinks: false, accurateTrackBounce: false, webvisor: false });
}

const tracking = createTracking({ fetcher: window.fetch.bind(window), session, path: () => location.pathname, loadMetrika });
void tracking.track('page_view');

export function currentSession() { return session(); }
export function trackGoal(goal: string) {
  void tracking.track(goal);
  void tracking.config.then(config => {
    if (!config.metrika_enabled || !config.metrika_counter_id) return;
    try { (window as Window & { ym?: (...args: unknown[]) => void }).ym?.(config.metrika_counter_id, 'reachGoal', goal); } catch { /* optional */ }
  });
}

document.addEventListener('click', event => {
  const link = (event.target as Element)?.closest<HTMLAnchorElement>('a[href]');
  if (!link) return;
  const href = link.getAttribute('href') || '';
  if (href.startsWith('https://t.me/')) trackGoal('contact_telegram');
  else if (href.startsWith('https://vk.ru/') || href.startsWith('https://vk.com/')) trackGoal('contact_vk');
  else if (href.startsWith('tel:')) trackGoal('contact_phone');
});
