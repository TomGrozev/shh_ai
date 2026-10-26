"""Fine-tune a BERT token classifier for PII detection.

Base model: ``OpenMed/OpenMed-PII-ClinicalE5-Small-33M-v1`` (Apache-2.0,
``BertForTokenClassification``, hidden 384, ~33M params, fast tokenizer),
selected with ``--base-model``. The larger variant
``OpenMed/OpenMed-PII-ClinicalE5-Base-109M-v1`` has hidden 768 and ~109M params
and ships the same 106-row head in the same order, so the warm-start map below
is identical for both bases.

The base model ships a 54-label Nemotron head. Instead of throwing it away,
each contract BIO label (:mod:`pii_contract`) is warm-started from the mean of
the base rows that map onto it (first_name + last_name -> NAME, city + state +
country -> LOCATION, ...). Types with no source row (PASSPORT) keep a fresh
init. A warm head lets the run start from knowledge instead of noise, which
matters on a short fine-tune.

Runs on CPU (for smoke runs) and on a single CUDA GPU. fp16 is enabled
automatically when CUDA is available; disable with ``--no-fp16``.

After training, the best checkpoint is scored on the dev set and each entity
type gets the confidence threshold that maximises its own dev F1. The result
goes to ``<output>/pii_thresholds.json`` (``{"<lowercase type>": float}``),
the file ``export.py`` copies next to the model.

Examples
--------
    # GPU, full run
    python train.py --train data/train.jsonl --validation data/validation.jsonl \
        --output outputs/run1

    # CPU smoke
    python train.py --train data/train.jsonl --validation data/validation.jsonl \
        --output /tmp/smoke --max-steps 10 --eval-steps 5 --epochs 1 \
        --batch-size 4 --max-length 128 --device cpu
"""

from __future__ import annotations

import argparse
import inspect
import json
import os
from array import array

import numpy as np
import torch
from torch import nn
from torch.utils.data import Dataset
# Only this symbol is imported eagerly: the callbacks below need their base
# class at import time. The model/tokenizer imports stay lazy so a broken
# environment still prints ``--help``.
from transformers import TrainerCallback

from pii_contract import (
    ID2LABEL,
    LABEL2ID,
    LABELS,
    NEMOTRON_LABEL_MAP,
    TRAINED_TYPES,
    Record,
    read_jsonl,
    upper_type,
)

BASE_MODEL = "OpenMed/OpenMed-PII-ClinicalE5-Small-33M-v1"
O_ID = LABEL2ID["O"]

# The runtime splits long text at 512 tokens with 64 tokens of overlap
# (lib/shh_ai/pii/ner.ex). Training windows must match, or the model is fitted
# on a token distribution the runtime never produces.
DEFAULT_STRIDE = 64

FEATURE_KEYS = ("input_ids", "attention_mask", "token_type_ids")


# --------------------------------------------------------------------------
# Offset handling
# --------------------------------------------------------------------------
def _detect_byte_offsets(text: str, offsets) -> bool:
    """Fast tokenizers may report offsets in bytes; detect which unit we got.

    If the text is pure ASCII the two coincide, so the answer only matters
    for multibyte text, where a byte end offset can exceed the codepoint
    length of the text.
    """
    max_end = max((e for _s, e in offsets if e is not None), default=0)
    return max_end > len(text)


def _byte_index(text: str) -> list[int]:
    """Cumulative UTF-8 byte length per codepoint boundary."""
    out = [0] * (len(text) + 1)
    for i, ch in enumerate(text):
        out[i + 1] = out[i] + len(ch.encode("utf-8"))
    return out


def _best_span(spans, s: int, e: int):
    """Index of the span with the greatest overlap with token [s, e)."""
    best, best_ov = None, 0
    for i, (ss, se, _t) in enumerate(spans):
        ov = min(e, se) - max(s, ss)
        if ov > best_ov:
            best_ov, best = ov, i
    return best


def _spans_in_unit(rec: Record, byte_offsets: bool):
    if not byte_offsets:
        return [(s.start, s.end, s.type) for s in rec.spans]
    bi = _byte_index(rec.text)
    return [(bi[s.start], bi[s.end], s.type) for s in rec.spans]


def _ignores_in_unit(rec: Record, byte_offsets: bool) -> list[tuple[int, int]]:
    """Optional ``ignore`` ranges of a record, in the tokenizer's offset unit.

    The key is optional in the JSONL record and holds ``[[start, end], ...]``
    in codepoint offsets, like spans. Preparation uses it to keep a record
    whose identifier-shaped text has no contract type (``customer_id``,
    ``user_name``): those tokens must train as neither ``O`` nor an entity, or
    the model learns that identifier-shaped strings are ordinary text.
    Absent key means no ranges.
    """
    raw = getattr(rec, "ignore", None)
    if not raw:
        return []
    ranges = [(int(a), int(b)) for a, b in raw]
    if not byte_offsets:
        return ranges
    bi = _byte_index(rec.text)
    return [(bi[a], bi[b]) for a, b in ranges]


def _overlaps_ignore(s: int, e: int, ignores: list[tuple[int, int]]) -> bool:
    return any(s < ie and e > is_ for is_, ie in ignores)


