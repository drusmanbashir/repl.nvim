"""Stand-in for regex1's `report_parser` package -- REPL send battery case V01 only.

The V01 fixture is a byte-for-byte copy of the first cells of
regex1/report_parser/repl/step_pipeline.py, so the payload can be judged line
by line against the real source. Its imports resolve here instead of to the
real parser: every imported name exists, with just enough behaviour for the
fixture's cells to run (no data files, no LLM calls). Not product code.
"""
import importlib.abc
import importlib.machinery
import sys
import types


def _training_subset(n=10, seed=0):
    import pandas as pd

    return pd.DataFrame(
        {
            "row_key": ["row%d" % i for i in range(n)],
            "gold_imaging": ["I_no_CA"] * n,
            "gold_clinical": ["C_none"] * n,
            "report": ["no evidence of malignancy"] * n,
            "clinical": ["routine follow-up"] * n,
            "referral": ["surveillance"] * n,
        }
    )


class ReportClassifier:
    def __init__(self, cfg):
        self.cfg = cfg

    def classify_text(self, report, clinical, referral):
        return {"imaging_status": "I_no_CA", "imaging_provenance": "stub", "clinical_status": "C_none"}


def _identity(value, *args, **kwargs):
    return value


def _config():
    return {"findings_helpers": {"i_ca_attribution": {"enabled": False}}, "redaction_strip": []}


_NAMES = {
    "report_parser.axis_state": {"AxisState": object, "Effect": object, "NO_EFFECT": "NO_EFFECT"},
    "report_parser.classifier": {"ReportClassifier": ReportClassifier},
    "report_parser.clinical": {},
    "report_parser.clinical.rules": {},
    "report_parser.clinical.render": {
        "_has_clinical_text": _identity, "build_clinical_status": _identity, "lead_evidence_label": _identity,
    },
    "report_parser.clinical.resolve": {"CLINICAL_RULES": ()},
    "report_parser.clinical.sensor": {"extract": _identity},
    "report_parser.config": {"load_config": _config},
    "report_parser.findings": {},
    "report_parser.findings.axis": {"_label_bucket_hits": _identity, "score_imaging_axis": _identity},
    "report_parser.findings.mentions": {"MentionView": list, "HP_BUCKETS": (), "sense_mentions": _identity},
    "report_parser.findings.recommendation": {
        "RecoView": list, "recommendation_yields": _identity, "sense_recommendations": _identity,
    },
    "report_parser.findings.registry": {"Rule": object, "rule_args": _identity, "RULES": ()},
    "report_parser.findings.render": {"build_imaging_status": _identity},
    "report_parser.findings.resolve": {
        "DEFAULT_EFFECT": None, "I_ACTIVE": (), "_high_precision_effect": _identity, "_result": _identity,
        "_score_sites": _identity, "imaging_negation_prefixes": (),
    },
    "report_parser.findings.rules_clear": {"_interim_has_negative_findings": _identity},
    "report_parser.fusion": {"fuse": _identity},
    "report_parser.preprocess": {"preprocess_report": _identity},
    "report_parser.qa": {},
    "report_parser.qa.scoring": {"fam": _identity, "img_norm": _identity},
    "report_parser.redaction": {"redact_text": _identity},
    "report_parser.repl": {},
    "report_parser.repl.bootstrap": {"load_training_subset": _training_subset},
}


class _StubFinder(importlib.abc.MetaPathFinder, importlib.abc.Loader):
    def find_spec(self, fullname, path, target=None):
        if fullname in _NAMES:
            return importlib.machinery.ModuleSpec(fullname, self, is_package=True)
        return None

    def create_module(self, spec):
        module = types.ModuleType(spec.name)
        module.__path__ = []
        module.__dict__.update(_NAMES[spec.name])
        return module

    def exec_module(self, module):
        return None


sys.meta_path.insert(0, _StubFinder())
