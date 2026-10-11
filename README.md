<p align="center"><b>English</b> · <a href="README.zh-CN.md">简体中文</a></p>

<h1 align="center">Ocean Delivery</h1>
<p align="center"><b>Know every stop. Keep delivering offline.</b><br>看清每一站，离线也能继续工作。</p>
<p align="center">Flutter · SQLite · Transactional outbox · iOS simulator Demo</p>

A map-first Flutter driver workbench with 30 synthetic demo stops around Sydney. Find a delivery, record its outcome offline, restart the app, and reconnect to watch the pending queue receive **simulated confirmations**.

<p align="center">
  <a href="https://kurogeo.github.io/transvirtual-driver-delivery/index.en.html#demo"><b>▶ Watch the 82-second demo</b></a> &nbsp; · &nbsp;
  <a href="https://kurogeo.github.io/transvirtual-driver-delivery/index.en.html">English presentation</a> &nbsp; · &nbsp;
  <a href="https://github.com/KuroGeo/transvirtual-driver-delivery/releases/tag/v0.1.0-report.3">Download report & video</a> &nbsp; · &nbsp;
  <a href="#run-the-interview-demo">Run it yourself</a>
</p>

<p align="center">
  <a href="docs/report/media/showcase.webp"><img src="docs/report/media/showcase.webp" alt="Ocean Delivery: real Flutter iOS simulator captures of the map workbench and delivery list" width="100%"></a>
</p>

The cover uses original **iOS 26.4 simulator screenshots**, captured from the formal Flutter Demo. Demo confirmation is simulated; one local update was waiting to sync during capture. [Capture provenance](assets/readme/capture-manifest.json).

## See the complete loop in 82 seconds

<p align="center"><a href="https://kurogeo.github.io/transvirtual-driver-delivery/index.en.html#demo"><img src="docs/report/media/ocean-delivery-poster.webp" width="100%" alt="Play the native demo: save two deliveries offline, restart, restore the queue, and receive simulated confirmations"></a></p>

**Save two results offline → restart the OS process → restore two queued updates → confirm → restart with queue zero.**