def _label_window(offsets, word_ids, spans, ignores, label_all_subtokens: bool):
    """Labels for one window from its offset mapping.

    ``label_all_subtokens=True`` (default): every subtoken overlapping a span
    gets a label; continuation pieces of the same span get ``I-<TYPE>``, which
    is what the runtime merge expects (it folds ``##`` pieces into the running
    entity). ``label_all_subtokens=False``: only the first subtoken of a word
    is labelled; continuations get ``-100`` (ignored by the loss).

    A token overlapping an ``ignore`` range is ``-100`` and wins over both the
    ``O`` label and any span overlap.

    Returns ``(labels, covered)`` where ``covered`` holds the indices of spans
    that some token overlapped.
    """
    labels: list[int] = []
    covered: set[int] = set()
    prev_span = None
    prev_word = None
    for i, (s, e) in enumerate(offsets):
        wid = word_ids[i]
        if wid is None or s == e:  # special token or empty
            labels.append(-100)
            prev_span = None
            prev_word = None
            continue
        if ignores and _overlaps_ignore(s, e, ignores):
            labels.append(-100)
            prev_span = None
            prev_word = wid
            continue
        if not label_all_subtokens and wid == prev_word:
            labels.append(-100)
            prev_word = wid
            continue
        idx = _best_span(spans, s, e)
        if idx is None:
            labels.append(O_ID)
            prev_span = None
        else:
            covered.add(idx)
            prefix = "B" if idx != prev_span else "I"
            labels.append(LABEL2ID[f"{prefix}-{spans[idx][2].upper()}"])
            prev_span = idx
        prev_word = wid
    return labels, covered


class WindowDataset(Dataset):
    """Token-classification windows over contract records.

    Every record is split with ``return_overflowing_tokens`` into windows of at
    most ``max_length`` tokens that overlap by ``stride`` tokens. Nothing is
    truncated away, and window boundaries match the runtime's split.

    The constructor tokenizes each record once to learn its window layout and
    to store the labels per window (one ``array('b')`` per window, so ~512
    bytes). ``__getitem__`` re-tokenizes the same record and returns the
    requested window; the tokenizer is the cheap part of a step.

    A record may carry an optional ``ignore`` list of ``[start, end]``
    codepoint ranges (:func:`_ignores_in_unit`); tokens overlapping one of
    them are labelled ``-100``, so they train as neither ``O`` nor an entity.

    ``keep_offsets=True`` (validation sets only) also stores each window's
    token offsets and wordpiece-continuation flags. The metric rebuilds
    character spans per document from them, the way the runtime groups tokens.
    """

    def __init__(
        self,
        records,
        tokenizer,
        max_length: int = 512,
        stride: int = DEFAULT_STRIDE,
        label_all_subtokens: bool = True,
        keep_offsets: bool = False,
    ):
        self._records = records
        self._tokenizer = tokenizer
        self._max_length = max_length
        self._stride = stride
        self._label_all = label_all_subtokens
        self._keep_offsets = keep_offsets
        self._windows: list[tuple[int, int]] = []
        self._labels: list[array] = []
        # Flat (start, end) pairs per token, and one continuation byte per
        # token: 1 when the token repeats the previous token's word id, which
        # is how BERT marks a ``##`` continuation piece.
        self._offsets: list[array] = []
        self._cont: list[bytearray] = []
        self.uncovered = 0

        for rec_idx, rec in enumerate(records):
            enc = self._encode(rec)
            window_offsets = enc["offset_mapping"]
            char_offsets = [o for win in window_offsets for o in win]
            byte_offsets = _detect_byte_offsets(rec.text, char_offsets)
            spans = _spans_in_unit(rec, byte_offsets)
            ignores = _ignores_in_unit(rec, byte_offsets)
            covered: set[int] = set()
            for win_idx in range(len(enc["input_ids"])):
                word_ids = enc.word_ids(batch_index=win_idx)
                labels, win_covered = _label_window(
                    window_offsets[win_idx],
                    word_ids,
                    spans,
                    ignores,
                    label_all_subtokens,
                )
                covered |= win_covered
                self._windows.append((rec_idx, win_idx))
                self._labels.append(array("b", labels))
                if keep_offsets:
                    flat = array("i")
                    cont = bytearray()
                    prev_wid = -1
                    for (s, e), wid in zip(window_offsets[win_idx], word_ids):
                        flat.append(s)
                        flat.append(e)
                        cont.append(1 if wid is not None and wid == prev_wid else 0)
                        prev_wid = wid if wid is not None else -1
                    self._offsets.append(flat)
                    self._cont.append(cont)
            self.uncovered += len(spans) - len(covered)

    def _encode(self, rec: Record, with_offsets: bool = True):
        kwargs = {}
        if with_offsets:
            kwargs["return_offsets_mapping"] = True
        return self._tokenizer(
            rec.text,
            truncation=True,
            max_length=self._max_length,
            stride=self._stride,
            return_overflowing_tokens=True,
            add_special_tokens=True,
            **kwargs,
        )

    def __len__(self) -> int:
        return len(self._windows)

    def window_sources(self) -> list[str]:
        """Record ``source`` per window, in dataset order.

        The metric needs it: each dev source is scored on its own gold only.
        The order must match what ``__getitem__`` returns, which is the order
        the Trainer evaluates in.
        """
        return [self._records[rec_idx].source for rec_idx, _win in self._windows]

    def window_records(self) -> list[int]:
        """Record index per window, in dataset order."""
        return [rec_idx for rec_idx, _win in self._windows]

    def record_source(self, rec_idx: int) -> str:
        return self._records[rec_idx].source

    def window_segments(self) -> list[dict]:
        """Per-window token offsets, continuation flags and gold tags.

        Requires ``keep_offsets=True``. ``gold[i]`` is the contract label name
        of token ``i``, or ``None`` where the label is ``-100`` (special
        token, padding or an ``ignore`` range); those tokens are not scored.
        """
        if not self._keep_offsets:
            raise RuntimeError("window_segments() needs a dataset built with keep_offsets=True")
        segments = []
        for flat, cont, labels in zip(self._offsets, self._cont, self._labels):
            offs = [(flat[i], flat[i + 1]) for i in range(0, len(flat), 2)]
            segments.append({
                "offsets": offs,
                "cont": cont,
                "gold": [LABELS[l] if l != -100 else None for l in labels],
            })
        return segments

    def __getitem__(self, idx: int):
        rec_idx, win_idx = self._windows[idx]
        # Offsets are only needed to build the labels, which the constructor
        # already stored; asking for them here would slow every step.
        enc = self._encode(self._records[rec_idx], with_offsets=False)
        feature = {k: enc[k][win_idx] for k in FEATURE_KEYS if k in enc}
        feature["labels"] = self._labels[idx].tolist()
        return feature


