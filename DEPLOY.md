# Deploy the WorldFriends backend

The app needs this API. Two supported paths: **Render** (public HTTPS URL, free tier)
or **Docker on your own machine** (LAN only). `render.yaml` and `docker-compose.yml`
are already in the repo, so neither needs code edits.

---

## A. Render — public URL in about 10 minutes

What you need: a GitHub account with access to this repo (already the case) and a
free Render account (<https://render.com>).

1. Sign in to Render with **GitHub**.
2. **New +** → **Blueprint**.
3. Pick the repository **`oppsoop/Sushh`** → **Connect**. Render reads `render.yaml`
   and shows two resources: `worldfriends-api` (web service) and `worldfriends-db`
   (Postgres).
4. **Apply**. Render creates the database, builds the API
   (`npm ci --omit=dev && node scripts/migrate.js`) and starts it.
5. Wait for the service to show **Live** (first build ~3–5 min). The health check
   `/v1/health` must pass.
6. Copy the service URL from the top of the page. It looks like:

   ```
   https://worldfriends-api-abcd.onrender.com
   ```

   That is your backend URL — no trailing slash, no `/v1`.
7. Verify it yourself in a browser: open
   `https://<your-url>/v1/health`. You should see:

   ```json
   {"status":"ok","version":"1.0.0","database":true,...}
   ```

### After you have the URL

- **Fastest:** in the app tap the **⛁ server** icon on the welcome screen, paste the
  URL, **Test & save**.
- **Baked in (recommended):** set it once for every future build:

  ```bash
  gh variable set API_BASE_URL --repo oppsoop/Sushh --body "https://worldfriends-api-abcd.onrender.com"
  gh workflow run build-apk --repo oppsoop/Sushh
  ```

  The APK that comes out of that run points at your server with no typing needed.

Free plan notes: the instance sleeps after ~15 minutes idle (the first request then
takes ~30 s), and the disk is ephemeral, so uploaded media is lost on redeploy. Move
`STORAGE` to S3/R2 (see `backend/src/env.js`) when you care about that.

---

## B. Docker on your computer — LAN only

```bash
git clone https://github.com/oppsoop/Sushh.git
cd Sushh
docker compose up -d --build
```

- API: <http://localhost:8080/v1/health>
- In the app's Server box: `http://<computer-LAN-IP>:8080`
  (Windows `ipconfig`, macOS `ipconfig getifaddr en0`, Linux `hostname -I`).
- Phone must be on the same Wi-Fi. This URL is private, so it cannot be baked into a
  public beta build — CI rejects private addresses on purpose.

---

## C. Manual Node install (no Docker)

```bash
cd backend
npm ci
export DATABASE_URL="postgresql://user:pass@host:5432/worldfriends"
export JWT_SECRET="$(openssl rand -hex 32)"
export ALLOW_DEV_CODES=true
export BETA_INVITE_CODES=FRIENDS2026
node scripts/migrate.js
npm start          # http://0.0.0.0:8080
```

Requirements: Node 20+, Postgres 14+. `ALLOW_DEV_CODES=true` makes the API return the
email verification code in the response (the app fills it in automatically) so you
don't need SMTP for a test deployment. Turn it off once `SMTP_URL` is configured.

---

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| App: "Could not reach that server" | URL wrong (extra `/v1`, trailing slash), server asleep, or the phone has no internet |
| `{"error":{"code":"not_found","message":"No route for GET /health"}}` | You dropped `/v1` — the health route is `/v1/health` |
| Signup says "invite code is not valid" | `BETA_INVITE_CODES` is empty on the server; use `FRIENDS2026` or set your own |
| Signup succeeds but no email arrives | No SMTP; run with `ALLOW_DEV_CODES=true` (the app then shows the code) |
| Render build fails on `node scripts/migrate.js` | Database not ready yet or `DATABASE_URL` missing — re-run the deploy |
| CI fails with "Private address" | `API_BASE_URL` is a LAN/localhost URL; use the public one |
