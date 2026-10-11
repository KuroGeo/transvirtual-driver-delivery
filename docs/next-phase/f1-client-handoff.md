# F1 navigation client candidate

Based on approved planning `5f32b66` and main `53c2089`. The 2026-10-12 authorization covers F1 only. See [execution contract](../../harness/project/next-phase/f1-execution.md) and [current evidence](../../harness/reports/f1-navigation.md). F2/F3 remain prepared; production is no-go.

## Driver flow

Open a stop from the map, Browse list or nearest stop, then **Navigate**. Directions keeps the original delivery, filters, list session and map alive. **View delivery details** returns to the original detail; its close button returns to the same source. A changed session/generation/dataset/stop invalidates the old sheet.

Apple Maps and Google Maps are explicit native choices. **Browser directions** is an explicit browser alternative; an unavailable application/mode or failed launch keeps the choices and **Copy address** available. A successful launch means the map accepted directions, not that navigation started or a delivery arrived. Background/resume after that receipt changes the visible handoff state; all delivery confirmation remains manual.

**Use my location** requests one foreground location fix. Denied permission, disabled location, timeout or stale/imprecise fixes leave the start to the map app. Drivers can explicitly confirm starting coordinates instead. There is no background tracking. On Android a supplied start requires a native-only HTTPS mode that the pinned launcher does not support, so that Google option reports unavailable and browser directions preserves the start; using a Maps-chosen start enables the native navigation scheme. No silent origin dropping.

## Road configuration

The production default is `UnavailableThirdPartyRoutePort`. There is no licensed client road supplier configuration in this candidate, so no in-app road line, distance or ETA is fabricated. The existing workbench's fixed reference and straight-line list distances retain their original labels. External Maps navigation works without an in-app road service. No own routes/matrix backend, proxy, service secret or third-party credential was added.

A future supplier implements the narrow `ThirdPartyRoutePort` and supplies verified license/configuration. Requests contain only origin/destination coordinates, UTC departure and driving mode. Local account/dataset/stop/request identifiers, tokens, notes and operation IDs are not sent. Repository responses require provider/config revision, fresh source timestamps/expiry, origin/destination/departure/arrival, duration basis and finite road geometry. Route overlays additionally require verified display permission. No route cache is persisted without supplier cache terms. Explicit refresh retries once with an eight-second timeout. Scope, target/input/attempt changes reject late results.

Current return context is a retained in-process session. After an OS process ends, the client reopens the workbench and durable deliveries/outbox; it does not revive an unverified old navigation session or claim arrival. Account switching is exercised through the future NavigationScope interface, not implemented login/account storage.

## Reproduce

Flutter 3.44.2 / Dart 3.12.2, locked `geolocator` 14.1.1 and `url_launcher` 6.3.3. Shared dependencies/platform/UI assembly have one owner. Refreshing a changed dependency lock is an explicit leased NP10 operation; normal checks enforce the lockfile.

```sh
python3 harness/run.py pub
python3 harness/run.py quality --isolated
python3 harness/f1.py collect-host
python3 harness/run.py native --scope workbench --configuration local-client --driver-target integration_test/f1_navigation_driver.dart --timeout 1200
```

Native checks run on a task-owned background iOS simulator with three real OS launches, native SQLite, raw driver observations/actions and screenshots. The private gateway is labeled `controlled-navigation-fixture`; it verifies Flutter preview/failure/return and durable queue protection, not actual external Maps/GPS/roads. Existing N1–N7 and production gates retain their scope. Real Maps/GPS/road supplier/physical-device tests and #31/#32/#33 remain separate acceptance boundaries. Never activate the user's simulator/window/tab to collect this evidence.

F1 host/native gates reread the exact candidate, named test logs and hashed original evidence. Missing, stale, wrong source or fixture presented as live is refused. CI collects the host gate after full quality; production eligibility remains false.
