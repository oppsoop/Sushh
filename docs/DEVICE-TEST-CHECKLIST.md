# Two-phone beta acceptance checklist

**Status: not yet performed.** Use two physical Android phones, two distinct email accounts and a real HTTPS deployment. Record date, APK version and signing fingerprint, Android versions, phone models, Wi-Fi/mobile network and result for each item. Never put passwords, personal message contents or full device identifiers in a shared report. Set up backups and obtain tester consent before using real data.

| Area | What to do | Pass evidence |
| --- | --- | --- |
| Install | Install the same signed universal APK on both phones. Open the server icon and save the real HTTPS API URL. | Both open, show correct backend health; record package/version/fingerprint. |
| Signup | Invite both emails; register with passwords and enter codes received by email. Try an unknown email without invite. | Approved users can enter; uninvited email is refused; no dev code shown. |
| Google | On Firebase-configured build, register with Google using an approved email/invite; then sign out and in again. | Both flows work, same account persists. |
| Usernames | Try invalid/prohibited name, claim a unique name, search exact/partial, try another person's name. Check change and reuse cooldowns. | Helpful errors and only one user owns each name. |
| Friends | Send/accept request, follow, open a profile, unfriend and block/unblock. | Relationship state agrees on both phones; blocked accounts cannot interact. |
| Chat | Send messages both ways, open chat, close/reopen, verify delivery/read indicators and ordering. | Messages persist once with sensible status. |
| Offline | Turn off sender internet; send text, photo and a file. Kill and restart the app, reconnect, wait. Repeat with unstable network. | Queue survives and sends each item once; recipient gets usable media. |
| Media | Send camera/gallery photo, video, voice note and file. Play/open and save to Downloads on the other phone. | Media plays/downloads correctly; verify failures with large/unsupported files. |
| Push | Grant notification permission; background/kill one app and send a message/friend request. Tap notification. | Correct notification appears and opens relevant screen; no duplicate. |
| Audio call | Call both directions on Wi-Fi, mobile and mixed networks with TURN; accept, decline, hang up, reconnect, repeat with recipient backgrounded. | Both hear each other, call ends cleanly, missed/background behavior is recorded. |
| Video call | Repeat audio cases with camera permission, switch camera and mute. | Both video/audio streams appear; controls work and app survives interruptions. |
| Social | Create/view/like/comment on posts and stories, check intended visibility, block/report, wait for a story to expire. | Only authorized users see content and expiration behaves correctly. |
| Feedback | Submit feedback with and without a screenshot; owner checks `/v1/admin/feedback`. | Message, app/device info and authorized screenshot are visible to owner. |
| Translation | With provider configured, translate selected message; without it, try again. | Correct language selection; clear unavailable error if no provider. |
| Session/security | Restart app, expire a token, change server, sign out/in. Delete a disposable account. | Session refresh works, new server never receives old tokens, deletion takes effect. |
| Recovery | Restart/redeploy backend and restore backup in a separate test environment. | Database and media remain intact; signed update installs with the same certificate. |
| Privacy/diagnostics | Generate a safe test crash and inspect Firebase after enabling it. Review analytics events. | Crash appears; no message content is deliberately sent as analytics parameters. |

Record failures and fix them before wider distribution. A pass on backend automated tests or a successful APK signature does not substitute for this checklist.
