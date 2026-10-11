# Native demo production sources

`capture.py` records an **isolated, task-owned** iOS simulator using the existing workbench and OS process restart checks. It needs an isolated copy of `app/` and `harness/`, a hash-verified workbench `Runner.app` under `app/build/ios/iphonesimulator`, and `video_driver.dart` copied into `app/integration_test/`. Resolve locked app dependencies first. Keep raw recordings and logs out of the public Pages allowlist.

The driver is the existing tooling smoke driver with readable pauses and a clearly labelled demo scope. It uses UI controls and read-only snapshots; no model mutation endpoint is added. The private tile proxy handles only requests from the actual viewport. The fixture provides controlled simulated HTTP acknowledgements. The recording does not replace or expand native acceptance.

```sh
python3 docs/report/video-src/capture.py \
  --root /absolute/path/to/isolated-root \
  --output /absolute/path/to/new-recording \
  --lock-root /absolute/path/to/harness/runs/locks
```

`build_composition.py` reproduces the 1920×1080, 82-second fixed-phone composition. The observed PIDs and cue timings are specific to this recording; refresh them when making a new capture. Supply `assets-native.mp4` (this capture: raw head trimmed at 25.81 seconds, no internal cuts, normal playback), and a local GSAP 3.14.2 `gsap.min.js`. `BRIEF.md` and `DESIGN.md` specify the visual treatment. Local Hiragino Sans GB/PingFang SC and JetBrains Mono are used for a local render; no cloud font availability is claimed.

```sh
python3 docs/report/video-src/build_composition.py /absolute/path/to/composition
cd /absolute/path/to/composition
npx hyperframes@0.8.147 check --snapshots
npx hyperframes@0.8.147 preview --background
npx hyperframes@0.8.147 render --fps 30 --quality delivery --output rendered.mp4
ffmpeg -i rendered.mp4 -an -c:v libx264 -preset slow -crf 24 \
  -pix_fmt yuv420p -movflags +faststart ocean-delivery-demo.mp4
```

Verify the final render with ffprobe, inspect beginning/action/restart/ending frames, and check Pages bytes after publication. Original raw recording and snapshots remain local; public receipts are in `../media/demo-proof.json`.