# --------------------------------------------------------------------------
# Head initialisation from the base model's Nemotron head
# --------------------------------------------------------------------------
def contract_head_sources() -> dict[str, list[str]]:
    """Contract BIO label -> base-model BIO labels whose rows it averages.

    A contract type is fed by every base row whose entity label maps onto it in
    ``pii_contract.NEMOTRON_LABEL_MAP``: first_name + last_name -> NAME,
    city/state/country/county/street/postcode/coordinate -> LOCATION,
    occupation -> TITLE, and so on. Base rows with no contract type (api_key,
    gender, user_name, ...) contribute nothing.
    """
    sources: dict[str, list[str]] = {label: [] for label in LABELS}
    for base_label, lower_type in NEMOTRON_LABEL_MAP.items():
        contract = upper_type(lower_type)
        sources[f"B-{contract}"].append(f"B-{base_label}")
        sources[f"I-{contract}"].append(f"I-{base_label}")
    # ``occupation`` has no entry in NEMOTRON_LABEL_MAP because
    # pii_contract.map_nemotron_label decides per span whether it is a role
    # (title) or a department name (organization). The head cannot split rows
    # per span, and occupation is the only base source of role words, so its
    # rows go to TITLE: ORGANIZATION already has the clean company_name row.
    sources["B-TITLE"].append("B-occupation")
    sources["I-TITLE"].append("I-occupation")
    sources["O"].append("O")
    return sources


def init_head_from_base(model, base_id2label: dict[int, str]) -> dict[str, list[str]]:
    """Replace ``model.classifier`` with a warm ``len(LABELS)``-row head.

    Row ``LABEL2ID[label]`` becomes the mean of the base rows listed by
    :func:`contract_head_sources`. A source with no ``I-`` row in the base head
    (``age``, ``cvv``) falls back to its ``B-`` row: same concept, only one row
    exists. Contract labels with no source row keep the fresh normal init, so
    the head is never all zeros.

    Returns the mapping actually used (empty list = fresh init).
    """
    hidden = model.config.hidden_size
    old_head = model.classifier
    head = nn.Linear(hidden, len(LABELS))
    head.to(device=old_head.weight.device, dtype=old_head.weight.dtype)
    init_range = float(getattr(model.config, "initializer_range", 0.02) or 0.02)
    nn.init.normal_(head.weight, mean=0.0, std=init_range)
    nn.init.zeros_(head.bias)

    base_label2id = {label: int(idx) for idx, label in base_id2label.items()}
    used: dict[str, list[str]] = {}
    with torch.no_grad():
        for label, source_labels in contract_head_sources().items():
            rows: list[int] = []
            names: list[str] = []
            for src in source_labels:
                row = base_label2id.get(src)
                if row is None and src.startswith("I-"):
                    row = base_label2id.get("B-" + src[2:])
                    if row is not None:
                        names.append("B-" + src[2:])
                else:
                    names.append(src)
                if row is not None:
                    rows.append(row)
            if not rows:
                used[label] = []
                continue
            target = LABEL2ID[label]
            head.weight[target] = old_head.weight[rows].mean(dim=0)
            head.bias[target] = old_head.bias[rows].mean()
            used[label] = names

    model.classifier = head
    # Order matters: the num_labels setter rewrites id2label before we set it.
    model.config.num_labels = len(LABELS)
    model.config.id2label = dict(ID2LABEL)
    model.config.label2id = dict(LABEL2ID)
    model.num_labels = len(LABELS)
    return used


# --------------------------------------------------------------------------
# Metrics
# --------------------------------------------------------------------------
def _edge_distance(idx: int, length: int) -> int:
    """Distance of token ``idx`` from the nearer edge of a ``length``-token window."""
    return min(idx, length - 1 - idx)


def _group_entities(tokens) -> list[dict]:
    """Character spans from a token stream, grouped the way the runtime does.

    Mirrors ``group_tokens/1`` (lib/shh_ai/pii/ner.ex): a ``B-`` token starts a
    new entity, an ``I-<same type>`` token continues it, and a wordpiece
    continuation piece continues it even when labelled ``B-``. Tokens must be
    sorted by start offset. ``tokens`` holds ``(start, end, tag, is_piece)``,
    optionally followed by the token's score (the probability of its predicted
    label). An entity's ``score`` is the mean of its tokens' scores, as
    ``finalize_group/1`` in the runtime computes it; it is ``None`` when the
    tokens carry no scores.
    """
    groups: list[dict] = []
    cur = None
    for token in tokens:
        start, end, tag, is_piece = token[:4]
        score = token[4] if len(token) > 4 else None
        if tag is None or tag == "O":
            cur = None
            continue
        prefix, base = tag.split("-", 1)
        if cur is not None and cur["type"] == base and start >= cur["end"] \
                and (prefix == "I" or is_piece):
            cur["end"] = end
        else:
            cur = {"type": base, "start": start, "end": end,
                   "score_sum": 0.0, "count": 0}
            groups.append(cur)
        if score is not None:
            cur["score_sum"] += float(score)
            cur["count"] += 1
    return [{"type": g["type"], "start": g["start"], "end": g["end"],
             "score": g["score_sum"] / g["count"] if g["count"] else None}
            for g in groups]


