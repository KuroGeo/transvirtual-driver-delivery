# Ocean Delivery interview presentation

Open [index.html](index.html) directly in a browser. The font and six original simulator screenshots are embedded; no server, npm install or network is required to read the report. Evidence links lead to the private GitHub repository and require access.

- **阅读模式:** all ten sections form a continuous report.
- **演示模式:** one section at a time; use on-screen arrows or the arrow/PageUp/PageDown keys when no control is focused. Escape returns to reading.
- **讲述提示:** personal Chinese speaking notes, hidden by default.
- **真实截图:** click to enlarge; Escape closes the dialog.
- **打印:** use the browser's print dialog. Closed appendix/answer details remain collapsed; open the ones you need first.

The historical four chat titles and their creation times were verified through Codex, sorted in Asia/Shanghai. [history.json](history.json) records live GitHub PR data for six merged PRs. [commit-show.txt](commit-show.txt) contains actual `git show --stat` output. [ai-usage.md](ai-usage.md) distinguishes AI generation from product direction and records concrete failures, time accounting and evidence boundaries.

To reproduce the report from the tracked files:

```sh
python3 docs/report/build_report.py
```

The report snapshots application/source history at `bebda787284fed5f9d5fb4acc36cd174fad7ab75`. This presentation/README packaging change adds no Flutter behavior. The Release's manifest binds the submission commit, reused simulator build, SDK, archive bytes and exclusions separately; it does not relabel earlier native evidence as current full-matrix acceptance.
