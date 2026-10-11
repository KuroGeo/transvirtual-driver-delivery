# AI usage and engineering judgment

Codex generated and iterated the browser prototype, Flutter application, tests, Harness tools and documentation, with separate engineering roles in the historical implementation chats. Oil UI guided the prototype design; the built-in image generation tool produced the icon. The report and README were also AI-assisted.

George supplied product direction and constraints, selected the map-first workflow and the first icon, corrected direct-sync feedback and return-origin behavior, reviewed real simulator screens, requested maximum-text repairs and decided the delivery boundary. No reliable line-by-line manual-code log exists; generated code is not claimed as hand-written. Git authorship alone does not establish manual authorship.

## Concrete failures and how they were caught

1. **Large-text layouts clipped content.** Actual maximum OS text size and Reduce Motion exposed truncated customer/address/result information and insufficient map summary space. PR37 introduced full safe-area, scrollable workspaces and expandable summaries, preserving focus and return origin. Its targeted N7 evidence covers two maximum-size device configurations and one normal-size configuration. See `harness/reports/large-text-repair.md` and its original evidence index.
2. **Short map layouts clipped controls.** PR34 review found 44px tools and fixed fit padding could exceed the remaining landscape map. Regressions first failed, then passed after the tools became scrollable and fit padding reserved marker height. This landscape evidence is host/widget regression, not OS rotation acceptance. See `harness/reports/pr34-final-review.md` (UI-01).
3. **Harness completion checks were too permissive.** Review found cleanup metadata and summary-only/truncated unittest logs could be accepted. Strict type/PID/process-group cleanup checks and complete verbose-line counts closed HREV-1/HREV-2. Preserved failing cases and independent review establish the repair; AI's own claim of success did not suffice.

## Scope and time accounting

The original brief asks for 4–6 hours and accepts an explained incomplete slice. This repository records several stages on October 10–11, 2026, including additional prototype, engineering infrastructure and accessibility work. Chat/commit timestamps are not a human active-effort log. No exact human hours are claimed. An extension request was observed in the email thread; no approval was present in the thread at report preparation. This report does not treat that request as an approved deadline change.

## What evidence means

Browser interaction checks establish the prototype only. Host/widget tests establish logic/layout behavior in their test configuration. Native simulator checks establish the named configurations, source and fake/controlled services. Physical-device performance, real backend delivery and production signing remain separate and unverified. The interview Release contains source, presentation and an arm64 simulator debug Demo; it does not declare production readiness.
