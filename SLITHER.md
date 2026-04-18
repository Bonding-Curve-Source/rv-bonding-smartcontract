# Slither — static analysis

[Slither](https://github.com/crytic/slither) is Trail of Bits’ static analyzer for Solidity. It **does not replace** automated tests (`hardhat test`); it complements them by surfacing risky patterns (reentrancy, unchecked external calls, etc.) and improvement hints (gas, style).

## Prerequisites

- Python 3 and [pipx](https://pypa.github.io/pipx/) (recommended), or `venv` + pip.

## Install Slither

```bash
pipx install slither-analyzer
```

Verify:

```bash
slither --version
```

## Run in this repo

From the `contract-bonding` root (where `hardhat.config.js` and `slither.config.json` live):

```bash
slither .
```

Slither uses Hardhat to compile (same idea as `npx hardhat compile`). Default settings come from `slither.config.json`.

## npm scripts

| Command | Description |
|---------|-------------|
| `npm run slither` | Run Slither; print results to the terminal |
| `npm run slither:json` | Write JSON → `reports/slither-report.json` |
| `npm run slither:sarif` | Write SARIF → `reports/slither.sarif` (VS Code, GitHub Code Scanning) |
| `npm run slither:export` | JSON + SARIF in one run |
| `npm run slither:txt` | Full terminal log → `reports/slither-output.txt` |
| `npm run slither:summary` | Build a **Vietnamese summary table** (Topic / Scope / Notes) → `reports/slither-summary.vi.md` — requires `reports/slither-report.json` first |
| `npm run slither:report` | Run Slither, export JSON, then generate `slither-summary.vi.md` |

`scripts/slither-summary.mjs` groups Slither detectors by **topic** (Reentrancy, arbitrary-send-erc20, oracle, …) and attaches **notes**. Adjust the mapping in the script when you add new detectors.

### Vietnamese summary (`slither-summary.vi.md`)

After `reports/slither-report.json` exists, `npm run slither:summary` writes Markdown with these columns (headings in the file are Vietnamese: **Chủ đề** / **Phạm vi** / **Gợi ý**):

| Column | Meaning |
|--------|---------|
| Topic | Grouped theme (e.g. Reentrancy, `arbitrary-send-erc20`, oracle…) — not a 1:1 match to raw Slither detector names. |
| Scope | Related contract / function / event (from JSON). |
| Notes | Short handling hints in Vietnamese. |

The end of the file lists **original detector names** (`reentrancy-benign`, …) per topic. Detectors not listed in `THEMES` (inside `slither-summary.mjs`) still appear separately with default notes and wiki links.

**One-shot (JSON + table):** `npm run slither:report`

### Files under `reports/`

| File | Produced by |
|------|----------------|
| `slither-report.json` | `slither:json` / `slither:export` / `slither:report` |
| `slither.sarif` | `slither:sarif` / `slither:export` |
| `slither-output.txt` | `slither:txt` (full terminal log) |
| `slither-summary.vi.md` | `slither:summary` or the last step of `slither:report` |

The `reports/` directory is listed in `.gitignore` (remove the ignore if you want to commit reports).

## Configuration (`slither.config.json`)

- `filter_paths`: exclude findings by file path (e.g. skip `node_modules`).
- `detectors_to_exclude`: disable noisy or low-priority detectors (e.g. Solidity version, naming).

Edit this file when you need to narrow scope or reduce noise.

## Manual runs (without npm)

```bash
mkdir -p reports
slither . --json reports/slither-report.json
slither . --sarif reports/slither.sarif
slither . --json reports/slither-report.json --sarif reports/slither.sarif
slither . --disable-color 2>&1 | tee reports/slither-output.txt
```

Print JSON to stdout: `slither . --json -`

## Exit codes and how to read output

- Slither often returns a **non-zero exit code** (e.g. `255`) when at least one finding exists — that means “review this,” not necessarily a critical bug.
- Each line includes **detector** + **contract/function** + Crytic doc links. **Judge each finding in context** (e.g. `arbitrary-send-erc20` is often a false positive when `from` is controlled by a trusted entrypoint).

Detector reference: [Slither detector documentation](https://github.com/crytic/slither/wiki/Detector-Documentation).

## Suggested workflow

1. `npm run compile` — ensure Hardhat compiles (Slither relies on a successful build).
2. `npm run slither:report` — JSON + Vietnamese summary in one go; or `npm run slither` for a quick terminal-only pass.
3. Read `reports/slither-summary.vi.md` to triage by topic; open `slither-report.json` or the terminal log for per-finding detail.
4. Triage order: **reentrancy** and external calls first, then oracle / zero-check, then gas, events, style.

## Troubleshooting

- **`npm run slither:summary` complains about missing JSON:** run `npm run slither:json` first, or use `npm run slither:report`.
- **`slither: command not found`:** reinstall with `pipx install slither-analyzer` and ensure `pipx` put the binary on your `PATH`.
- **Compile errors:** fix Solidity/Hardhat issues first; Slither will not finish if the project does not build.
- **Too many warnings:** narrow with `slither.config.json` (`filter_paths`, `detectors_to_exclude`), then run `slither:report` again.
