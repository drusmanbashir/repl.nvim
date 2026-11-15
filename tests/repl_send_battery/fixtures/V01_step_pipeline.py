# %%

"""Step one report through the deployed parser, stage by stage.ca

REPL: send the cells in order. The 10-row cell runs `ReportClassifier` against gold; pick a
row with ROW, then each later cell is one stage of `ReportClassifier.classify_text` with its
intermediates as named variables (sections, mentions, gate verdicts, recommendations, every
rule Effect). The S3d cell applies ONE registry rule per run; re-send it to advance.

Debugger: launch this file and set breakpoints in the 10-row loop, in `apply_rule` (step
into `rule.fn` to land in a rule body), or in any stage cell. The stage cells copy the
orchestration bodies of classify_text / classify_clinical / classify_findings and call the
production functions; the last cell flags any drift from `ReportClassifier`. #AI
"""

import pandas as pd

from report_parser.axis_state import AxisState, Effect
from report_parser.findings.mentions import MentionView
from report_parser.findings.recommendation import RecoView, recommendation_yields
from report_parser.findings.registry import Rule, rule_args

MENTION_COLS = ("cls", "section", "kind", "assertion", "hedge", "object_class", "llm_affirmed", "phrase", "pattern")
RECO_COLS = ("section", "action", "verb", "status", "object_class", "object_assertion", "link", "phrase", "object_phrase")


def fired(labels) -> list[str]:
    """Labels set True, in insertion order. #AI"""
    on = [k for k, v in labels.items() if v]
    return on


def mentions_frame(mentions: MentionView) -> pd.DataFrame:
    """One display row per Mention. #AI"""
    frame = pd.DataFrame([{c: getattr(m, c) for c in MENTION_COLS} for m in mentions], columns=list(MENTION_COLS))
    return frame


def recos_frame(recos: RecoView) -> pd.DataFrame:
    """One display row per Recommendation, plus whether it passes the C4 gate. #AI"""
    rows = [{**{c: getattr(r, c) for c in RECO_COLS}, "yields": recommendation_yields(r)} for r in recos]
    frame = pd.DataFrame(rows, columns=[*RECO_COLS, "yields"])
    return frame


def apply_rule(state: AxisState, rule: Rule, ctx: dict) -> tuple[Effect, bool]:
    """One registry step exactly as classify_findings runs it; prints the label change. #AI"""
    before = fired(state.labels)
    effect = rule.fn(*rule_args(rule, ctx, state.labels, state.spans))
    changed = state.apply(effect, f"rule:{rule.id}")
    print(f"{rule.id:36} changed={changed!s:5} {before} -> {fired(state.labels)}")
    if changed:
        print(f"{'':36} {effect}")
    stepped = (effect, changed)
    return stepped


if __name__ == "__main__":
# %%
# SECTION:--- SETUP --- <CR>
    from report_parser.axis_state import NO_EFFECT
    from report_parser.classifier import ReportClassifier
    from report_parser.clinical import rules as clin_rules
    from report_parser.clinical.render import _has_clinical_text, build_clinical_status, lead_evidence_label
    from report_parser.clinical.resolve import CLINICAL_RULES
    from report_parser.clinical.sensor import extract
    from report_parser.config import load_config
    from report_parser.findings.axis import _label_bucket_hits, score_imaging_axis
    from report_parser.findings.mentions import HP_BUCKETS, sense_mentions
    from report_parser.findings.recommendation import sense_recommendations
    from report_parser.findings.registry import RULES
    from report_parser.findings.render import build_imaging_status
    from report_parser.findings.resolve import (
        DEFAULT_EFFECT,
        I_ACTIVE,
        _high_precision_effect,
        _result,
        _score_sites,
        imaging_negation_prefixes,
    )
    from report_parser.findings.rules_clear import _interim_has_negative_findings
    from report_parser.fusion import fuse
    from report_parser.preprocess import preprocess_report
    from report_parser.qa.scoring import fam, img_norm
    from report_parser.redaction import redact_text
    from report_parser.repl.bootstrap import load_training_subset

    pd.set_option("display.width", 250)
    pd.set_option("display.max_colwidth", 80)

    # False: no Ollama calls, every gated I_CA hit becomes a regex-only yes (labels can differ)
    LLM_GATE = True
    cfg = load_config()
    cfg["findings_helpers"]["i_ca_attribution"]["enabled"] = LLM_GATE
    clf = ReportClassifier(cfg=cfg)
    subset = load_training_subset(n=10, seed=0)
    print(subset[["row_key", "gold_imaging", "gold_clinical"]].to_string())

# %%
# SECTION:--- 10-row subset: full pipeline vs gold ---
    outs = []
    for _, r in subset.iterrows():
        report, clinical, referral = r["report"], r["clinical"], r["referral"]
        out = clf.classify_text(report, clinical, referral)
        outs.append(out)
    summary = subset[["row_key", "gold_imaging", "gold_clinical"]].assign(
        pred_imaging=[o["imaging_status"] for o in outs],
        imaging_from=[o["imaging_provenance"] for o in outs],
        pred_clinical=[o["clinical_status"] for o in outs],
    )
    summary["img_ok"] = summary["gold_imaging"].map(img_norm) == summary["pred_imaging"].map(img_norm)
    summary["clin_ok"] = summary["gold_clinical"].map(fam) == summary["pred_clinical"].map(fam)
    print(summary.to_string())

# %%
