import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://delivest.ru',
  build: { inlineStylesheets: 'always' },
  vite: {
    server: { proxy: { '/api/landing/': process.env.BASTION_API_URL || 'http://127.0.0.1:4000' } },
  },
});
