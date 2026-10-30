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

## Point it at your backend

The APK needs a running WorldFriends API. The build ships with a placeholder URL,
so on first launch:

1. On the welcome screen tap the **⛁ (server)** icon in the top-right corner
   (or go to **Me → Settings → Server** later).
2. Enter your API URL, e.g. `https://worldfriends-api.onrender.com`, and tap
   **Test & save**. The app calls `/health` and only stores the URL if the server answers.
3. Sign in / create an account.

Running the backend locally instead: `cd backend && npm start` (listens on `:8080`),
then use your computer's LAN IP, e.g. `http://192.168.1.20:8080`. The phone must be on
the same Wi-Fi.

Signing up needs the beta invite code unless your email is on the allow-list:
`FRIENDS2026`.

## Notes

- Builds are signed with the Android **debug** key until you add `ANDROID_KEYSTORE_BASE64`,
  `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD` and `ANDROID_KEY_ALIAS` secrets —
  fine for sideloading, not for Play.
- Push notifications stay off until `GOOGLE_SERVICES_JSON_BASE64` is added as a secret;
  the app runs normally without it.
- Every build sets a higher `versionCode`, so a newer APK installs over the old one
  without uninstalling.
