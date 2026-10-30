# WorldFriends — install the beta APK

## Download

Latest build (universal APK, works on every Android phone, ~103 MB):

https://github.com/oppsoop/Sushh/releases/latest/download/WorldFriends-1.0.0-universal.apk

Smaller builds (same app, one CPU architecture each):

| File | Use when |
| --- | --- |
| `WorldFriends-1.0.0-arm64-v8a.apk` (~42 MB) | Any phone from ~2017 onwards (recommended) |
| `WorldFriends-1.0.0-armeabi-v7a.apk` (~34 MB) | Older 32-bit phones |
| `WorldFriends-1.0.0-x86_64.apk` (~47 MB) | Emulators / x86 tablets |
| `WorldFriends-1.0.0-universal.apk` (~103 MB) | Not sure which one you need |

All builds are on the [releases page](https://github.com/oppsoop/Sushh/releases).

## Install

1. Download the APK on the phone (or transfer it over USB).
2. Open the file. Android will warn about an unknown app — tap **Settings → Allow from this source**, then **Install**.
3. Android 8+ asks once for **Install unknown apps** permission for the app you downloaded with (Chrome/Files). That is expected for a beta that is not on Play.
4. Open **WorldFriends**.

Minimum Android version: 7.0 (API 24).

## Get a server (pick one)

The app is only a client; it needs the WorldFriends API running somewhere it can reach.

### A. On this computer, with Docker (recommended, ~5 minutes)

```bash
git clone https://github.com/oppsoop/Sushh.git
cd Sushh
docker compose up -d --build      # starts Postgres + the API on port 8080
```

Check it: <http://localhost:8080/v1/health>

Then find your computer's LAN IP:

- Windows: `ipconfig` → "IPv4 Address" (looks like `192.168.1.20`)
- macOS: `ipconfig getifaddr en0`
- Linux: `hostname -I`

In the app's **Server** box enter `http://192.168.1.20:8080` (your own IP, port 8080)
and tap **Test & save**. The phone must be on the same Wi-Fi as the computer.
Windows will ask to allow Node/Docker through the firewall the first time — allow
private networks.

### B. On the internet, for free, with Render

1. Push/keep this repo on GitHub.
2. Render → **New → Blueprint** → pick this repository (it reads `render.yaml`).
3. Render creates the API and a Postgres database. Wait for "Live".
4. Copy the URL, e.g. `https://worldfriends-api-xxxx.onrender.com`, and paste it
   into the app's Server box (no trailing slash, no `/v1`).

Free Render instances sleep after 15 minutes idle; the first request afterwards
takes ~30 s. Media stored on the free instance is wiped on redeploy.

### C. On this chat's sandbox (temporary)

While this session is running the API is live at:

`https://8080-iphkpfg1jks2ctve9t3j9.e2b.app`

Paste that into the app's Server box. It stops working when the sandbox shuts down.

## Point it at your backend

The APK needs a running WorldFriends API. The build ships with a placeholder URL,
so on first launch:

1. On the welcome screen tap the **⛁ (server)** icon in the top-right corner
   (or go to **Me → Settings → Server** later).
2. Enter your API URL, e.g. `https://worldfriends-api.onrender.com`, and tap
   **Test & save**. The app calls `/health` and only stores the URL if the server answers.
3. Sign in / create an account.

Without Docker: `cd backend && npm install && env DATABASE_URL=... node scripts/migrate.js && npm start`.

Signing up needs the beta invite code unless your email is on the allow-list:
`FRIENDS2026`. When the server runs with `ALLOW_DEV_CODES=true` (the Docker setup does),
the email verification code is filled in automatically instead of being emailed.

## Notes

- Builds are signed with the Android **debug** key until you add `ANDROID_KEYSTORE_BASE64`,
  `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD` and `ANDROID_KEY_ALIAS` secrets —
  fine for sideloading, not for Play.
- Push notifications stay off until `GOOGLE_SERVICES_JSON_BASE64` is added as a secret;
  the app runs normally without it.
- Every build sets a higher `versionCode`, so a newer APK installs over the old one
  without uninstalling.