def decode_windows(segments) -> tuple[list[dict], list[dict]]:
    """Gold and predicted character spans of one document, from its windows.

    Overlapping windows share tokens. Each shared token keeps the prediction
    from the window where it sits farthest from an edge, so a token is scored
    once and the window that saw the most context wins. ``segments`` holds one
    dict per window of the document: ``offsets`` (per-token char pairs), ``cont``
    (piece flags), ``gold`` (label names or ``None``) and ``pred`` (same shape).
    A token whose gold is ``None`` (``-100``) is dropped from both sides. An
    optional ``pred_score`` list adds the per-token probability of the predicted
    label; the predicted spans then carry the mean as ``score``.
    """
    best: dict[tuple[int, int], tuple] = {}
    for seg in segments:
        gold = seg["gold"]
        pred = seg["pred"]
        cont = seg["cont"]
        offsets = seg["offsets"]
        pred_score = seg.get("pred_score")
        n = len(gold)
        for i in range(n):
            if gold[i] is None:
                continue
            start, end = offsets[i]
            if start == end:  # empty token, cannot be an entity
                continue
            dist = _edge_distance(i, n)
            key = (start, end)
            if key not in best or dist > best[key][0]:
                score = None if pred_score is None else pred_score[i]
                best[key] = (dist, gold[i], pred[i], bool(cont[i]), score)

    order = sorted(best.items())
    gold_tokens = [(s, e, v[1], v[3]) for (s, e), v in order]
    pred_tokens = [(s, e, v[2], v[3], v[4]) for (s, e), v in order]
    return _group_entities(gold_tokens), _group_entities(pred_tokens)


def match_doc(gold, predicted) -> tuple[list[str], list[str], list[str]]:
    """One-to-one greedy match of predicted spans onto gold spans.

    Port of ``match_doc/2`` in test/eval/support/scorer.ex: gold spans are walked
    in order and each takes the first unused prediction that overlaps it and has
    the same type. Returns ``(tp_types, fp_types, fn_types)``.
    """
    tp: list[str] = []
    missed: list[str] = []
    avail = list(predicted)
    for g in gold:
        hit = None
        for i, p in enumerate(avail):
            if p["type"] == g["type"] and p["start"] < g["end"] and g["start"] < p["end"]:
                hit = i
                break
        if hit is None:
            missed.append(g["type"])
        else:
            tp.append(g["type"])
            avail.pop(hit)
    return tp, [p["type"] for p in avail], missed


def _prf(tp: int, fp: int, fn: int) -> tuple[float, float, float]:
    """Precision, recall and F1 from one type's counts (0.0 when undefined)."""
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / (tp + fn) if tp + fn else 0.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    return precision, recall, f1


def types_by_source(docs) -> dict[str, set[str]]:
    """The entity types each dev source's gold covers.

    A source is scored only on the types its own gold marks (see
    ``MetricsReporter``); the threshold sweep applies the same rule, so it
    measures a type over exactly the documents the checkpoint metric does.
    """
    source_types: dict[str, set[str]] = {}
    for src, gold, _predicted in docs:
        source_types.setdefault(src, set()).update(s["type"] for s in gold)
    return source_types


