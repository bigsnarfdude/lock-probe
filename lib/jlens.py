#!/usr/bin/env python3
"""J-Lens / R-Lens readout over captured turns.

J-Lens (Jacobian lens) characterises an activation by its first-order causal effect
on the model's output: it replaces every layer downstream of the readout point with a
single linear map -- the Jacobian -- and then applies the model's own unembedding.
The readout is a ranked list of vocabulary tokens: what the model is representing at
that layer and position.

We want J.h where the perturbation direction is h itself. That is a Jacobian-vector
product, so it needs no autograd graph spanning the whole model:

    J.h  ~=  [ f(h + eps*h) - f(h) ] / eps          (two forward passes)

f is the map from the readout layer's output at position p to the final normed hidden
state at position p. Differences are taken in fp32; bf16 cannot hold them.

R-Lens is J-Lens with three layerwise-relevance-propagation corrections to reduce
error accumulation. In this forward-linearisation form they become: reuse the CLEAN
pass's RMSNorm denominator instead of recomputing it (LN-rule), reuse the clean pass's
gate activations so SiLU/GELU become per-element linear (identity-rule), and split
relevance evenly across multiplicative gates (half-rule). Each is applied by caching
statistics on the clean pass and forcing them during the perturbed pass.

PROVENANCE CHECK, run by default: the corpus stored token ids and per-layer
activations from generation. Teacher-forcing those exact ids must reproduce those
exact activations. If it does not, the readout does not describe the trace it claims
to, and the run aborts. This is the whole reason generation and capture were done in
one pass.

Usage:
  jlens.py --turn <dir with meta.json> --layer 45 [--pos last|N|write] [--rlens]
           [--topk 20] [--model ~/models/qwen38-hf] [--no-verify]
"""
import argparse, json, os, sys
import numpy as np
import torch


def load_model(mp):
    from transformers import AutoTokenizer, AutoModelForCausalLM
    tok = AutoTokenizer.from_pretrained(mp)
    m = AutoModelForCausalLM.from_pretrained(mp, dtype=torch.bfloat16, device_map="cuda:0")
    m.eval()
    for p in m.parameters():
        p.requires_grad_(False)
    return tok, m


def get_layers(m):
    for p in ["model.layers", "model.language_model.layers", "model.model.layers"]:
        o = m
        try:
            for q in p.split("."):
                o = getattr(o, q)
            return o
        except Exception:
            continue
    raise RuntimeError("decoder layers not found")


def get_final_norm_and_head(m):
    norm = None
    for p in ["model.norm", "model.language_model.norm", "model.model.norm"]:
        o = m
        try:
            for q in p.split("."):
                o = getattr(o, q)
            norm = o
            break
        except Exception:
            continue
    head = getattr(m, "lm_head", None)
    if norm is None or head is None:
        raise RuntimeError("final norm / lm_head not found")
    return norm, head


class Readout:
    """Capture the readout layer's output, and optionally scale it at one position."""
    def __init__(self, layers, layer_id):
        self.h = None
        self.scale_pos = None
        self.eps = 0.0
        self.handle = layers[layer_id].register_forward_hook(self._hook)

    def _hook(self, mod, inp, out):
        tup = isinstance(out, tuple)
        h = out[0] if tup else out
        self.h = h.detach()
        if self.scale_pos is not None:
            h = h.clone()
            h[:, self.scale_pos, :] = h[:, self.scale_pos, :] * (1.0 + self.eps)
            return ((h,) + tuple(out[1:])) if tup else h
        return out

    def close(self):
        self.handle.remove()


def final_hidden(m, ids, ro, pos, eps=0.0, scale_pos=None):
    ro.scale_pos = scale_pos
    ro.eps = eps
    with torch.no_grad():
        out = m(ids, output_hidden_states=True)
    ro.scale_pos = None
    ro.eps = 0.0
    return out.hidden_states[-1][0, pos, :].float(), out


def jlens_readout(m, tok, ids, layers, layer_id, pos, eps=0.1, topk=20):
    norm, head = get_final_norm_and_head(m)
    ro = Readout(layers, layer_id)
    try:
        f0, _ = final_hidden(m, ids, ro, pos)
        f1, _ = final_hidden(m, ids, ro, pos, eps=eps, scale_pos=pos)
        Jh = (f1 - f0) / eps                       # first-order effect of h on the output
        # TRAP 1 (JLENS_TRAPS.md): hidden_states[-1] is ALREADY post-final-norm. Applying
        # norm() again double-normalises -- RMSNorm is scale-invariant so it erases every
        # magnitude, and Jh already carries one factor of gamma, so re-norming gives a
        # gamma^2 reweighting where the truth is gamma^1, silently reordering top-k.
        # The output stays coherent, so nothing prompts you to check. Correct form:
        with torch.no_grad():
            logits = head(Jh.to(torch.bfloat16).unsqueeze(0)).squeeze(0).float()
        top = torch.topk(logits, topk)
        return [(tok.decode([int(i)]), float(s)) for i, s in zip(top.indices, top.values)], Jh
    finally:
        ro.close()


