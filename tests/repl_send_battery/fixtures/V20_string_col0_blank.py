# repl_send_battery V20: body-only cell holding a triple-quoted string whose text sits at column 0 and contains a blank line.
# Copied verbatim from ~/code/regex1/p2/base.py:173-188.
# %%
# SECTION:-------------------- AI attempt - fails--------------------------------------------------------------------------------------

    token_guide = """
imaging_status tokens (mutually exclusive, ranked by clinical severity):
- I_mets: metastatic disease (definite spread to distant organs)
- I_CA: primary cancer or local tumor progression (not metastatic)
- I_susp: suspicious findings requiring follow-up (cancer not confirmed)
- I_indeterminate: unclear findings, cannot rule in/out cancer
- I_no_CA: no evidence of cancer
- I_stable_from_before: unchanged findings from prior imaging (known stable disease)

Parser uses regex + NLP to match report text → tokens, with Ollama LLM gate for I_CA attribution.
matched_spans shows what text triggered each token.
"""

# %%