class MetricsReporter:
    """Span+type F1 with the held-out benchmark's rule, for checkpoint selection.

    Scoring follows ``ShhAi.Eval.Scorer`` (test/eval/support/scorer.ex): a
    prediction is a true positive when it overlaps a gold span and has the same
    type; matching is one-to-one and greedy, per document, after the windows of
    that document are merged. Span overlap ignores boundary drift, which is what
    the benchmark measures, and what the previous seqeval exact-span metric did
    not.

    Dev sources are annotated to different depths: gretel marks every PII span
    it generated, Nemotron marks its full span list, and neither covers every
    contract type (gretel-en has no TITLE or AGE row). So each source is scored
    only on the entity types its own gold covers, as the benchmark does. Per-type
    counts are then pooled, so a type is measured once, over the sources that
    can measure it.

    Model selection uses macro F1 over types with gold support. Micro F1 hides
    the rare contract types the runtime needs (SSN, PASSPORT, ...), so a model
    that only learns NAME and DATE still scores high.

    ``eval_ds`` must be built with ``keep_offsets=True``; its window order is
    the order the Trainer evaluates in.
    """

    def __init__(self, eval_ds: WindowDataset):
        self.dataset = eval_ds
        self.window_sources = eval_ds.window_sources()
        self.table: dict[str, dict] = {}
        self.by_source: dict[str, dict] = {}

    @staticmethod
    def _prf(tp: int, fp: int, fn: int) -> tuple[float, float, float]:
        return _prf(tp, fp, fn)

    def documents(self, preds, scores=None):
        """Per-document ``(source, gold, predicted)`` spans, windows merged.

        ``preds`` holds one predicted label id per token per window. ``scores``,
        when given, holds one score per token per window; the predicted spans
        then carry their mean as ``score`` (the runtime's entity confidence).
        """
        segments = self.dataset.window_segments()
        records = self.dataset.window_records()
        if len(preds) != len(self.window_sources):
            raise RuntimeError(
                f"metric/window mismatch: {len(preds)} "
                f"prediction rows for {len(self.window_sources)} known windows"
            )

        windows_of: dict[int, list[int]] = {}
        for w, rec_idx in enumerate(records):
            windows_of.setdefault(rec_idx, []).append(w)

        docs: list[tuple[str, list[dict], list[dict]]] = []
        for rec_idx in sorted(windows_of):
            doc_segments = []
            for w in windows_of[rec_idx]:
                seg = segments[w]
                window_len = len(seg["gold"])
                seg = dict(seg)
                seg["pred"] = [
                    LABELS[int(preds[w][i])] if i < window_len else None
                    for i in range(window_len)
                ]
                if scores is not None:
                    seg["pred_score"] = scores[w]
                doc_segments.append(seg)
            gold, predicted = decode_windows(doc_segments)
            docs.append((self.dataset.record_source(rec_idx), gold, predicted))
        return docs

    def compute(self, eval_pred):
        logits, labels = eval_pred[0], eval_pred[1]
        preds = np.argmax(logits, axis=-1)
        if len(labels) != len(self.window_sources) or len(preds) != len(self.window_sources):
            raise RuntimeError(
                f"metric/window mismatch: {len(labels)} labels and {len(preds)} "
                f"prediction rows for {len(self.window_sources)} known windows"
            )

        docs = self.documents(preds)

        # A source is scored only on the types its gold covers (benchmark rule).
        source_types = types_by_source(docs)

        # type -> [tp, fp, fn], pooled over the sources that cover the type.
        counts = {t: [0, 0, 0] for t in TRAINED_TYPES}
        source_counts = {src: [0, 0, 0] for src in source_types}
        for src, gold, predicted in docs:
            allowed = source_types[src]
            predicted = [p for p in predicted if p["type"] in allowed]
            tp, fp, fn = match_doc(gold, predicted)
            for types, slot in ((tp, 0), (fp, 1), (fn, 2)):
                for etype in types:
                    counts[etype][slot] += 1
                    source_counts[src][slot] += 1

        self.table = {}
        macro_parts: list[float] = []
        for etype, (tp, fp, fn) in counts.items():
            if tp + fp + fn == 0:
                continue
            precision, recall, f1 = self._prf(tp, fp, fn)
            self.table[etype] = {"tp": tp, "fp": fp, "fn": fn,
                                 "precision": precision, "recall": recall,
                                 "f1-score": f1, "support": tp + fn}
            if tp + fn:  # a type with no gold anywhere cannot be averaged in
                macro_parts.append(f1)

        self.by_source = {}
        for src, (tp, fp, fn) in source_counts.items():
            precision, recall, f1 = self._prf(tp, fp, fn)
            self.by_source[src] = {"tp": tp, "fp": fp, "fn": fn,
                                   "precision": precision, "recall": recall,
                                   "f1-score": f1, "support": tp + fn,
                                   "types": len(source_types[src])}

        if not macro_parts:
            return {"precision": 0.0, "recall": 0.0, "micro_f1": 0.0, "macro_f1": 0.0}

        tp = sum(c[0] for c in counts.values())
        fp = sum(c[1] for c in counts.values())
        fn = sum(c[2] for c in counts.values())
        precision, recall, micro_f1 = self._prf(tp, fp, fn)
        return {
            "precision": precision,
            "recall": recall,
            "micro_f1": micro_f1,
            "macro_f1": sum(macro_parts) / len(macro_parts),
        }

    def render(self) -> str:
        """Per-source summary, then the pooled per-type table."""
        if not self.table:
            return "  (no entities in the validation windows)"
        lines = ["  per source (types its gold covers only, span+type match):"]
        for src in sorted(self.by_source):
            row = self.by_source[src]
            lines.append(
                f"  {src:<46s} P={row['precision']:5.3f} R={row['recall']:5.3f} "
                f"F1={row['f1-score']:5.3f} tp={int(row['tp']):6d} "
                f"fp={int(row['fp']):6d} fn={int(row['fn']):6d} "
                f"types={int(row['types'])}"
            )
        lines.append(
            f"  pooled {'type':<14s} {'TP':>7s} {'FP':>6s} {'FN':>6s} "
            f"{'P':>6s} {'R':>6s} {'F1':>6s} {'n':>7s}"
        )
        for t in TRAINED_TYPES:
            row = self.table.get(t)
            if row is None:
                continue
            lines.append(
                f"  {'':<6s} {t:<14s} {int(row['tp']):7d} {int(row['fp']):6d} "
                f"{int(row['fn']):6d} {row['precision']:6.3f} {row['recall']:6.3f} "
                f"{row['f1-score']:6.3f} {int(row['support']):7d}"
            )
        return "\n".join(lines)


# --------------------------------------------------------------------------
# Per-type confidence thresholds, swept on the dev set
# --------------------------------------------------------------------------
# The runtime filters every detection against a per-type threshold
# (``above_threshold?/3`` in lib/shh_ai/pii/ner.ex) and compares the entity's
# mean token probability with it. One global cutoff gives every type the
# confidence profile of the noisiest one, so the sweep below gives each type
# the cutoff that maximises its own dev F1 under the benchmark's span rule.
def token_confidences(logits, segments) -> list[list[float]]:
    """Probability of each window token's predicted label, per window.

    Rows are trimmed to the window's token count: ``Trainer.predict`` pads
    batches to a common length, and a padded position is not a token.
    """
    scores: list[list[float]] = []
    for w, seg in enumerate(segments):
        n = len(seg["gold"])
        row = np.asarray(logits[w][:n], dtype=np.float32)
        row = row - row.max(axis=-1, keepdims=True)
        probs = np.exp(row)
        probs /= probs.sum(axis=-1, keepdims=True)
        best = row.argmax(axis=-1)
        scores.append(probs[np.arange(n), best].tolist())
    return scores


def type_counts(docs, source_types, etype: str,
                threshold: float) -> tuple[int, int, int]:
    """TP, FP, FN of one type at one threshold, over the sources that cover it.

    The match is the benchmark's one-to-one overlap rule, restricted to one
    type: ``match_doc`` pairs only same-type spans, so the restriction leaves
    that type's counts unchanged. ``threshold <= 0`` keeps every argmax
    prediction, which is the "before" row.
    """
    tp = fp = fn = 0
    for src, gold, predicted in docs:
        if etype not in source_types[src]:
            continue
        gold_spans = [g for g in gold if g["type"] == etype]
        pred_spans = [p for p in predicted if p["type"] == etype
                      and (threshold <= 0 or p["score"] >= threshold)]
        hit, false, missed = match_doc(gold_spans, pred_spans)
        tp += len(hit)
        fp += len(false)
        fn += len(missed)
    return tp, fp, fn


