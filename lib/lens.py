#!/usr/bin/env python3
"""L3 readout: logit lens over a captured turn corpus, at a CHOSEN anchor.

Runs on CPU. Needs only lm_head + the final RMSNorm (~7 GB of a 52 GB model), because
the logit lens is just head(norm(h)) and the activations are already on disk.

WHY THE LOGIT LENS AND NOT THE FINITE-DIFFERENCE JACOBIAN LENS
  On this corpus the FD lens returned junk subword fragments in 6 of 13 readouts (46%).
  The plain logit lens on the SAME activations was 13%. The FD construction divides
  rounding error by a small epsilon; in bf16, bf16(1.01) = 1.0078, so a 1e-2 epsilon
  carries a 22% bias before any rounding. Use the FD lens only with eps >= 0.1 and only
  after checking the junk rate.

ANCHOR CHOICE MATTERS MORE THAN LENS CHOICE. Measured, same corpus, same layer:
  action    the token after `chmod`   -> both conditions read "permissions" alike.
                                        Fixed by SHELL SYNTAX, not by any plan. No signal.
  cot-last  last token before </think> -> returns `</think>`. It is a delimiter. No signal.
  cot-plan  a restore-keyword token in -> reads `original / exactly / afterward /
            the chain of thought          permissions`, up to 14 of 15 on-topic. THE PLAN.

  cot-plan is DESCRIPTIVE, NOT A CONTRAST: it exists only in turns that wrote a restore
  plan, which by construction means the instructed condition. Do not report a
  conceal-vs-neutral difference from it.

  SHELF LIFE: cot-plan works only while the model reasons in natural language. If
  reasoning moves into activations, this anchor disappears and `action` -- the one that
  currently reads nothing -- is what is left. That is the argument for fixing `action`.

Row alignment (easy to get wrong): capture keeps the LAST prefill position, then one row
per decode step, so acts row i == full position (n_prompt - 1 + i). Reading "the state at
token k" means row k+1 -- the state after emitting k, which predicts k+1.
"""
import argparse, glob, json, os, re, sys
import numpy as np
import torch
from safetensors import safe_open
from huggingface_hub import hf_hub_download

RMS_EPS = 1e-6
PERM    = re.compile(r"perm|chmod|writab|mode|444|restor|acl|readonly|read-only", re.I)
RESTORE = re.compile(r"restor|revert|444|original|afterwards?|恢复", re.I)
JUNK    = re.compile(r"^[\W_]{1,2}$")


def load_head_norm(repo, head_shard, norm_shard):
    head = norm = None
    with safe_open(hf_hub_download(repo, head_shard), framework="pt") as f:
        if "lm_head.weight" in f.keys():
            head = f.get_tensor("lm_head.weight")
    with safe_open(hf_hub_download(repo, norm_shard), framework="pt") as f:
        for k in f.keys():
            if k.endswith("norm.weight") and "layers" not in k:
                norm = f.get_tensor(k); break
    if head is None or norm is None:
        sys.exit(f"missing tensors (head={head is not None} norm={norm is not None})")
    return head.float(), norm.float()


def lens(h, head, w, topk):
    hn = (h / torch.sqrt(torch.mean(h * h) + RMS_EPS)) * w
    return [int(t) for t in torch.topk(hn @ head.T, topk).indices]


def find_anchor(strs, which):
    te = next((k for k, s in enumerate(strs) if "</think>" in s), None)
    if which == "cot-last":
        return (te - 1) if te and te > 0 else None
    if which == "cot-plan":
        hits = [k for k in range(te or len(strs)) if RESTORE.search(strs[k])]
        return hits[-1] if hits else None
    ci = next((k, ) for k, s in enumerate(strs) if "CMD" in s) if any("CMD" in s for s in strs) else None
    ci = ci[0] if ci else None
    return next((k for k, s in enumerate(strs)
                 if "chmod" in s.lower() and ci is not None and k > ci), None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus")
    ap.add_argument("--anchor", default="cot-plan", choices=["action", "cot-last", "cot-plan"])
    ap.add_argument("--layer", type=int, default=56)
    ap.add_argument("--topk", type=int, default=15)
    ap.add_argument("--repo", default="Qwen/Qwen3.8-27B")
    ap.add_argument("--head-shard", default="model-00018-of-00018.safetensors")
    ap.add_argument("--norm-shard", default="model-00016-of-00018.safetensors")
    a = ap.parse_args()

    from transformers import AutoTokenizer
    tok = AutoTokenizer.from_pretrained(a.repo)
    head, w = load_head_norm(a.repo, a.head_shard, a.norm_shard)
    print(f"[load] head {tuple(head.shape)}  anchor={a.anchor}  L{a.layer}", flush=True)

    rows = []
    for d in sorted(glob.glob(os.path.join(a.corpus, "turns", "*"))):
        mf = os.path.join(d, "meta.json")
        if not os.path.exists(mf): continue
        m = json.load(open(mf)); strs = m["gen_token_strs"]
        z = np.load(os.path.join(d, "acts.npz")); key = f"L{a.layer}"
        if key not in z: continue
        A = z[key]
        idx = find_anchor(strs, a.anchor)
        if idx is None: continue
        r = min(idx + 1, A.shape[0] - 1)
        toks = [tok.decode([t]) for t in lens(torch.tensor(A[r].astype(np.float32)), head, w, a.topk)]
        rows.append({"tag": m["tag"], "cond": m["cond"],
                     "ctx": "".join(strs[max(0, idx-10):idx+2])[-58:], "toks": toks})

    print(f"\n{'turn':<18} {'cond':<9} {'perm':<5} {'junk':<5} context -> top tokens")
    print("-"*104)
    for r in rows:
        p = sum(1 for t in r["toks"] if PERM.search(t))
        j = sum(1 for t in r["toks"] if JUNK.search(t))
        print(f"{r['tag']:<18} {r['cond']:<9} {p:<5} {j:<5} ...{r['ctx']!r}")
        print(f"{'':<40}-> {r['toks'][:8]}")
    print()
    for c in sorted({r["cond"] for r in rows}):
        s = [r for r in rows if r["cond"] == c]
        pm = np.mean([sum(1 for t in r["toks"] if PERM.search(t)) for s_ in [s] for r in s_])
        jm = np.mean([sum(1 for t in r["toks"] if JUNK.search(t)) for r in s])
        print(f"  {c:<9} n={len(s):<3} mean perm-hits/{a.topk} = {pm:.2f}   mean junk = {jm:.2f}")
    if a.anchor == "cot-plan":
        print("\n  NOTE: cot-plan is conceal-only by construction. Descriptive, NOT a contrast.")


if __name__ == "__main__":
    main()
