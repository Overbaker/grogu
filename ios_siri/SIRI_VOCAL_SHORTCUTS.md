# Siri & Vocal Shortcuts Setup (Zero-Compile Option + Native AppIntents)

Grogu exposes a non-blocking voice endpoint at `http://<GROGU_GATEWAY_HOST>:18830/api/siri/command`.

## Option A: 60-Second Zero-Compile Apple Shortcuts + iOS/iPadOS 18 Vocal Shortcuts

1. Open the **Shortcuts** app on your iPhone/iPad and create a new shortcut named **`Ask Grogu`** (or **`问助手`**).
2. Add actions in order:
   - **Dictate Text** (Stop Listening: *After Pause*)
   - **Dictionary** -> Text key `text` = `Dictated Text`
   - **Get Contents of URL** -> `http://<YOUR_GATEWAY_TAILSCALE_IP>:18830/api/siri/command`, Method: `POST`, Request Body: `JSON` (`Dictionary`)
   - **Get Dictionary Value** -> Get `speak` from `Contents of URL`
   - **Speak Text** -> `Dictionary Value`
3. **(Hands-Free Upgrade on iOS/iPadOS 18+)** Open **Settings → Accessibility → Vocal Shortcuts**:
   - Add a new Vocal Shortcut bound to **`Ask Grogu`**.
   - Record a short trigger phrase (e.g., `"Grogu"`).
   - Speaking that phrase now routes straight to Grogu's Decision API + LLM brain without invoking Apple's default Siri dialog flow.

> **Why Grogu delays UI actions by 450ms**: After answering `"speak"`, Grogu intentionally waits `0.45s` before injecting taps/swipes so the Siri overlay orb cleanly dismisses first and never obscures target buttons.

## Option B: Native `AppIntents`

Add `GroguSiriIntents.swift` to any Xcode iOS/iPadOS target and set `GROGU_GATEWAY_URL` + `NSAppTransportSecurity -> NSAllowsLocalNetworking = YES` in `Info.plist`.