def sweep_type_thresholds(docs, source_types, lo: float = 0.30,
                          hi: float = 0.95, step: float = 0.05) -> dict[str, dict]:
    """Pick each type's dev-F1-maximising confidence threshold.

    The grid runs from ``lo`` to ``hi``. Argmax (no filter) is also a
    candidate, reported as threshold ``0.0``: every grid point is stricter than
    argmax, so without it the pick could cost F1 on a type whose predictions
    sit below ``lo``. A tie keeps the lowest threshold, so the sweep keeps
    recall when the F1 is flat. Types whose gold no dev source covers are left
    out: their counts would be 0/0/0 at every threshold and the pick would be
    meaningless.
    """
    grid: list[float] = []
    value = lo
    while value <= hi + 1e-9:
        grid.append(round(value, 4))
        value += step

    report: dict[str, dict] = {}
    for etype in TRAINED_TYPES:
        if not any(etype in types for types in source_types.values()):
            continue
        tp0, fp0, fn0 = type_counts(docs, source_types, etype, 0.0)
        p0, r0, f1_before = _prf(tp0, fp0, fn0)
        best = {"threshold": 0.0, "f1_after": f1_before, "precision": p0,
                "recall": r0, "tp": tp0, "fp": fp0, "fn": fn0}
        for threshold in grid:
            tp, fp, fn = type_counts(docs, source_types, etype, threshold)
            precision, recall, f1 = _prf(tp, fp, fn)
            if f1 > best["f1_after"] + 1e-12:
                best = {"threshold": threshold, "f1_after": f1,
                        "precision": precision, "recall": recall,
                        "tp": tp, "fp": fp, "fn": fn}
        best["f1_before"] = f1_before
        best["support"] = tp0 + fn0
        report[etype] = best
    return report


def render_threshold_table(report: dict[str, dict]) -> str:
    """The dev F1 of each type at argmax and at its chosen threshold."""
    if not report:
        return "  (no dev entities; thresholds not swept)"
    lines = [
        "  per-type confidence threshold (best checkpoint, dev, span rule):",
        f"  {'type':<14s} {'thr':>6s} {'F1 before':>10s} {'F1 after':>9s} "
        f"{'P':>6s} {'R':>6s} {'n':>7s}",
    ]
    for etype, row in report.items():
        lines.append(
            f"  {etype:<14s} {row['threshold']:6.2f} {row['f1_before']:10.3f} "
            f"{row['f1_after']:9.3f} {row['precision']:6.3f} {row['recall']:6.3f} "
            f"{int(row['support']):7d}"
        )
    before = sum(r["f1_before"] for r in report.values()) / len(report)
    after = sum(r["f1_after"] for r in report.values()) / len(report)
    lines.append(f"  macro over {len(report)} measured types: "
                 f"F1 {before:.4f} -> {after:.4f}")
    missing = [t for t in TRAINED_TYPES if t not in report]
    if missing:
        lines.append(f"  not measured (no dev gold): {', '.join(missing)}")
    return "\n".join(lines)


def write_type_thresholds(path: str, report: dict[str, dict]) -> dict[str, float]:
    """Write ``{"<lowercase type>": threshold}`` for the runtime.

    Keys are the runtime's PII type names (``ShhAi.Config.supported_pii_types``,
    lowercased), which is also the spelling ``PII_NER_TYPE_THRESHOLDS`` parses.
    A value of ``0.0`` means argmax beat every grid point: keep all predictions
    of that type instead of cutting any away.
    """
    thresholds = {etype.lower(): round(row["threshold"], 4)
                  for etype, row in sorted(report.items())}
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(thresholds, fh, indent=2)
        fh.write("\n")
    return thresholds


class EvalLogCallback(TrainerCallback):
    """Print metric summary + per-type table after every evaluation."""

    def __init__(self, reporter: MetricsReporter):
        super().__init__()
        self.reporter = reporter

    def on_evaluate(self, args, state, control, metrics=None, **kwargs):
        m = metrics or {}
        epoch = state.epoch if state.epoch is not None else 0.0
        print(
            f"[eval] step {state.global_step} (epoch {epoch:.2f}) "
            f"macro_f1={m.get('eval_macro_f1', float('nan')):.4f} "
            f"micro_f1={m.get('eval_micro_f1', float('nan')):.4f} "
            f"P={m.get('eval_precision', float('nan')):.4f} "
            f"R={m.get('eval_recall', float('nan')):.4f}",
            flush=True,
        )
        print(self.reporter.render(), flush=True)


class FreezeEncoderCallback(TrainerCallback):
    """Freeze the encoder parameters for the first ``steps`` optimizer steps.

    Only active with ``--freeze-encoder-steps > 0``. It stops the first, noisy
    head updates from dragging pretrained features before the head settles.
    The default is 0: the head is already warm from the base model, so a plain
    short warmup is enough and freezing only shortens the useful updates.
    """

    def __init__(self, steps: int):
        super().__init__()
        self.steps = steps

    def _freeze(self, model, frozen: bool) -> None:
        for name, param in model.named_parameters():
            if not name.startswith("classifier."):
                param.requires_grad = not frozen

    def on_train_begin(self, args, state, control, model=None, **kwargs):
        if self.steps > 0 and model is not None:
            self._freeze(model, True)

    def on_step_begin(self, args, state, control, model=None, **kwargs):
        if self.steps > 0 and state.global_step >= self.steps and model is not None:
            self._freeze(model, False)


# --------------------------------------------------------------------------
# Device selection
# --------------------------------------------------------------------------
def _select_device(preference: str = "auto") -> torch.device:
    """Resolve the training device: CUDA, else Apple MPS, else CPU.

    ``transformers`` picks MPS by itself, but this pipeline never said so: on an
    Apple Silicon Mac the run logged ``device=cpu`` while actually training on
    the GPU. Resolve it in one place and pin it below so the log and the
    compute cannot disagree.
    """
    if preference != "auto":
        return torch.device(preference)
    if torch.cuda.is_available():
        return torch.device("cuda")
    if hasattr(torch.backends, "mps") and torch.backends.mps.is_available() \
            and torch.backends.mps.is_built():
        return torch.device("mps")
    return torch.device("cpu")