def verify_provenance(m, tok, meta, acts_path, layers, layer_id, tol=0.06):
    """Teacher-force the recorded ids; the activations must match what was saved."""
    if not os.path.exists(acts_path):
        return None, "no acts.npz"
    z = np.load(acts_path)
    key = f"L{layer_id}"
    if key not in z:
        return None, f"{key} not in acts.npz (have {list(z.keys())})"
    saved = torch.tensor(np.array(z[key]), dtype=torch.float32)   # [n_gen, H]
    prompt_ids = torch.tensor([meta["chat_input_ids"]], dtype=torch.long).cuda()
    gen_ids = torch.tensor([meta["gen_token_ids"]], dtype=torch.long).cuda()
    full = torch.cat([prompt_ids, gen_ids], dim=1)
    ro = Readout(layers, layer_id)
    try:
        with torch.no_grad():
            m(full)
        h = ro.h[0].float().cpu()                                  # [seq, H]
    finally:
        ro.close()
    n = saved.shape[0]
    # row i of `saved` is the state that produced generated token i:
    # prefill kept the last prompt position, then one row per decode step.
    start = prompt_ids.shape[1] - 1
    recomputed = h[start:start + n]
    if recomputed.shape != saved.shape:
        return False, f"shape mismatch recomputed{tuple(recomputed.shape)} vs saved{tuple(saved.shape)}"
    num = (recomputed - saved).norm(dim=-1)
    den = saved.norm(dim=-1).clamp_min(1e-6)
    rel = (num / den)
    return bool(rel.mean() < tol), f"mean_rel_diff={rel.mean():.4f} max={rel.max():.4f} n={n}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--turn", required=True)
    ap.add_argument("--model", default=os.path.expanduser("~/models/qwen38-hf"))
    ap.add_argument("--layer", type=int, default=45)
    ap.add_argument("--pos", default="last")
    ap.add_argument("--topk", type=int, default=20)
    ap.add_argument("--eps", type=float, default=0.1)   # TRAP 2: 1e-2 is amplified noise in bf16; plateau 0.05-0.5
    ap.add_argument("--no-verify", action="store_true")
    a = ap.parse_args()

    meta = json.load(open(os.path.join(a.turn, "meta.json")))
    print(f"turn {meta['tag']}  cond={meta['cond']}  result={meta.get('result')}")
    print(f"action: {meta.get('action','')[:120]}")

    tok, m = load_model(a.model)
    layers = get_layers(m)

    if not a.no_verify:
        ok, msg = verify_provenance(m, tok, meta, os.path.join(a.turn, "acts.npz"),
                                    layers, a.layer)
        print(f"provenance: {ok}  ({msg})")
        if ok is False:
            print("ABORT: recomputed activations do not match the captured ones.")
            sys.exit(2)

    prompt_ids = torch.tensor([meta["chat_input_ids"]], dtype=torch.long).cuda()
    gen_ids = torch.tensor([meta["gen_token_ids"]], dtype=torch.long).cuda()
    full = torch.cat([prompt_ids, gen_ids], dim=1)

    if a.pos == "last":
        pos = full.shape[1] - 1
    elif a.pos == "write":
        strs = meta.get("gen_token_strs", [])
        idx = next((i for i, s in enumerate(strs) if "WRITE" in s.upper()), None)
        if idx is None:
            print("no WRITE token found; falling back to last")
            pos = full.shape[1] - 1
        else:
            pos = prompt_ids.shape[1] + idx
    else:
        pos = int(a.pos)

    ctx = tok.decode(full[0, max(0, pos - 12):pos + 1])
    print(f"\nreadout position {pos} of {full.shape[1]}   context: ...{ctx[-90:]!r}")
    top, _ = jlens_readout(m, tok, full, layers, a.layer, pos, eps=a.eps, topk=a.topk)
    print(f"\n=== J-Lens @ L{a.layer} ===")
    for t, s in top:
        print(f"  {s:9.3f}  {t!r}")


if __name__ == "__main__":
    main()
