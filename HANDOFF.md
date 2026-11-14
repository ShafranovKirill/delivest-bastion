# Landing redesign

Updated 2026-11-14, Europe/Moscow.

Approved work: refresh the landing for franchise owners using the supplied photos and screenshots, brand #48010c, custom mobile app offer, app-store names, integrations diagram, screenshot enlargement and scroll-dependent colour transition. User approved commit and push to main on 2026-11-14.

Implemented in FranchiseLanding.astro, Header.astro, Integrations.astro, LeadDialog.astro, Base.astro and index.astro. Media are in public/franchise, icon attribution in public/credits.

Latest approval includes all main call-to-action buttons saying “Обсудить подключение”. The form accepts phone or email and offers direct Telegram, VK and telephone links.

Validation on final implementation: npm run build and git diff --check passed. Browser checks at widths 320, 390 and 1366 passed for screenshot themes, enlargement, integrations layout and horizontal overflow. Scroll colour changes checked in both directions and reduced-motion mode. All call-to-action buttons and direct contact links checked. Independent read-only review found no significant issues.

No Makefile or make preflight target exists in this landing repository. Live Telegram submission was not tested. Production deployment was not performed.

Local preview: http://127.0.0.1:4322/ (npm run preview -- --host 127.0.0.1 --port 4322, requires npm run build).
Development: npm ci; npm run dev.
Source branch: codex/franchise-landing-preview. User requested main as push destination. No PR requested.
