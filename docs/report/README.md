# Ocean Delivery interview presentation

Open the [Chinese report](index.html) or [English report](index.en.html) directly in a browser. The toolbar language switch preserves the current section, presentation mode and speaker-note setting. The compressed WOFF2 font and six WebP copies of original simulator screenshots are embedded; no server, npm install or network is required to read the report. The 82-second H.264 demo is a separate `media/ocean-delivery-demo.mp4` file; keep the `media` folder next to the HTML for offline playback. Evidence links lead to the public source repository and its merged PRs.

Published presentation: [English](https://kurogeo.github.io/transvirtual-driver-delivery/index.en.html) · [中文 / GitHub Pages](https://kurogeo.github.io/transvirtual-driver-delivery/) · [Part 03: human/AI collaboration](https://kurogeo.github.io/transvirtual-driver-delivery/#journey).

- **阅读模式:** all ten sections form a continuous report.
- **演示模式:** one section at a time; use on-screen arrows or the arrow/PageUp/PageDown keys when no control is focused. Escape returns to reading.
- **讲述提示:** personal Chinese speaking notes, hidden by default.
- **真实截图:** click to enlarge; Escape closes the dialog.
- **打印:** use the browser's print dialog. Closed appendix/answer details remain collapsed; open the ones you need first.

The historical four chat titles and their creation times were verified through Codex, sorted in Asia/Shanghai. [history.json](history.json) records live GitHub PR data for six merged PRs. [commit-show.txt](commit-show.txt) contains actual `git show --stat` output. [ai-usage.md](ai-usage.md) distinguishes AI generation from product direction and records concrete failures, time accounting and evidence boundaries.

Part 03 now expands the four conversations into eight steps. Each identifies AI execution, George's decisions/corrections, and what AI could not independently complete. [collaboration.json](collaboration.json) contains 17 short human-message excerpts and exact timestamps, verified against the original records. Capability boundaries are interpretations of this project history; no universal model inability or manual-code ownership is implied.

To reproduce the report from the tracked files:

```sh
python3 docs/report/build_report.py
```

To export a committed report for a GitHub Pages artifact:

```sh
python3 docs/report/stage_pages.py /absolute/path/to/report-export
```

The export copies the HTML, compressed demo/poster, curated recording proof and transcript, selected collaboration excerpts, commit stats and AI note; its PR index omits full bodies and raw chat records. It does not publish the application, original mail or assignment attachments. The pinned `.github/workflows/report-pages.yml` workflow deploys this allowlist from `main`. The source repository is public by George's explicit request, and the site uses `KuroGeo/transvirtual-driver-delivery`.

The report snapshots application/source history at `bebda787284fed5f9d5fb4acc36cd174fad7ab75`. This presentation/README packaging change adds no Flutter behavior. The Release's manifest binds the submission commit, reused simulator build, SDK, archive bytes and exclusions separately; it does not relabel earlier native evidence as current full-matrix acceptance.

## Compressed media

Original PNGs and the raw native recording are retained. Web copies use WebP; Inter is embedded as WOFF2. The video uses H.264 / yuv420p / MP4 faststart at 1080p and 30 fps. It has no audio, allowing live narration. The video is a separate file and the player uses `preload="metadata"`; actual fetching is browser-dependent. [Image compression receipts](media/image-compression.json) · [Video proof and encoding receipts](media/demo-proof.json).

The native recording reuses a hash-verified 84-file workbench simulator package and drives real UI controls across three system processes. Input text is Flutter Driver emulated; ACKs come from the task HTTP fixture. This is an additional demonstration, not a new full native acceptance result. Raw logs, task secrets, original recording and temporary project assets are kept out of the Pages export.
The current public app uses self-created synthetic CSV data. Original recruitment mail, assignment attachments and the engineering archive containing copies are retained locally and ignored by Git. This report keeps screenshots and evidence bound to their historical candidates; it does not claim they were recaptured with the replacement data.

## Bilingual presentation

Both versions use the same layout, evidence links and ten sections. `english.json` contains explicit translations of the original Chinese text; `localize_report.py` refuses to build if any Chinese text or accessibility label lacks a translation. Section 03 keeps all eight steps and translates the instruction excerpts; the Chinese originals remain in `collaboration.json`. Screenshots and video retain their original UI and Chinese on-screen text. The English page enables the lightweight English caption track by default. Its VTT bytes are embedded in both HTML files to support direct offline opening; `media/demo.en.vtt` is kept as an editable source. Both pages reuse the same compressed MP4.
