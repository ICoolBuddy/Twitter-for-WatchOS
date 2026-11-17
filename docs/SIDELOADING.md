# Sideloading Perch

CI builds an **unsigned** IPA that contains both apps:

```
Payload/Perch.app                      iOS app        com.CHANGEME.perch
Payload/Perch.app/Watch/PerchWatch.app watchOS app    com.CHANGEME.perch.watchkitapp
```

## 1. Download the build

GitHub → **Actions** → latest green **Build** run → *Artifacts* → **Perch-unsigned-ipa**.
Unzip it to get `Perch-unsigned.ipa`.

Want different bundle IDs? Either edit `Config/Perch.xcconfig` (`PERCH_BUNDLE_ID`) or run the
workflow manually (**Run workflow** → `bundle_id`). The Watch app always becomes
`<bundle_id>.watchkitapp`, and its `WKCompanionAppBundleIdentifier` is `<bundle_id>`.

## 2. Sign it

Use your certificate + a provisioning profile that includes **both** UDIDs (iPhone 15 Pro **and**
Apple Watch Series 10). A **wildcard App ID** (`TEAMID.*`) is easiest because it covers both
bundle IDs with one profile.

- The **Watch app and everything inside it must be re-signed too**, not just the outer app.
  Most tools (Sideloadly, ksign/esign, zsign, FlareStore) do this when "sign nested bundles /
  deep sign" is on.
- If your tool **renames bundle IDs**, the Watch app's ID must stay `<new iOS id>.watchkitapp`
  and `WKCompanionAppBundleIdentifier` in `Watch/PerchWatch.app/Info.plist` must equal the new
  iOS ID. Otherwise iOS refuses to install the Watch app.
- No special entitlements are needed (no app groups, no push, no iCloud).

With `zsign` for example:

```sh
zsign -k cert.p12 -p 'password' -m wildcard.mobileprovision -o Perch-signed.ipa Perch-unsigned.ipa
```

## 3. Install

Install the signed IPA on the iPhone with your usual tool (Sideloadly, FlareStore, ideviceinstaller, …).

## 4. Install the Watch app

It usually installs automatically. If not: iPhone **Watch** app → *My Watch* → scroll to
**Available Apps** → **Perch** → *Install*.

## 5. Developer Mode (development-signed builds)

If the profile is a *development* profile, enable Developer Mode on the Watch:
**Settings → Privacy & Security → Developer Mode** (the iPhone needs it on too). The Watch restarts.

## 6. First run

1. Open **Perch** on the iPhone → *Log in with X* (or *Paste cookies instead*).
2. The session is sent to the Watch automatically (or tap *Sync to Watch now*).
3. Open Perch on the Watch. No phone handy? *Try demo mode* shows sample data.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "Unable to install — integrity could not be verified" (iPhone or Watch) | The **Watch UDID isn't in the profile**, or the **Watch bundle wasn't re-signed**. Add the Watch UDID, regenerate the profile, enable deep/nested signing. |
| iPhone app installs, Watch app never appears under Available Apps | Watch bundle ID isn't `<iOS id>.watchkitapp`, or `WKCompanionAppBundleIdentifier` doesn't match the (renamed) iOS ID. Turn off bundle-ID renaming or fix both values. |
| Watch app installs then immediately crashes / won't launch | Development profile without Developer Mode on the Watch, or the profile expired (free accounts: 7 days). |
| "Untrusted Developer" on iPhone | Settings → General → VPN & Device Management → trust your certificate. |
| Watch shows "Open Perch on your iPhone" forever | Open the iPhone app once (it activates WatchConnectivity), check *Apple Watch → Status*, tap *Sync to Watch now*. |
| Timeline error "endpoint has changed (404)" | X shipped a new web build. Tap *Refresh endpoints* (iPhone is fastest), or set the remote override URL to your repo's raw `endpoints.json`. |
| "Session expired (401)" | Log in again on the iPhone; the new session syncs to the Watch. |
| "Rate limited" | Perch backs off automatically (1 min, doubling, max 15 min). Just wait. |
| Search fails but timeline works | Search needs the signing key: iPhone → *Refresh signing key*. |
