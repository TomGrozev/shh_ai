"""Package a trained checkpoint into a Bumblebee-loadable directory.

Writes safetensors weights, ``config.json`` (with the contract ``id2label``),
and a *fast* ``tokenizer.json`` into ``--out`` so the runtime can load it with
``Bumblebee.load_model({:local, dir})`` / ``Bumblebee.load_tokenizer({:local, dir})``.
``train.py``'s ``pii_thresholds.json`` (the per-type dev thresholds) is copied
alongside them when it is present.

Usage
-----
    python export.py --model outputs/run1/final --out export/pii-ner
    # optional, never run by the pipeline:
    python export.py --model outputs/run1/final --out export/pii-ner --push-to-hub USER/repo
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys

from pii_contract import ID2LABEL, LABEL2ID, LABELS

REQUIRED_FILES = ("config.json", "model.safetensors", "tokenizer.json")

# ``train.py`` writes the per-type confidence thresholds into its output dir;
# the model lives in ``<output>/final``, so both locations are searched.
THRESHOLDS_FILE = "pii_thresholds.json"


def _find_thresholds(model_dir: str) -> str | None:
    """Locate ``pii_thresholds.json`` for a checkpoint, if the run wrote one."""
    for candidate in (model_dir, os.path.dirname(os.path.abspath(model_dir))):
        path = os.path.join(candidate, THRESHOLDS_FILE)
        if os.path.exists(path):
            return path
    return None


def _copy_thresholds(src: str, out: str) -> None:
    """Validate and copy the threshold JSON next to the exported model."""
    with open(src, encoding="utf-8") as fh:
        thresholds = json.load(fh)
    if not isinstance(thresholds, dict) or not all(
            isinstance(k, str) and isinstance(v, (int, float))
            for k, v in thresholds.items()):
        raise SystemExit(f"[export] ERROR: {src} is not a {{type: threshold}} object")
    dst = os.path.join(out, THRESHOLDS_FILE)
    with open(dst, "w", encoding="utf-8") as fh:
        json.dump(thresholds, fh, indent=2)
        fh.write("\n")
    print(f"[export] wrote {len(thresholds)} per-type thresholds to {dst}")


def _copy_tokenizer_files(src_dir: str, out: str) -> None:
    """Copy tokenizer sidecar files a Bumblebee loader expects, if the fast
    tokenizer's own save did not already emit them."""
    wanted = ("tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "vocab.txt")
    for name in wanted:
        dst = os.path.join(out, name)
        src = os.path.join(src_dir, name)
        if not os.path.exists(dst) and os.path.exists(src) and \
                os.path.abspath(src) != os.path.abspath(dst):
            shutil.copyfile(src, dst)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", required=True, help="trained checkpoint/final dir")
    ap.add_argument("--out", required=True, help="destination directory")
    ap.add_argument("--push-to-hub", default=None,
                    help="HF repo id to push to (NOT run by the pipeline)")
    ap.add_argument("--thresholds", default=None,
                    help="pii_thresholds.json to copy (default: found next to the "
                         "checkpoint or in its parent dir)")
    args = ap.parse_args(argv)

    from transformers import AutoConfig, AutoModelForTokenClassification, AutoTokenizer

    os.makedirs(args.out, exist_ok=True)

    config = AutoConfig.from_pretrained(args.model)
    config.id2label = ID2LABEL
    config.label2id = LABEL2ID
    config.num_labels = len(LABELS)
    config.architectures = ["BertForTokenClassification"]

    model = AutoModelForTokenClassification.from_pretrained(args.model, config=config)
    model.save_pretrained(args.out, safe_serialization=True)

    tokenizer = AutoTokenizer.from_pretrained(args.model, use_fast=True)
    if not tokenizer.is_fast:
        print("[export] ERROR: tokenizer is not fast; Bumblebee needs tokenizer.json",
              file=sys.stderr)
        return 1
    tokenizer.save_pretrained(args.out)
    _copy_tokenizer_files(args.model, args.out)

    thresholds_src = args.thresholds or _find_thresholds(args.model)
    if thresholds_src:
        _copy_thresholds(thresholds_src, args.out)
    else:
        print("[export] WARNING: no pii_thresholds.json found for this checkpoint; "
              "the runtime will use its global NER threshold for every type",
              file=sys.stderr)

    missing = [f for f in REQUIRED_FILES if not os.path.exists(os.path.join(args.out, f))]
    if missing:
        print(f"[export] ERROR: missing required files: {missing}", file=sys.stderr)
        return 1

    print(f"[export] wrote Bumblebee-loadable model to {os.path.abspath(args.out)}")
    for f in sorted(os.listdir(args.out)):
        print(f"    {f}")

    if args.push_to_hub:
        print(f"[export] --push-to-hub {args.push_to_hub}: not run (publishing is a human step)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
