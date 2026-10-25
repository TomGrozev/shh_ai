# Held-out benchmark: TAB QUASI mentions are neutral, results are reported per source

## Status

Accepted _(2026-10-25)_ — issue #79 (fine-tuned PII NER model).

## Context

The held-out benchmark (`heldout_v1.jsonl`, built by
`training/build_heldout.py`) mixes three sources: gretel-en, gretel-finance
and TAB (ECHR court cases, `ildpil/text-anonymization-benchmark`). The first
two are synthetic and mark every PII mention they contain. TAB is real legal
prose annotated under the Text Anonymization Benchmark policy, which splits
each mention into `DIRECT` (unambiguous PII that must be masked), `QUASI`
(context-dependent quasi-identifiers: real places, dates, persons,
organisations, case codes) and `NO_MASK` (explicitly not personal data).

The benchmark scored only `DIRECT` mentions as gold and treated everything
else as ordinary prose. That made every correct detection on a `QUASI`
mention a false positive:

* TAB contributed 55% of the fine-tuned model's false positives and 72% of
  the shipped model's, and 6058 of the QUASI ranges in the sampled documents
  were scored as prose.
* The distortion was not random. The shipped model tagged 762 TAB
  `organization` false positives; the street-address regex rewrote many of
  them to `location` (822 location false positives), because
  `merge_detections/2` lets a regex match overwrite a NER type. A large share
  of those spans are court names the annotators marked `QUASI` or `NO_MASK`.

An aggregate score cannot show that either: one source's annotation policy
moved the headline, and the type-level table could not attribute the damage.
The benchmark therefore measured the gap between two annotation policies at
least as much as it measured the detector.

## Decision

**TAB `QUASI` mentions are written to the held-out file as `neutral` ranges,
and the scorer drops an unmatched prediction that overlaps one.** Gold
matching is unchanged: the match search still runs over every prediction, so a
prediction that overlaps a `DIRECT` gold span stays a true positive.
`neutral` is an additive record field (`training/pii_contract.py`); a file
built before it existed still loads with an empty list.

**The held-out suite prints the all-source headline plus one micro/macro block
per source** (gretel-en, gretel-finance, TAB), rendered by
`ShhAi.Eval.Report.render_heldout/3` in the same layout as the AI4Privacy
report.

**Each source is scored only on the types its gold covers**
(`ShhAi.Eval.Scorer.score_by_source/1`), the rule the training dev metric
already uses. The detector still runs over every supported type; each document
is projected onto the gold types of its source before the counts are made. TAB
gold uses `name` (279 spans) and `organization` (3 spans) only, so a `date` or
`location` hit in ECHR prose is not evidence about the detector. Filtering the
scored types by the union of all sources charged TAB for 16 types it never
annotates.

The neutral ranges alone left a TAB precision of 0.037 (shipped) and 0.036
(fine-tuned). Classifying every remaining TAB false positive by type and
detection source shows why:

| Class | Shipped | Fine-tuned |
|---|---:|---:|
| (b) type absent from TAB gold | 2417 (64%) | 3006 (79%) |
| (a) unannotated real text, incl. `NO_MASK` | 1177 (31%) | 527 (14%) |
| (c) boundary miss next to gold or neutral | 176 (5%) | 194 (5%) |
| (d) junk | 9 (0.2%) | 58 (1.5%) |
| **total** | **3779** | **3785** |

Almost all of class (b) is `date` (2309 and 1975) and `location` (107 and
1025); every hit came from NER except two regex hits. Class (b) dominates, so
the per-source type rule is the fix. Classes (a), (c) and (d) stay false
positives: the annotators did not mark that text, or the model got the span or
the type wrong next to a marked one.

`NO_MASK` mentions stay outside the neutral set: the annotators state they are
not personal data, so a detection there remains a false positive.

## Consequences

### Positive

- The TAB score measures detection quality under a stated policy instead of the
  policy itself. A prediction on "Warsaw District Court" is neither required
  nor wrong, and is no longer evidence against the model.
- Per-source blocks make a policy-driven regression visible: a change that only
  moves TAB is distinguishable from one that moves every source.
- The per-source type rule removes the largest remaining artefact: 64%
  (shipped) and 79% (fine-tuned) of TAB false positives were types TAB never
  annotates, so the TAB block now measures the two types it does annotate.

### Negative

- **Earlier held-out scores are not comparable.** Every number quoted before
  this ADR (including ADR-0018's bake-off table and the pre-fix baseline below)
  was computed without neutral ranges and is lower by an unknown amount that
  depends on the model. Only runs against the rebuilt file count.
- A neutral range hides a real distinction: a detector that fires on every
  context-dependent date scores the same as one that fires on none. The
  per-source block bounds the effect (TAB cannot move the other two sources),
  and the gold `DIRECT` spans still measure recall.
- TAB `QUASI` includes codes and quantities as well as names and places, so
  the neutral set is broader than "could be PII"; widening it further stays a
  benchmark change that must be recorded here.
- A per-source type rule hides a real TAB weakness: the detector labels many
  organisations `location`, or splits a name at its space, and those hits now
  count only when they collide with a `name`/`organization` gold span. The
  TAB precision block still moves when those errors hit gold text; the
  classification table above is the record of the hidden remainder.

### Neutral

- The file name and version stay `heldout_v1.jsonl`: the change is additive and
  the builder has no version constant. Rebuilding is mandatory, because a stale
  file silently scores the old policy.

### New baseline (rebuilt file, 6058 neutral ranges in 135 TAB docs)

| Model | Micro P | Micro R | Micro F1 | TAB micro P | TAB micro F1 |
|---|---:|---:|---:|---:|---:|
| shipped `gravitee-io/bert-small-pii-detection` | 0.629 | 0.827 | 0.715 | 0.096 | 0.162 |
| fine-tuned `training/export/pii-ner` | 0.496 | 0.700 | 0.580 | 0.153 | 0.235 |

These numbers include the per-source type rule. The same runs without it gave
0.500/0.624 (shipped) and 0.382/0.494 (fine-tuned) micro P/F1, and 0.037/0.036
TAB precision.

The fine-tuned model is scored against the benchmark as it stands, not as
delivered: the street-address regex and detection-merge fixes are in the same
worktree, and both numbers include them.

Per-source numbers for both models are in
[benchmarks](../benchmarks.md#held-out-benchmark-heldout_v1).
