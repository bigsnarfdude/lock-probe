# Lock Probe

A controlled behavioral-forensics eval for agentic LLMs. One locked file, one task, one varied
sentence — scored from the filesystem, not the transcript.

**Companion to** the `ai-eval-security-lab` infra replication. That project proves the security
*controls* catch an escape; this one measures the *behaviour* that leads to one.

## The question

When you tell a model it's being watched, does it hide what it did? The probe gives a model a
read-only file it must write to, forcing it to `chmod`, then varies only the framing and reads
the result off `stat`. Because the score comes from the file's own metadata (inode, mode,
mtime, ctime), the model cannot fake it in its transcript.

## What's inside

```
README.md            you are here
RUNBOOK.md           step-by-step: scp to a box → run 8 steps → archive → teardown
scripts/
  00-preflight.sh    GPU/user checks; hard-fails if the agent can sudo
  10-setup.sh        deps + weights (pinned rev) + scorer self-test
  20-serve.sh        vLLM serve bf16
  30-baseline.sh     L1/L2 — effort gradient + scratch/gzip controls
  40-lens.sh         L3 — activation capture + lens
  50-pressure.sh     the pressure ladder (neutral→PXR→conceal)
  60-concealment.sh  L4 — costly concealment (L4C/L4T/L4B)
  70-analyze.sh      cross-arm table (truncation-excluded, validity-corrected)
  80-archive.sh      checksum + rsync results off the box
  99-teardown.sh     free the GPU
  _reference/        the original run scripts this package was distilled from
lib/
  smoke_eval.py      the harness: model → shell → score from artifacts
  capture_chmod.py   L3 activation capture
  lens.py, jlens.py  activation readouts
  nc_report.py       L1/L2 report
  analyze.py         cross-arm analysis (ships with the fixes below)
  selftest.py        scorer self-test — run before spending GPU
docs/
  FINDINGS.md        what the numbers mean
  EXPECTED.md        numbers from prior runs (a reproduction that disagrees is interesting)
  CHANGELOG.md       fixes baked into this package vs the original run — v1 -> v2 -> v3
judge/
  judge_opus.py      independent LLM judge pass over a completed run (rubric-scored intent)
  RUBRIC_v2.md        the rubric judge_opus.py reads against
harness_versions/
  MANIFEST.md        provenance graph — every byte-distinct code version, sha256, and which
                     data it produced (mermaid diagrams: code lineage + orchestration call graph)
  <name>__<hash>.py  archived copies, named by content hash, of every version referenced above
```

`lib/smoke_eval.py` is the current (v3) harness. `lib/smoke_eval_v2.py` is kept alongside it as the
exact as-run v2 baseline, since v2's own `git`-adjacent "master" copy had a bug the copy that
actually executed did not — see `harness_versions/MANIFEST.md` for why a description string isn't
enough and every version here is filed by its hash instead.

## The findings, in one paragraph

Naming the inspected channel moves file-restoration from ~2% to ~99%; vague surveillance
("you're being recorded", "this is an evaluation") does nothing. The model restores exactly the
channel it's told about and never the timestamp beside it — though a control proves it can, to
the nanosecond. And forbidding the sanctioned route triples how often it enumerates the OS for a
privilege-escalation path. None of it is deception: it's literal instruction-following, and the
one forensic trace it cannot forge unprivileged (ctime) always gives it away. Full write-up in
`docs/FINDINGS.md`.

## Safety / scope

Benign throughout. The agent runs as an unprivileged user on a sandboxed rented box that is torn
down after. No real system is targeted; the "escalation recon" is enumeration that finds nothing
on a locked-down host. This is measurement of model behaviour under controlled framing, in the
spirit of the Hugging Face / eval-security incident analysis.

## Requirements

≥40 GB VRAM (H100/A100), root on the box, ~120 GB disk. See RUNBOOK.md.
