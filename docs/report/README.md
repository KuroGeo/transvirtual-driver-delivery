# Ocean Delivery interview presentation

Open [index.html](index.html) directly in a browser. The font and six original simulator screenshots are embedded; no server, npm install or network is required to read the report. Evidence links lead to the public source repository and its merged PRs.

Published presentation: [GitHub Pages](https://kurogeo.github.io/transvirtual-driver-delivery/) · [Part 03: human/AI collaboration](https://kurogeo.github.io/transvirtual-driver-delivery/#journey).

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

The export copies the standalone HTML, selected collaboration excerpts, commit stats and AI note; its PR index omits full bodies and raw chat records. It does not publish the application, original mail or assignment attachments. The pinned `.github/workflows/report-pages.yml` workflow deploys this allowlist from `main`. The source repository is public by George's explicit request, and the site uses `KuroGeo/transvirtual-driver-delivery`.

The report snapshots application/source history at `bebda787284fed5f9d5fb4acc36cd174fad7ab75`. This presentation/README packaging change adds no Flutter behavior. The Release's manifest binds the submission commit, reused simulator build, SDK, archive bytes and exclusions separately; it does not relabel earlier native evidence as current full-matrix acceptance.

The current public app uses self-created synthetic CSV data. Original recruitment mail, assignment attachments and the engineering archive containing copies are retained locally and ignored by Git. This report keeps screenshots and evidence bound to their historical candidates; it does not claim they were recaptured with the replacement data.
