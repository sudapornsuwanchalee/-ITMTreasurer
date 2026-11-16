# ITM Treasurer v6 — Netlify edition

This is a **Netlify adaptation of v5**, not a live tested production application. It replaces the Cloudflare Worker with a Netlify Edge Function, keeping the existing public dashboard, LINE login and Supabase admin app.

## Setup

1. Create a Supabase project. In SQL Editor run `schema.sql`, then `upgrade_v3.sql`, `upgrade_v4.sql`, `migration_line_v5.sql` (for a new installation). For an existing v5 database, **do not rerun these migrations**. Back up first.
2. In Netlify, deploy this **folder/repository as a site**. For reliable Edge Function deployment, use a Git-connected deployment (or Netlify CLI); plain drag-and-drop deploys may not package Edge Functions correctly. CLI: `npm install -g netlify-cli`, `netlify login`, then from this folder `netlify deploy --prod --dir=.`. Verify the Edge Function appears in Netlify logs.
3. In Netlify Site configuration → Environment variables add (scope including Functions/Edge Functions):
   - `SUPABASE_URL`: https://YOURPROJECT.supabase.co
   - `SUPABASE_SERVICE_ROLE_KEY`: Supabase **secret service_role key** (server only, never browser)
   - `LINE_CHANNEL_ID`: LINE Login channel ID
   - `LINE_CHANNEL_SECRET`: LINE Login channel secret (server only)
   - `SESSION_SECRET`: strong random secret (32+ random bytes)
   Redeploy after setting variables.
4. In LINE Developers set LINE Login Callback URL to `https://YOUR-SITE.netlify.app/auth/callback` (or your custom domain). The gateway automatically derives its public URL from the incoming request. LINE Login scopes: `openid profile`.
5. Edit `admin/config.js` with the Supabase URL and **publishable/anon key only**. Never put service_role key in browser files. In Supabase Auth settings allow the Netlify `/admin/` URL as a redirect. Set up finance roles and member mapping according to the SQL and original v5 requirements.
6. Verify `/api/public`, `/api/me`, `/auth/start`, LINE callback, member allowlist, slip submission, evidence storage, admin reconciliation, approval and period close using **test data**.

## Important limitations

- This package **does not automatically onboard LINE members**. A trusted admin must securely map a verified LINE user ID to an existing Supabase profile in `line_members`. Unknown LINE users cannot upload slips.
- Statement CSV is not independently verified by the bank. Uploaded slips are pending until reviewed and reconciled.
- Public summary is visible to anyone with the URL. Do not publish member names, bank details or slips.
- Netlify Edge Functions must be deployed and tested with the live environment. The project has not been end-to-end tested against LINE, Supabase or Netlify.
- Review session/CSRF controls, rate limits, authorization, bank reconciliation and audit trails before using with real funds. Do not treat this as audited financial software.
- The admin app is inherited from v4 and uses Supabase authentication, not LINE Login.

## Quick smoke tests

- `https://YOUR-SITE.netlify.app/api/me` should return `{"loggedIn":false}` after server env setup.
- `https://YOUR-SITE.netlify.app/api/public` should return JSON after SQL migration.
- `https://YOUR-SITE.netlify.app/auth/start` should redirect to LINE Login.
- A user not in the allowlist should not be able to submit slips.
