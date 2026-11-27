# Changelog

## 1.1.0

### Highlights
- **No Node.js required.** The macOS app now talks to the bulb natively (Swift + Network.framework). It runs as a single universal binary (Apple Silicon and Intel), with no background service and no open network port.
- **Redesigned popover.** The power button lives in the header and glows in the bulb's color. A **White / Color** switch shows only the controls for the active mode, and the popover height follows its content.
- **Favorites.** Save the current light in one tap, apply it instantly (color and brightness change together via `set_scene`), and rename, delete or drag to reorder.
- **Control from other apps.** The new `yeelight-quickcontrol://` URL scheme supports toggle, on/off, brightness, white, color and favorites. Bundled action helpers let tools that can only "open an application" (such as Logi Options+ Smart Actions) control the light.
- **Cleaner settings.** A compact panel that fits the popover, with a real "Start at login" switch that reports approval and errors.

### Reliability
- Reconnects automatically with backoff when the bulb drops, and re-discovers it if its IP address changed.
- Commands are rate-limited below the bulb's quota, and slider drags are coalesced, so the bulb no longer disconnects the app.
- Fixed command replies occasionally overwriting the bulb state (request IDs are now matched).
- Fixed HSV color mode being shown incorrectly.
- Network scan verifies devices actually speak the Yeelight protocol.

### Security
- The app no longer serves anything on a network port. The optional standalone server (`npm start`) now validates the `Host` header, requires JSON for state-changing requests, and only scans on POST.

### Developer
- Integration tests for both controllers against a fake bulb (`npm test`, `npm run test:macos`) and a WKWebView self-test, all run in CI.
