# iDroidik Setup (iOS app)

On-device setup for [iDroidik](https://github.com/a-user-of-python/iDroidik) — Android 16 on iPhone 7.

This is a jailbreak utility app (installed via Sileo as a `.deb`). It does everything
`setup-device.sh` does, but **on the phone itself** — no Mac needed for setup:

1. **Preflight** — verifies iPhone 7 (iPhone9,1/9,3), iOS 15.x, running as root, enough free space
2. **APFS volume** — finds or creates the "Android" volume (additive; iOS is never touched)
3. **Image download** — fetches `nand-a16` parts from the GitHub release, verifies per-part
   and whole-image sha256, writes to the Android volume
4. **Firmware** — copies touch + Wi-Fi firmware from the phone's **own iOS** into the
   Android volume. Nothing is downloaded. (This is the legal requirement.)
5. **userdata.img** — provisions persistent `/data` with nonce-tagged blocks; the nonce
   is saved to `userdata-a16.conf` for the boot script

After setup, boot Android from a computer over USB (tethered checkm8 boot). Reboot to
return to iOS.

## Safety

- NEVER restores or erases the iPhone. Only ADDS an APFS volume and writes inside it.
- All destructive operations (volume creation) require explicit confirmation in the UI.
- The app refuses to run unless `getuid() == 0` (setuid root via the `.deb` postinst).
- No Apple firmware is bundled or downloaded — it is generated on-device from the
  user's own iOS, exactly like `tools/gen-firmware.sh`.

## Building

Pushing to `main` triggers `.github/workflows/build-deb.yml`, which builds the
unsigned app with `xcodebuild` and packages the `.deb`. Download the artifact from
the Actions run.

To build the `.deb` locally from a compiled `.app`:

```bash
cd setup-app/debian
./build-deb.sh /path/to/iDroidikSetup.app
```

## Installing

Install `com.idroidik.setup_1.0_iphoneos-arm.deb` via Sileo. The postinst script:

- `chown root:wheel` + `chmod 4755` the binary (setuid root)
- Runs `uicache` so the icon appears

The app icon appears on the home screen as "iDroidik Setup".

## Project layout

```
setup-app/
  iDroidikSetup.xcodeproj/      # Xcode project (generated)
  iDroidikSetup/
    iDroidikSetupApp.swift      # App entry
    Info.plist
    Assets.xcassets/
    Core/
      Shell.swift               # Process wrapper (runs as root)
      SetupState.swift          # Observable wizard state
      SetupEngine.swift         # Setup logic (mirrors setup-device.sh)
    Views/
      ContentView.swift         # Wizard container + step runner
      StepViews.swift           # Per-step UI (large text, high contrast)
  debian/
    DEBIAN/control              # .deb metadata
    DEBIAN/postinst             # setuid root + uicache
    build-deb.sh                # Local .deb builder
  .github/workflows/build-deb.yml
```
