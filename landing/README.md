# Delivest landing

Landing page of Delivest, built with [Astro](https://astro.build) into static HTML.

```bash
npm install
npm run dev      # http://localhost:4321
npm run build    # -> dist/
```

- `src/components/` holds the page sections, `src/pages/index.astro` puts them together.
- `src/assets/screens/` holds the screenshots: `name.webp` is the light theme, `name-d.webp` is the dark one (optional). The build resizes them and adds a content hash to every file name.
- `src/assets/crm/` holds the CRM logos for the integrations strip.
- `public/brand/` holds the favicon and the OG image, copied as is.

## Deploy

The site runs in a Docker container (nginx with the built `dist/`) on `127.0.0.1:LANDING_PORT`. nginx on the host handles HTTPS and proxies to it.

```
browser ──https──▶ host nginx (TLS) ──▶ 127.0.0.1:LANDING_PORT ──▶ container nginx ──▶ dist/
```

On a server with Docker, nginx and certbot, with the domain already pointing to it:

```bash
git clone https://github.com/ShafranovKirill/delivest-landing.git
cd delivest-landing
cp .env.example .env
nano .env        # DOMAIN, LETSENCRYPT_EMAIL, LANDING_PORT (a free local port, 8090 by default)
sudo ./deploy.sh
```

The script builds the image and starts the container, waits for it to answer, writes the host nginx config for `DOMAIN`, issues a Let's Encrypt certificate and redirects HTTP to HTTPS. To update: `git pull && sudo ./deploy.sh`.

Contact form: the page posts to `/api/lead`, the `lead` container (`lead/server.mjs`) forwards the request to Telegram. Set `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` in `.env`; without them the form shows an error with the Telegram and phone contacts.

Without the script: `docker compose up -d --build` serves the site on `http://127.0.0.1:8090`.