[Watch the compressed native video in the report](https://kurogeo.github.io/transvirtual-driver-delivery/index.en.html#demo). It shows two Offline saves, actual OS process restarts, durable recovery and simulated matching confirmations. The recording reuses a historical workbench build and its original dataset snapshot, rather than the replacement synthetic public CSV. It uses the instrumented native workbench entrypoint with controlled HTTP; the formal app entrypoint remains the run command below. No voiceover, so it can be narrated during the interview. [Recording proof](docs/report/media/demo-proof.json).

**Compressed downloads:** [MP4 · 2.80 MB](https://github.com/KuroGeo/transvirtual-driver-delivery/releases/download/v0.1.0-report.3/ocean-delivery-demo-82s.mp4) · [Bilingual offline report + video ZIP](https://github.com/KuroGeo/transvirtual-driver-delivery/releases/download/v0.1.0-report.3/ocean-delivery-bilingual-report-20261012.zip).

## Why offline work survives

<p align="center"><img src="assets/readme/offline-flow.svg" width="100%" alt="Save: result and outbox commit together. Restore: a new process reopens the database. Confirm: a matching ACK is persisted before the operation leaves the queue."></p>

1. **Save.** Result and outbox snapshot commit in one SQLite transaction; a failed write rolls back the whole change.
2. **Restore.** A new OS process reopens the same database, recovering outcomes, reasons, the Offline setting and operation identities.
3. **Confirm.** Serial sync accepts only matching operation, dataset and stop identities. Confirmation and outbox removal commit together.

<details>
<summary><b>Technology choices, alternatives and configuration</b></summary>

| Choice | Why it fits this slice | Cost / when I would change it |
| --- | --- | --- |
| **sqflite / SQLite** | A delivery result and its outbox snapshot commit in one transaction; constraints and versioned migrations are explicit. | SQL and mapping are hand-maintained. Consider Drift when typed queries and reactive reads justify code generation. |
| **Transactional outbox + serial sync** | Stable operation/dataset/stop identities survive process death. A result is confirmed only after a matching ACK is durably recorded. | Extra table and confirmation transaction; serial throughput. Add batching only with a defined backend contract. |
| **ChangeNotifier / Listenable + constructor injection** | SDK-native observable ViewModels and easily replaced dependencies suit one workbench. | Subscription, disposal and async ownership require discipline. Reassess Riverpod/Cubit when shared dependencies and async composition grow. These were alternatives, not an implemented migration. |
| **UI / data layers, MVVM + Repository** | Views render; ViewModels own short-lived interaction; Repository owns lifecycle rules and persistence; Transport owns transmission. | More boundaries than a single widget. Introduce use cases when cross-feature orchestration becomes complex. |
| **flutter_map + marker clustering** | Custom Flutter markers align with the selected prototype, search, status and accessibility semantics. | Dense-marker performance and provider licensing need their own acceptance. Cached tiles do not guarantee a complete offline region. |
| **Typed panels and return origin** | List → detail returns to the list with context; map/nearest → detail returns to the map. | More explicit return tests. Add declarative routing when login, deep links and independent screens exist. |

A pending stop may transition only to **completed** or **failed**. Both outcomes are terminal. The Repository checks this in logic and the database update is conditional on `pending`; hiding buttons alone is insufficient. Failed results require a reason; original CSV failures have unknown historical reasons and are not assigned invented values.

**Configuration matters:** `OCEAN_MODE=demo` uses `ocean_delivery-demo.sqlite` and simulated confirmations. The default `local-client` uses a separate database and `UnavailableTransport`; it preserves the queue and reports service unavailability. No real backend is connected.

</details>

## Run the interview demo

**Verified target:** Apple Silicon macOS, Xcode with the **iOS 26.4** simulator runtime, **iPhone 17 Pro**. The current iOS project uses Swift Package Manager. Install Flutter **3.44.2 / Dart 3.12.2** and make `flutter`, `python3`, and Xcode's `xcrun` available in your terminal. Android is scaffolded but is not the verified submission target.

Run these commands from the repository root. They create a dedicated simulator and leave its data intact for the restart demonstration:

```sh
flutter --version
xcrun simctl list runtimes
OCEAN_DEMO_DEVICE=$(xcrun simctl create 'Ocean Delivery Interview' \
  com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
  com.apple.CoreSimulator.SimRuntime.iOS-26-4)
xcrun simctl boot "$OCEAN_DEMO_DEVICE"
xcrun simctl bootstatus "$OCEAN_DEMO_DEVICE" -b
python3 harness/run.py pub
cd app
flutter run --target lib/main.dart --device-id "$OCEAN_DEMO_DEVICE" \
  --dart-define=OCEAN_MODE=demo
```

To view your dedicated device, open Simulator yourself and select **Ocean Delivery Interview** from its device menu. The commands do not select an existing device or erase a database. If iOS 26.4 is missing, install that runtime in Xcode before running them. Public OpenStreetMap tiles require internet access; tile failure still permits list browsing and local delivery updates.

The Release includes an already built **arm64 iOS simulator debug Demo** and installation instructions. It is a convenience artifact, not an iPhone IPA or a production-signed build. The source above is the canonical development entry point.

<details>
<summary><b>Optional live walkthrough and actual process restart</b></summary>

| Time | Action | Expected result |
| --- | --- | --- |
| 0:00–1:00 | Browse the map/list, filter by status, switch **Offline**. | 30 stops; initial status counts are 24 pending, 3 completed, 3 failed. |
| 1:00–2:00 | Complete a pending stop. Fail another, selecting a reason or entering nonblank **Other** text. | Two locally saved terminal results; visible pending-sync count increases by two. |
| 2:00–3:00 | Quit and relaunch the installed app on the same simulator. | Status, failure reason, Offline setting and queued operations survive. |
| 3:00–4:00 | Switch **Online**. | Demo sends serially; matching confirmations are committed before queue entries disappear. |
| 4:00–5:00 | Restart again; explain the consistency rules. | Confirmed entries stay confirmed and are not sent again. |

For a real OS restart, copy the device ID printed by `simctl create` into a second terminal, then run:

```sh
OCEAN_DEMO_DEVICE='paste-the-created-device-UDID-here'
xcrun simctl terminate "$OCEAN_DEMO_DEVICE" dev.oceandelivery.oceanDelivery
xcrun simctl launch "$OCEAN_DEMO_DEVICE" dev.oceandelivery.oceanDelivery
```

Hot reload or hot restart is not the persistence demonstration. Keep the same installation and database. The full repeatable N1 driver and its controlled HTTP fixture are documented in [app/README.md](app/README.md).

</details>

## Tests and evidence

From the repository root:

```sh
python3 harness/run.py quality --isolated
python3 harness/run.py test --target test/data/sqlite_delivery_repository_test.dart --isolated
python3 harness/run.py test --target test/sync/sync_coordinator_test.dart --isolated
```

The first targeted suite covers terminal-state rejection, mandatory failure reasons, transactional rollback and real SQLite reopen. The second covers serial sync, identity matching, failed confirmation persistence and duplicate triggers. The quality command additionally enforces locked dependencies, formatting, static analysis, architecture/requirement checks and all host/widget tests.

Recorded application-code baseline: **196 Flutter tests; 166 Harness tests** (Darwin: 165 pass + one Linux-only N/A; Linux CI: 166 pass). The PR37 N7 repair was accepted on iPhone 17 Pro and iPhone 16 at the maximum system text size, plus a normal-size configuration. These are **targeted simulator checks**; historical full 34-item acceptance belongs to its earlier candidate. [Detailed limits](harness/reports/large-text-repair.md) · [Original evidence index](harness/reports/large-text-final-evidence-index.json).

The main snapshot `bebda78` passed [CI](https://github.com/KuroGeo/transvirtual-driver-delivery/actions/runs/38148283089). Report/README packaging changes receive their own validation and do not retroactively expand native acceptance.

## How I used AI

**Tools:** Codex coordinated implementation and independent engineering roles; Oil UI guided the browser prototype; the built-in image generator created the icon. AI generated Flutter, prototype, test and Harness code, and assisted documentation. I supplied product direction, selected the map-first design and icon, corrected interaction details, reviewed the simulator experience and decided the delivery boundaries. I do not claim the generated code as hand-written. More detail: [Part 03: AI execution and my decisions](https://kurogeo.github.io/transvirtual-driver-delivery/index.en.html#journey) · [AI usage & concrete mistakes](docs/report/ai-usage.md).

One concrete failure: generated layouts clipped information at maximum OS text size. Actual simulator screenshots and native reading/return checks exposed it. The repair used expandable summaries and full safe-area workspaces while retaining ordinary-size layout, focus and return origin; PR37 records the fix and regression evidence. Another review found that the Harness could accept incomplete test logs or unreaped child-process cleanup; strict completion checks and counterexample tests repaired it in PR34.

**Time accounting:** the repository history spans October 10–11, 2026 and includes prototype, architecture, Harness and later accessibility work beyond the small assignment slice. No reliable human active-effort log was maintained, so this submission does not claim that all of that work fit the requested 4–6 hours. Commit and chat timestamps show chronology, not focused work hours.

## What I would do next

- Keep interview extensions small: add a focused rule or test, then verify the persistence/sync path.
- Scale to thousands of stops with measured query/index, visible-marker and list costs; use isolates only for demonstrated CPU-heavy parsing/work.
- Define a real backend contract for idempotency, conflicts and account ownership before connecting delivery results.
- Store photo/signature files separately and queue their metadata; define resumable upload, limits and orphan cleanup.
- Measure startup, frame timing, memory and battery on physical devices in profile/release builds.
- Evaluate authorized offline map data, real GPS and road routing; fixed straight-line distance currently serves the demo.

Authentication, real backend integration, push and route optimization remain outside the assignment. **Production remains no-go:** physical-device performance (#31), enforced remote release checks (#32), and real service/resources/signing/delivery (#33) remain separate requirements. Publishing this interview prerelease does not clear them.

<details>
<summary><b>More real Flutter screenshots</b></summary>

<table>
<tr><td align="center"><b>Delivery detail</b><br><img src="docs/report/media/delivery-detail.webp" width="280" alt="Address, time window and result controls"></td><td align="center"><b>Required failure reason</b><br><img src="docs/report/media/failure-form.webp" width="280" alt="Failure reason form before submission"></td></tr>
<tr><td align="center"><b>Offline failure record</b><br><img src="docs/report/media/failure-record.webp" width="280" alt="Persisted reason and waiting-to-sync state"></td><td align="center"><b>Completed record</b><br><img src="docs/report/media/completed-record.webp" width="280" alt="Local result and simulated confirmation times"></td></tr>
</table>

Screens shown above are compressed WebP copies. Original PNGs and editable promotional material: [assets/readme](assets/readme/README.md).

</details>

<details>
<summary><b>Prototype, architecture and engineering workflow</b></summary>

Run `python3 prototype/serve.py` and open [the map prototype](http://127.0.0.1:8764/index.html) or [design comparison](http://127.0.0.1:8764/style-explorer.html). The browser version uses HTML/CSS/JavaScript, Alpine.js, Leaflet and localStorage; its 78 checks passed three rounds. Browser evidence is separate from Flutter evidence.

[Demo data](app/assets/deliveries.csv) · [Current return rules](prototype/origin-return-design.md) · [Direct sync design](prototype/direct-sync-design.md) · [Architecture](docs/solution-design.md) · [Skill/Harness workflow](harness/README.md) · [Issue dependency graph](harness/project/backlog.json) · [Execution board](harness/project/work.json).

</details>

<details>
<summary><b>Public demo data and historical screenshots</b></summary>

The public app uses self-created customer names, fictional addresses and generated coordinates in [app/assets/deliveries.csv](app/assets/deliveries.csv). Its seven-column format, demo references and initial status counts are retained. Recruitment mail, original assignment attachments and the engineering archive containing copies are kept locally and ignored by Git. Earlier screenshots and evidence describe their recorded candidates; existing installations retain their saved database.

</details>
