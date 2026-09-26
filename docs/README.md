# Documentation map

`README.md` and `CLAUDE.md` stay at the repository root because they are entry-point files. Project documentation is grouped here by purpose so version plans, user guides and validation evidence do not accumulate in one directory.

## Guides

- `guides/VIRTUAL_FLY_LAB_GUIDE.md` — user-facing Virtual Fly Lab controls and behavior.
- `guides/LAUNCHERS.md` — supported launch paths and launcher behavior.

## Plans

- [V4–V14 sequential roadmap](plans/VIRTUAL_FLY_LAB_ROADMAP.md) — authoritative order; V5.5.1 unified app work precedes V5.6, and V6–V14 remain planned.
- [Implementation playbook](plans/IMPLEMENTATION_PLAYBOOK.md) — contracts, step tracking, validation, failure handling and handoff rules.
- [Interactive sandbox design](plans/INTERACTIVE_FLY_SANDBOX_PLAN.md) — participant Viewer, environment controls, external I/O and neural interpretation contracts.
- [V4 implementation plan](plans/VIRTUAL_FLY_LAB_V4_PLAN.md)
- [V5 implementation plan](plans/VIRTUAL_FLY_LAB_V5_PLAN.md)
- [V5.5.1 unified app experience plan](plans/VIRTUAL_FLY_LAB_V5_5_1_UNIFIED_APP_PLAN.md) — one native macOS window for the world, stimuli, neural observation, and experiments before V5.6.
- [V6 implementation plan](plans/VIRTUAL_FLY_LAB_V6_PLAN.md)
- [V7 implementation plan](plans/VIRTUAL_FLY_LAB_V7_PLAN.md)
- [V8 implementation plan](plans/VIRTUAL_FLY_LAB_V8_PLAN.md)
- [V9 implementation plan](plans/VIRTUAL_FLY_LAB_V9_PLAN.md)
- [V10 implementation plan](plans/VIRTUAL_FLY_LAB_V10_PLAN.md)
- [V11 implementation plan](plans/VIRTUAL_FLY_LAB_V11_PLAN.md)
- [V12 implementation plan](plans/VIRTUAL_FLY_LAB_V12_PLAN.md)
- [V13 implementation plan](plans/VIRTUAL_FLY_LAB_V13_PLAN.md)
- [V14 implementation plan](plans/VIRTUAL_FLY_LAB_V14_PLAN.md)

V3/V2 and original FlyGym plans are historical. The former roadmap is preserved in `history/VIRTUAL_FLY_LAB_ROADMAP_PRE_INTERACTIVE_2026-09-13.md`; its old version assignments are superseded.

## Reports

- `reports/V5_PROGRESS.md` — V5 baseline gate, installed viewport/picking API preflight, step tracker and first implementation slice.
- `reports/V4_COMPLETION_REPORT.md` — V4 fixed-tick/session implementation, full regression and real Viewer acceptance evidence.
- `reports/V3_COMPLETION_REPORT.md` — V3 implementation and regression evidence.
- `reports/V3_VERIFICATION_REPORT_2026-09-13.md` — independent V3 verification and remediation history.
- `reports/V2_FINAL_AUDIT_2026-09-13.md` — pre-V3 audit retained as historical evidence.
- `reports/PERFORMANCE_FLYGYM.md` — measured FlyGym performance notes.

## Reference

- `reference/FLYGYM_API_INSPECTION.md` — installed FlyGym API inspection evidence.

## History

- `history/WRITEUP.md` — narrative implementation history.

The `notes/` directory remains separate because it is already an ordered engineering notebook. `data/DATA_LICENSE.md` stays next to the data it governs, and `flygym_bridge/README.md` stays next to the Python bridge implementation.
