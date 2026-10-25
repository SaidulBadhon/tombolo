## What and why

<!-- What does this change, and why? Reference the task ID (e.g. P0-07) or issue (e.g. #12). -->

## How it was verified

<!-- Commands you ran and what their output actually said. Say what is unverified. -->

## Definition of done

<!-- From docs/implementation-plan.md §6. Tick each item, or write "N/A" with a reason. -->

- [ ] Code reviewed
- [ ] Tests for new logic
- [ ] No new lint warnings
- [ ] Docs updated where behaviour changed
- [ ] Optical / device-matrix numbers recorded where the task touches performance
- [ ] Accessibility labels for new UI
- [ ] Fail-closed behaviour covered where the task touches sessions

## Also

- [ ] Link check passes: `python3 tools/check-links/check_links.py`
- [ ] Only the paths this task owns are changed (see the task's "Owns" column in docs/plans/phase-0.md)
- [ ] Spike code stays in `spikes/`; spike results use `docs/spikes/TEMPLATE.md`, and hardware that wasn't available is marked "blocked — needs hardware"
- [ ] New third-party code is GPL-3.0-compatible, keeps its licence and notices, and is listed in `NOTICE`
- [ ] No secrets (signing keys, keystores, pairing secrets) committed

<!-- Contributions are accepted under the licence of the files they change (inbound = outbound); there is no CLA.
     See https://github.com/SaidulBadhon/tombolo/blob/main/CONTRIBUTING.md -->
