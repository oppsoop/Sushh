# WorldFriends — private Android beta

WorldFriends is a Flutter Android app with a Node.js/PostgreSQL API for a small friends-and-family beta. The code includes accounts, usernames, chat, media, friends, stories, posts, calls, reporting and feedback.

> **Before sharing:** this repository does not create or operate your server or Firebase project. The current unconfigured APK uses `https://worldfriends-api.example.com`, which is a placeholder, not a working service. Email, Google sign-in, push, Firebase Crashlytics/Analytics and dependable calls need your own services configured. Backend tests pass, but installation, notifications and audio/video calls have **not** yet been verified on two physical phones. Follow the checklist in [docs/DEVICE-TEST-CHECKLIST.md](docs/DEVICE-TEST-CHECKLIST.md) before inviting people. Messages are **not end-to-end encrypted**: the service operator can access server-side content.

## What you need

- A computer, a GitHub account with access to this repository, and two Android phones (Android 7.0 or newer).
- An account with a hosting provider, a PostgreSQL database and persistent storage. Hosting, a database, storage and TURN may cost money; check provider prices.
- A real email address with SMTP sending enabled. This delivers signup and password-reset codes.
- A Firebase project in your Google account for Google sign-in, push notifications, Crashlytics and Analytics.
- A TURN relay for reliable calls across restrictive networks. STUN alone is not enough in all networks.
- The **matching signing backup and private decryption key** delivered with your APK. Keep both private and backed up; see [signing and updates](#signing-and-updates).

Do not send passwords, service-account keys, signing keys or admin tokens in chat. Put them only in the hosting/GitHub secret settings described below.

## 1. Put the backend online (beginner example)

This is one possible route using [Render](https://render.com/); another HTTPS host with Node 20+, PostgreSQL, WebSockets and persistent storage can also work. Render's screens and prices can change. You own the accounts and billing; nothing is automatically provisioned by this repository.

1. Create a Render account and link the GitHub account that can see `oppsoop/Sushh`.
2. Create a **PostgreSQL** database. Choose a region and a plan appropriate for your beta; save the **Internal Database URL** from its dashboard. Keep the database private, enable backups, and use the same region for the web service.
3. Create a **Web Service** from `oppsoop/Sushh`, branch `arena/042fd40d-sushh` (or the branch containing this code). Set:
   - Root directory: `backend`
   - Runtime: Node
   - Build command: `npm ci`
   - Start command: `npm run migrate && npm start`
   - Health-check path, if offered: `/v1/health`
4. Select a **paid** service plan that supports a persistent disk. Attach a disk mounted at `/var/data/worldfriends`. Render's free/ephemeral filesystem loses uploaded files on redeploy. Only files inside the mount path persist; back up the disk as well as the database. A disk-attached service should stay at **one instance** for this beta. See [Render persistent disks](https://render.com/docs/disks).
5. In the service's **Environment** settings, add the following. Never commit the real values. Generate two different long random secrets with a password manager or, on a computer with OpenSSL, run `openssl rand -hex 32` twice.

   | Name | Value |
   | --- | --- |
   | `NODE_ENV` | `production` |
   | `PUBLIC_URL` | Your service's full HTTPS URL, e.g. `https://your-service.onrender.com`, no trailing slash. Render shows it on the service page; set it after creating the service if needed. |
   | `DATABASE_URL` | The PostgreSQL **internal** URL from step 2. |
   | `DATABASE_SSL` | `true` for TLS. Certificate verification is on by default; if your database provider supplies a CA certificate, set `DATABASE_CA_CERT` to its PEM. Do not add `sslmode` parameters to the URL that override the client settings. |
   | `DATABASE_SSL_VERIFY` | `true` (default) verifies the database identity. Some providers use self-signed certificates: obtain their trusted CA where possible. As a last resort on a private Render internal network, `false` permits TLS without verifying the server, which risks interception. |
   | `JWT_SECRET` | First randomly generated secret (at least 32 characters). Keep stable across deploys. |
   | `ADMIN_TOKEN` | Second random secret, different from `JWT_SECRET`. Keep private. |
   | `SMTP_URL` | Your actual SMTP connection URL, including account and app password. See below. |
   | `MAIL_FROM` | An address your SMTP provider allows, e.g. `WorldFriends <you@gmail.com>`. |
   | `STORAGE` | `local` |
   | `MEDIA_DIR` | `/var/data/worldfriends` |
   | `BETA_MODE` | `true` |
   | `BETA_ALLOW_ANY_EMAIL` | `false` |
   | `BETA_ALLOWED_EMAILS` | Optional comma-separated emails, e.g. `you@example.com,friend@example.com`. Only these people or invite-code holders can register. |

   Example for a Gmail account with 2-step verification and an **app password**: `smtps://you%40gmail.com:APP_PASSWORD@smtp.gmail.com:465`. Replace the username and password; `%40` represents `@`. Remove spaces from the app password and percent-encode any special characters. Some accounts cannot create app passwords; in that case use a transactional SMTP provider. `SMTP_URL` is required in production, and signup will fail if mail cannot be delivered. Do not use your ordinary Google password.
6. Deploy. Open `https://YOUR-SERVICE/v1/health` in a browser. It should say `status: "ok"` and `database: true`. `smtp`, `push`, `googleSignIn`, `translation`, and `turn` show whether the corresponding configuration is present; a `true` flag is **not** proof that delivery or calling was tested.
7. Check the service logs for migration or SMTP errors. Back up the PostgreSQL database and disk, then test restoring both. Losing either can lose user data. Avoid putting real people on a service until this and the device checklist pass.

For a local developer example see [`backend/.env.example`](backend/.env.example). Do not run production with development codes or example secrets.

### Invite testers

An address in `BETA_ALLOWED_EMAILS` can sign up without a code. For a limited-use code, in a terminal on your own computer run this after replacing the two placeholders locally (do **not** post the real token):

```sh
curl -X POST 'https://YOUR-SERVICE/v1/admin/invites' \
  -H 'Content-Type: application/json' \
  -H 'X-Admin-Token: YOUR_PRIVATE_ADMIN_TOKEN' \
  -d '{"maxUses": 1, "email": "friend@example.com"}'
```

The response contains an `invite.code`. Send it privately to that friend. Omit `email` for a code usable by any address; `maxUses` limits registrations. Optional `expiresAt` is an ISO-8601 time such as `2027-01-01T00:00:00Z`. You can also set `BETA_INVITE_CODES` for shared codes, but those have no per-code usage limit. To inspect the latest feedback or reports, use the same header on `GET /v1/admin/feedback` or `GET /v1/admin/reports`; screenshot URLs are short-lived bearer links, so keep them private. Protect the admin token and do not put it in URLs.

## 2. Configure Firebase and Google sign-in

You must create the Firebase project in **your** Google account. The app cannot do this for you without access to that account.

1. Open [Firebase Console](https://console.firebase.google.com/), create a project, and add an **Android** app with the exact package name `com.mycompany.worldfriends`. Add the SHA-1 and SHA-256 certificate fingerprints from the signature-verification file for the APK **and the same signing key you will use for updates**. Download `google-services.json`; do not commit it.
2. In Firebase Authentication, enable the Google sign-in provider. Find its **Web application OAuth client ID** (not the Android client ID). Set backend environment variable `GOOGLE_CLIENT_ID` to it. For the app build, set GitHub Actions variable `GOOGLE_SERVER_CLIENT_ID` to the same value. The Google button appears only in a build with this client ID.
3. For push, create a Firebase service-account JSON key with permission to send Firebase Cloud Messaging messages. Store its **entire JSON** as backend secret `FCM_SERVICE_ACCOUNT_JSON` using your hosting dashboard, not in the repository. Enable the Firebase Cloud Messaging API as required by your project. Restart the service. `/v1/health` should show `push: true`, but test actual notifications on phones.
4. Enable Crashlytics and, if wanted, Google Analytics in the project. The app initializes them only when Firebase configuration is included at build time. The app's analytics event/parameter allowlists do not include message text, but Firebase/Google process their own diagnostic data under their terms. Obtain tester consent and review the data settings.
5. Add `GOOGLE_SERVICES_JSON_BASE64` as a GitHub Actions **secret**: base64-encode the entire `google-services.json` into one line and paste the result. On macOS/Linux, for example, `base64 < google-services.json | tr -d '\n'` (do not paste the output into chat). Set Actions variable `API_BASE_URL` to your real HTTPS service URL, and `GOOGLE_SERVER_CLIENT_ID` as above. Then rebuild with the **same signing key** as below.

GitHub repository variables and secrets are under **Settings → Secrets and variables → Actions**. The service-account key belongs on the backend, not in the APK or GitHub repository. The `google-services.json` file itself is configuration, not a substitute for the private service-account key.

## 3. TURN and optional translation

For calls, provide a TURN server (for example a separately hosted coturn instance) with TLS/UDP ports open and REST/shared-secret authentication enabled. Set backend `TURN_URLS` to a comma-separated list such as `turn:turn.yourdomain.com:3478?transport=udp,turns:turn.yourdomain.com:5349?transport=tcp`, and set `TURN_SHARED_SECRET` to the same strong secret configured on the TURN server. The backend issues short-lived credentials. Restrict and monitor relay use, firewall it appropriately, and test both Wi-Fi and mobile networks. A reliable, always-on TURN server and real phones are required to verify calls; FCM must also be configured to alert backgrounded recipients.

Translation is optional: set `DEEPL_API_KEY` or `GOOGLE_TRANSLATE_API_KEY` on the backend. Translation sends the selected text to that provider and may incur charges; do not configure a key if testers have not agreed. With no key, the app reports that translation is unavailable.

## 4. Download and install the APK

1. Open the successful **Android beta build** run for this branch under [GitHub Actions](https://github.com/oppsoop/Sushh/actions/workflows/flutter-build.yml). Artifacts require GitHub access and expire; download them promptly. `worldfriends-universal-apk` contains the APK for normal use. `worldfriends-split-apks` contains ABI-specific APKs; install **one** matching your device (most modern physical phones are `arm64-v8a`). Do not install every split. The same run's `encrypted-signing-key-backup` belongs to those APKs if CI generated the key.
2. Transfer the universal APK to the phone, open it with Files, and allow **install unknown apps** for the file manager/browser if Android asks. Install only builds you trust. You can turn that permission off afterward.
3. On the welcome screen, tap the small **server icon** at the top right. Enter your deployed `https://...` URL without `/v1`, tap **Test & save**, and then sign up with an approved email or invite code. This setting allows an existing APK to point at your backend, but changing servers signs you out and deletes queued unsent messages. Never enter an untrusted server.
4. That server setting does not add Firebase to an already-built APK. To enable Google sign-in, push and crash reporting, complete step 2 and rebuild with the same signing key. Reinstall/update the new APK, and run the two-phone checklist. Permit microphone, camera, notifications and storage access when prompted.

### Firebase App Distribution for trusted testers

In Firebase Console, select your Android app → **App Distribution** → **Get started** → **Releases**, upload the configured universal APK, add individual tester email addresses or a private tester group, add release notes, and click **Distribute**. Each tester accepts their email invitation on their Android phone, downloads and installs the app. Remove testers who should no longer receive builds. See the [official Android distribution guide](https://firebase.google.com/docs/app-distribution/android/distribute-console). App Distribution does not host your API or replace the invite gate.

## Signing and updates

The workflow builds package `com.mycompany.worldfriends`, version name `1.0.0`, version code `1`, plus universal and ABI APKs, and runs `apksigner verify` for each. If signing secrets were absent, that run generated a fresh release key and encrypted the keystore **and its passwords** to the backup-recipient public certificate. Different generated-key runs have different keys. Always save the APK and encrypted backup from the **same successful run**. Also save the separately delivered `backup-decryption-key.pem` in a private, durable location. Neither the private key nor decrypted keystore should be committed or shared with testers.

To recover the signing files on a trusted computer with OpenSSL:

```sh
openssl cms -decrypt -binary -inform DER \
  -in worldfriends-signing-backup.enc -inkey backup-decryption-key.pem \
  -out worldfriends-signing-backup.tar.gz
tar -xzf worldfriends-signing-backup.tar.gz
```

This extracts `release-key.p12` and `key.properties` (containing passwords). Protect them as secrets. In GitHub Actions secrets set `ANDROID_KEYSTORE_BASE64` to a single-line base64 encoding of `release-key.p12`, `ANDROID_KEYSTORE_PASSWORD` to the `storePassword` value, `ANDROID_KEY_PASSWORD` to `keyPassword`, and `ANDROID_KEY_ALIAS` to `keyAlias`. Then run **Actions → Android beta build → Run workflow** on this branch. Verify the new APK certificate fingerprint matches the original. Only a same-package, same-certificate build can update installed apps without uninstalling; losing the signing key can force a new install and data loss. Increase Android version code for later releases; the workflow currently deliberately builds the initial `1.0.0`/`1`.

## Developer checks and limitations

- Backend: Node 20+ and PostgreSQL required. `cd backend && npm ci && TEST_DATABASE_URL='postgresql://...' npm test`. **The tests drop and recreate the public schema of the supplied test database. Never use a real database.**
- Flutter: `cd app && flutter pub get && flutter analyze && flutter test`. The Android workflow also builds and verifies release APKs.
- This beta uses a single backend instance for in-memory WebSocket presence and rate limits; it is not a horizontally scaled production service. Media URLs are time-limited bearer links and can be used by anyone who obtains them until expiry. Revoking access may not invalidate already-issued links immediately.
- Calls, background notification behavior, media compatibility, security, performance, accessibility and recovery still need real-device testing. The server, Firebase account, SMTP, TURN and translation provider were not provisioned automatically. Do not describe an unconfigured build as production-ready.
