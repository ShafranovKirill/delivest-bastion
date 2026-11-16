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

## Branded loading pass — 2026-11-16, Europe/Moscow

Approved scope: a burgundy first-screen loader using the real cream Delivest logo and an assembling pizza; prioritize the hero and visible intro images, reveal hero copy and later images gently, and prepare ProductPresentation photos in the background. The page stays usable without JavaScript. The loader exits when the hero and essential fonts are ready, or within two seconds of the early head script; interaction also dismisses it. Reduced-motion preferences are respected.

Changed `src/layouts/Base.astro`, `src/styles/global.css`, `src/components/FranchiseLanding.astro`, `src/components/ProductPresentation.astro`; added standalone `public/brand/loader.svg`. `npm ci`, `npm run build`, SVG XML parse and `git diff --check` passed in the isolated clone. Changes transferred to `/home/kirill/storage/projects/delivest/delivest-landing`; final build and diff check passed there. Independent review found no significant issues. Browser checks at desktop and 390px confirmed loader completion, usable content and no horizontal overflow; slider photo selection worked. HTTP logs confirmed all eight slider photos requested before interaction. Isolated execution of the early loader script verified readiness, timeout and interaction exits and idempotent completion. No-JS/reduced-motion fallbacks reviewed in code, not separately emulated in a browser. Current branch: `codex/branded-loading` from `origin/main` at `7c52fa2`. User approved keeping the result and making a local commit on 2026-11-16. Push, PR and deployment are not authorized for this pass. Local preview: `http://127.0.0.1:4326/`; standalone loader: `/brand/loader.svg`.

## Loader revision — 2026-11-16, Europe/Moscow

Kirill approved replacing the logo, pizza and caption with three animated cream steam strokes on burgundy. The standalone preview is available at /brand/loader.svg.

The loader now waits for decoding of the hero background and both eager intro screenshots. Font loading and input no longer control dismissal. Failed image requests settle independently and an eight-second fallback covers stalled requests. Verified on port 4326 in fresh Chrome contexts with delayed, failed and stalled mobile-menu requests. Build and diff check passed.