# --------------------------------------------------------------------------
# Optimizer: separate learning rates for the warm head and the encoder
# --------------------------------------------------------------------------
def _build_optimizer(model, encoder_lr: float, head_lr: float, weight_decay: float):
    """AdamW with four groups: head/encoder x decay/no-decay.

    Bias and LayerNorm never get weight decay. A fresh (or warm-started from a
    different label set) head needs a larger step than the pretrained encoder,
    which is easy to destroy: hence 2e-4 for the head against 3e-5 for the
    encoder by default.
    """
    groups: dict[tuple[bool, bool], list] = {
        (False, False): [],
        (False, True): [],
        (True, False): [],
        (True, True): [],
    }
    for name, param in model.named_parameters():
        if not param.requires_grad:
            continue
        is_head = name.startswith("classifier.")
        no_decay = name.endswith("bias") or "LayerNorm.weight" in name
        groups[(is_head, no_decay)].append(param)

    param_groups = []
    for (is_head, no_decay), params in groups.items():
        if not params:
            continue
        param_groups.append({
            "params": params,
            "lr": head_lr if is_head else encoder_lr,
            "weight_decay": 0.0 if no_decay else weight_decay,
        })
    return torch.optim.AdamW(param_groups)


# --------------------------------------------------------------------------
# TrainingArguments compatibility across transformers versions
# --------------------------------------------------------------------------
def _training_arguments(**kwargs):
    from transformers import TrainingArguments

    params = inspect.signature(TrainingArguments.__init__).parameters
    if "eval_strategy" not in params and "evaluation_strategy" in params:
        kwargs["evaluation_strategy"] = kwargs.pop("eval_strategy")
    return TrainingArguments(**kwargs)


def _build_trainer(model, args, reporter, callbacks, optimizer, train_ds, eval_ds, tokenizer):
    from transformers import DataCollatorForTokenClassification, Trainer

    collator = DataCollatorForTokenClassification(tokenizer)
    trainer_kwargs = dict(
        model=model,
        args=args,
        train_dataset=train_ds,
        eval_dataset=eval_ds,
        data_collator=collator,
        compute_metrics=reporter.compute,
        callbacks=callbacks,
        # Supplying the optimizer keeps the two learning rates; the Trainer
        # still builds the warmup/decay schedule on top of it.
        optimizers=(optimizer, None),
    )
    # ``tokenizer=`` was renamed to ``processing_class=`` in transformers 4.46+.
    if "processing_class" in inspect.signature(Trainer.__init__).parameters:
        trainer_kwargs["processing_class"] = tokenizer
    else:
        trainer_kwargs["tokenizer"] = tokenizer
    return Trainer(**trainer_kwargs)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--train", default=os.path.join(os.path.dirname(__file__), "data/train.jsonl"))
    ap.add_argument("--validation", default=os.path.join(os.path.dirname(__file__), "data/validation.jsonl"))
    ap.add_argument("--output", required=True, help="output dir (checkpoints + final model)")
    ap.add_argument("--base-model", default=BASE_MODEL)
    ap.add_argument("--max-length", type=int, default=512)
    ap.add_argument("--stride", type=int, default=DEFAULT_STRIDE,
                    help="window overlap in tokens; must match the runtime (64)")
    ap.add_argument("--batch-size", type=int, default=16)
    ap.add_argument("--eval-batch-size", type=int, default=32)
    ap.add_argument("--learning-rate", type=float, default=3e-5,
                    help="encoder learning rate")
    ap.add_argument("--head-learning-rate", type=float, default=2e-4,
                    help="classifier head learning rate")
    ap.add_argument("--epochs", type=float, default=5.0)
    ap.add_argument("--weight-decay", type=float, default=0.01)
    ap.add_argument("--warmup-ratio", type=float, default=0.05)
    ap.add_argument("--eval-steps", type=int, default=500,
                    help="evaluate and checkpoint every N optimizer steps")
    ap.add_argument("--early-stopping-patience", type=int, default=4,
                    help="stop after N evaluations without macro-F1 improvement")
    ap.add_argument("--freeze-encoder-steps", type=int, default=0,
                    help="freeze the encoder for the first N steps (0 = never)")
    ap.add_argument("--max-steps", type=int, default=-1, help="smoke runs; -1 = full")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--first-subtoken-only", action="store_true",
                    help="label only the first subtoken of each word "
                         "(default: label every subtoken, continuations as I-)")
    ap.add_argument("--no-fp16", action="store_true")
    ap.add_argument("--device", default="auto", choices=("auto", "cuda", "mps", "cpu"),
                    help="training device (auto = cuda, else mps, else cpu)")
    ap.add_argument("--threads", type=int, default=0,
                    help="torch/OMP thread cap (0 = leave as-is)")
    ap.add_argument("--threshold-min", type=float, default=0.30,
                    help="lowest per-type confidence threshold in the dev sweep")
    ap.add_argument("--threshold-max", type=float, default=0.95,
                    help="highest per-type confidence threshold in the dev sweep")
    ap.add_argument("--threshold-step", type=float, default=0.05,
                    help="per-type threshold sweep step")
    ap.add_argument("--thresholds-file", default=None,
                    help="where to write pii_thresholds.json "
                         "(default: <output>/pii_thresholds.json)")
    args = ap.parse_args(argv)

    if args.threads:
        torch.set_num_threads(args.threads)
        os.environ.setdefault("OMP_NUM_THREADS", str(args.threads))

    from transformers import AutoModelForTokenClassification, AutoTokenizer, EarlyStoppingCallback

    train_records = read_jsonl(args.train)
    eval_records = read_jsonl(args.validation)
    print(f"[train] {len(train_records)} train / {len(eval_records)} validation records")
    if not eval_records:
        raise SystemExit(f"{args.validation} has no validation records")

    tokenizer = AutoTokenizer.from_pretrained(args.base_model, use_fast=True)
    if not tokenizer.is_fast:
        raise SystemExit(f"{args.base_model} has no fast tokenizer; Bumblebee needs tokenizer.json")

    # Load the base model WITH its own head: the head rows are the knowledge we
    # transplant into the contract label space below.
    model = AutoModelForTokenClassification.from_pretrained(args.base_model)
    base_id2label = {int(k): v for k, v in model.config.id2label.items()}
    used = init_head_from_base(model, base_id2label)
    warm = sum(1 for rows in used.values() if rows)
    fresh = sorted(label for label, rows in used.items() if not rows)
    print(f"[train] head: {warm}/{len(LABELS)} contract labels warm-started from "
          f"{len(base_id2label)} base rows; fresh init for {fresh or 'none'}")
    for label in LABELS:
        sources = used.get(label)
        if sources:
            print(f"[train]   {label:<16s} <- {', '.join(sources)}")

    label_all = not args.first_subtoken_only
    train_ds = WindowDataset(train_records, tokenizer, args.max_length, args.stride, label_all)
    eval_ds = WindowDataset(eval_records, tokenizer, args.max_length, args.stride, label_all,
                            keep_offsets=True)
    print(f"[train] windows: {len(train_ds)} train / {len(eval_ds)} validation "
          f"(max_length={args.max_length}, stride={args.stride}, "
          f"label_all_subtokens={label_all})")
    if train_ds.uncovered or eval_ds.uncovered:
        print(f"[train] WARNING: {train_ds.uncovered} train / {eval_ds.uncovered} validation "
              f"spans had no covering token (boundary alignment)")

    device = _select_device(args.device)
    # fp16 is a CUDA-only path here: Trainer has no MPS fp16 autocast, and CPU
    # fp16 is slower than fp32.
    use_fp16 = device.type == "cuda" and not args.no_fp16

    steps_per_epoch = max(1, len(train_ds) // args.batch_size)
    total_steps = args.max_steps if args.max_steps > 0 else int(steps_per_epoch * args.epochs)
    print(f"[train] ~{steps_per_epoch} steps/epoch, {total_steps} total; "
          f"eval every {args.eval_steps} steps, patience {args.early_stopping_patience} evals")

    training_args = _training_arguments(
        use_cpu=device.type == "cpu",
        output_dir=args.output,
        overwrite_output_dir=True,
        per_device_train_batch_size=args.batch_size,
        per_device_eval_batch_size=args.eval_batch_size,
        learning_rate=args.learning_rate,
        num_train_epochs=args.epochs,
        weight_decay=args.weight_decay,
        warmup_ratio=args.warmup_ratio,
        max_steps=args.max_steps,
        eval_strategy="steps",
        eval_steps=args.eval_steps,
        save_strategy="steps",
        save_steps=args.eval_steps,
        save_total_limit=2,
        load_best_model_at_end=True,
        metric_for_best_model="macro_f1",
        greater_is_better=True,
        logging_steps=50,
        fp16=use_fp16,
        seed=args.seed,
        dataloader_num_workers=0,
        report_to=[],
    )

    optimizer = _build_optimizer(model, args.learning_rate, args.head_learning_rate,
                                 args.weight_decay)
    reporter = MetricsReporter(eval_ds)
    callbacks = [EvalLogCallback(reporter),
                 EarlyStoppingCallback(early_stopping_patience=args.early_stopping_patience)]
    if args.freeze_encoder_steps > 0:
        callbacks.append(FreezeEncoderCallback(args.freeze_encoder_steps))

    trainer = _build_trainer(model, training_args, reporter, callbacks, optimizer,
                             train_ds, eval_ds, tokenizer)
    actual = trainer.accelerator.device
    if actual.type != device.type:
        raise SystemExit(
            f"requested device {device} but the Trainer resolved {actual}; "
            "check ACCELERATE_USE_CPU / CUDA_VISIBLE_DEVICES"
        )
    print(f"[train] device={actual} fp16={use_fp16} "
          f"lr(encoder)={args.learning_rate} lr(head)={args.head_learning_rate}")
    trainer.train()

    metrics = trainer.evaluate()
    print(f"[train] best-checkpoint validation metrics: {metrics}")

    # ``trainer.train()`` reloads the best checkpoint at the end
    # (load_best_model_at_end), so this pass scores exactly the weights that
    # ``final/`` will hold.
    print(f"[train] threshold sweep on the dev set "
          f"({args.threshold_min:.2f}-{args.threshold_max:.2f} "
          f"step {args.threshold_step:.2f}), checkpoint "
          f"{trainer.state.best_model_checkpoint or 'final weights'}")
    prediction = trainer.predict(eval_ds)
    logits = prediction.predictions
    if logits is None:
        print("[train] WARNING: Trainer.predict returned no logits; "
              "pii_thresholds.json not written")
    else:
        segments = eval_ds.window_segments()
        scores = token_confidences(logits, segments)
        docs = reporter.documents(np.argmax(logits, axis=-1), scores)
        report = sweep_type_thresholds(docs, types_by_source(docs),
                                       args.threshold_min,
                                       args.threshold_max,
                                       args.threshold_step)
        print(render_threshold_table(report), flush=True)
        thresholds_path = args.thresholds_file or os.path.join(
            args.output, "pii_thresholds.json")
        os.makedirs(os.path.dirname(os.path.abspath(thresholds_path)), exist_ok=True)
        write_type_thresholds(thresholds_path, report)
        print(f"[train] wrote {len(report)} per-type thresholds to "
              f"{os.path.abspath(thresholds_path)}")

    final_dir = os.path.join(args.output, "final")
    trainer.save_model(final_dir)
    tokenizer.save_pretrained(final_dir)
    print(f"[train] saved final model to {final_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
