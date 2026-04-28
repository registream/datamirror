# Agency requirements checklist

**Date:** 2026-04-24
**Scope:** datamirror v1.0 with default configuration (`DM_MIN_CELL_SIZE = 50`, `DM_QUANTILE_TRIM = 1`, aggregates-only emission).
**Companion:** [COMPLIANCE.md](COMPLIANCE.md) holds the primary-source audit, quoted thresholds, and verified URLs for every rule cited here. Update both documents together when thresholds change.

---

## Legend

- **Met** — datamirror's shipped defaults satisfy the rule without any researcher action.
- **Met (configurable)** — satisfied when the researcher sets a non-default parameter or follows documented per-stratum guidance. Flagged to make the researcher's responsibility explicit.
- **Met (by construction)** — a structural property of the extract bundle rather than a runtime check.
- **Gap** — not performed by v1.0. Handled by researcher post-processing in the interim; flagged as a candidate for an agency-specific compliance profile in future work.
- **Not applicable** — the rule concerns a release category datamirror does not produce.

---

## Summary

Across eight agencies plus the Ricciato (2026) post-handbook residual list, 36 substantive rules reviewed:

| Status | Count |
|---|---|
| Met at defaults | 18 |
| Met (by construction) | 4 |
| Met (configurable) | 9 |
| Gap | 2 |
| Not applicable | 3 |

The two gaps are both within the US Census FSRDC handbook (pseudo-percentile post-processing; 4-significant-figure rounding of continuous statistics). Researchers targeting FSRDC-analogous sites handle these as documented post-processing steps; agency-specific compliance profiles are a natural extension of the bundle architecture (see [STRICT_PROFILES_DESIGN.md](STRICT_PROFILES_DESIGN.md)).

Every rule rated **Met (configurable)** carries a specific action for the researcher, called out in that rule's row.

---

## Statistics Sweden (SCB) / MONA

Primary deployment target. SCB publishes a researcher-responsibility framing rather than numerical output thresholds; the operational caps are the binding constraint.

| Rule | Source | datamirror v1.0 | Status |
|---|---|---|---|
| No microdata downloads permitted | SND 2023 slide deck, p.5 | Bundle emits only aggregates (quantile grids, correlations, regression coefficients); microdata never written | **Met (by construction)** |
| 5 MB per-file download cap | SND 2023 | Largest observed file across all unit tests and four AEA replication packages: `correlations.csv` at 1.65 MB (Banerjee 2015, widest variable set) | **Met** (3× under cap) |
| 50 MB cumulative per seven-day window | SND 2023 | Largest full-paper bundle set 11.1 MB (Banerjee 2015, seven tables). One paper's worth of bundles uses ~22% of the weekly allowance | **Met** |
| Researcher verifies before disclosure | SCB MONA rules and regulations | Every gate state persisted to `metadata.csv`; suppression counts logged | **Met (by construction)** |

---

## Statistics Denmark (DST)

| Rule | Source | datamirror v1.0 | Status |
|---|---|---|---|
| Minimum 3 observations per cell (person-level statistics) | DST 2015 §guidelines | Default `DM_MIN_CELL_SIZE = 50` is 16.7× stricter | **Met** |
| 80% dominance rule (business statistics) | DST 2015 | Not applicable: datamirror emits scalar regression coefficients, not magnitude tables; business-statistics dominance rules do not apply | **Not applicable** |
| Medians and rank statistics permitted if no identification risk | DST 2015 | 101-point quantile grid emitted at pooled N; stratified grid gated at `DM_MIN_CELL_SIZE` | **Met** |
| Researcher responsibility for identification risk | DST 2015 | Suppression counts and resolved gate values persisted to `metadata.csv` for disclosure-officer audit | **Met (by construction)** |

---

## Statistics Norway (SSB)

| Rule | Source | datamirror v1.0 | Status |
|---|---|---|---|
| GDPR data-minimisation framing; no explicit numerical thresholds in public guidelines | SSB 2021 (revised 2025) | datamirror's gates apply regardless of explicit thresholds. Default defensible under data-minimisation since only aggregates are emitted and small cells are suppressed | **Met** |

---

## Eurostat / ESSnet: Brandt-Franconi Data-without-Boundaries

The operative European baseline. All thresholds verified against the 2016 revised DwB guidelines.

| Rule | Source | datamirror v1.0 | Status |
|---|---|---|---|
| Raw maxima and minima of continuous variables classified **Class 3 (unsafe, not released)** | Brandt-Franconi 2016 Table | `DM_QUANTILE_TRIM = 1` default plateaus `q0` at the 1st percentile and `q100` at the 99th, retiring both Class-3 entries | **Met** |
| Percentile data classified Class 3 by default; principles-based exception at large N | Brandt-Franconi 2016 | At MONA N (typically millions), the principles-based argument is direct. 101-point grid interior is the documented safe operating point | **Met** at pooled N; per-stratum see IAB/StatCan rows below |
| Correlation matrices safe with ≥10 observations | Brandt-Franconi 2016 Class 14 | `DM_MIN_CELL_SIZE = 50` default is 5× stricter. Stratified correlations gate at the same threshold | **Met** |
| Regression output safe with ≥10 degrees of freedom | Brandt-Franconi 2016 | Researcher checkpoints only regressions with adequate d.f.; datamirror documents N ≥ 20 per coefficient as a working floor in the paper | **Met (configurable)** |
| Regression not based solely on categorical variables | Brandt-Franconi 2016 | Researcher responsibility; datamirror does not restrict estimator choice but the constraint is documented in the paper §9 and in this repo's PRIVACY.md | **Met (configurable)** |
| Frequency tables rule-of-thumb ≥10 | Brandt-Franconi 2016 | `DM_MIN_CELL_SIZE = 50` default is 5× stricter | **Met** |

---

## UK Office for National Statistics (ONS) — SDAP Handbook v2.0

The baseline for the ONS Secure Research Service and affiliated UK research centres.

| Rule | Source | datamirror v1.0 | Status |
|---|---|---|---|
| Default minimum cell size 10 | SDAP 2024 v2.0 §Frequency tables | Default `DM_MIN_CELL_SIZE = 50` is 5× stricter | **Met** |
| Percentile tables allowed if each percentile has ≥10 underlying observations | SDAP 2024 v2.0 | At MONA N (millions), the 101-point grid passes. Per-stratum the test requires stratum N ≥ 1010 for a 101-point grid or coarser grid at small strata | **Met** at pooled N; researcher raises `min_cell_size` or uses coarser grid per-stratum |
| Top/bottom-coding recommended (not prescribed at specific percentile) | SDAP 2024 v2.0 | `DM_QUANTILE_TRIM = 1` default | **Met** |
| Correlations safe with ρ = ±1 caveat (perfect correlation reveals duplication) | SDAP 2024 v2.0 | Correlation matrices emitted from the overall sample; the ρ = ±1 edge case is not currently detected with a runtime warning, but would be visible to a disclosure officer on inspection | **Met (configurable)** — see open item in COMPLIANCE.md |

---

## US Census Bureau FSRDC — Disclosure Avoidance Methods Handbook v.4

The strictest reviewed agency for continuous-variable outputs. Datamirror's two documented gaps are both here.

| Rule | Source | datamirror v1.0 | Status |
|---|---|---|---|
| Minimum cell size 3 person-level; 10/20/100 for IRS-commingled data | FSRDC Handbook v.4 | Default `DM_MIN_CELL_SIZE = 50` clears person-level; researcher raises to 100 for IRS-commingled | **Met (configurable)** |
| **Rounding of all continuous statistics to 4 significant figures** (including regression coefficients and SEs) | FSRDC Handbook v.4 | v1.0 emits full precision. Researcher post-processes before FSRDC-reviewed release. Candidate for an `fsrdc` compliance profile (see [STRICT_PROFILES_DESIGN.md](STRICT_PROFILES_DESIGN.md)) | **Gap** |
| **True percentiles prohibited**; pseudo-percentile with 11-observation non-overlapping windows required | FSRDC Handbook v.4 §Continuous variables | v1.0 emits a 101-point true-percentile grid. Researcher post-processes to pseudo-percentiles for FSRDC-reviewed release. Candidate for an `fsrdc` compliance profile | **Gap** |
| p% and (n, k) dominance rules on magnitude tables | FSRDC Handbook v.4 | Not applicable: datamirror emits scalar regression coefficients, not magnitude tables | **Not applicable** |
| Concentration ratio rules on binary RHS indicators; disclosure statistics per 0/1 split of every dummy | FSRDC Handbook v.4 | Researcher responsibility; datamirror does not currently enumerate binary-indicator disclosure statistics | **Met (configurable)** |

---

## IAB FDZ (Germany) — Guidelines for the Design of Evaluation Programmes

Strictest published numerical thresholds on percentile granularity.

| Rule | Source | datamirror v1.0 | Status |
|---|---|---|---|
| Minimum 20 observations per cell (categorical) | IAB FDZ guidelines | Default `DM_MIN_CELL_SIZE = 50` is 2.5× stricter | **Met** |
| Hard floor of 20 observations for regression output | IAB FDZ guidelines | Researcher checkpoints only regressions with N ≥ 20; documented in the paper and in PRIVACY.md | **Met (configurable)** |
| Weighted output requires unweighted N ≥ 20 as well | IAB FDZ guidelines | Researcher responsibility; datamirror records the fit-sample N in `checkpoints.csv` for audit | **Met (configurable)** |
| Percentile granularity table: 20 for median, 40 for quartile, 80 for decile, 200 for p5/p95, 400 for p1/p99, **2000 for 1%-granularity** | IAB FDZ guidelines | At MONA N (typically millions) all tiers pass. Per-stratum, the 1%-granularity tier (2000) is above the default `min_cell_size = 50`; researcher raises to 2000 for IAB-reviewed stratum-level 1%-granularity releases, or accepts a coarser stratum grid | **Met** at pooled N; **Met (configurable)** per-stratum |
| Residual-series prohibited | IAB FDZ guidelines | Not applicable: datamirror does not emit residuals | **Not applicable** |

---

## Statistics Canada — DAD Vetting Handbook v1.1

| Rule | Source | datamirror v1.0 | Status |
|---|---|---|---|
| ≥20 records per quartile/quintile/decile | StatCan DAD 2022 | At MONA N, decile-granularity at 20+ per bucket is straightforward. Per-stratum N ≥ 200 required for a decile grid | **Met** at pooled N; **Met (configurable)** per-stratum |
| ≥400 records per percentile | StatCan DAD 2022 | At MONA N, per-percentile cell count far exceeds 400. Per-stratum 1%-granularity requires raising `min_cell_size` to 400 | **Met** at pooled N; **Met (configurable)** per-stratum |
| Correlations safe with data-source-specific caveats | StatCan DAD 2022 | Correlation matrices emitted from the overall sample; small strata suppressed from stratified matrix at `min_cell_size` | **Met** |
| Cell suppression not permitted in standard aggregate products; researcher recomputes with coarser definition | StatCan DAD 2022 | datamirror's suppression is a tool-internal gate with logged counts, not a released-data cell-masking operation. Researcher re-runs with coarser stratification if needed to avoid any suppression | **Met (configurable)** |

---

## Post-handbook residual risks (Ricciato 2026 for the interpretable low-dimensional generator class)

Classical SDC handbooks predate synthetic-data regenerators, so the following risks are not handbook-classified. Ricciato (2026, *JOS* 42:1) names them for tools in datamirror's paradigm; we address each explicitly.

| Risk | datamirror v1.0 | Status |
|---|---|---|
| Rare strata and singleton-like leakage | `DM_MIN_CELL_SIZE` extended to stratified continuous marginals and stratified correlations; small strata skipped entirely rather than emitted at single-observation granularity | **Met** |
| Over-constrained checkpoints on small N (concatenated coefficient vector approaches a low-rank encoding of the data) | Documented convention that total checkpoint-coefficient count should be substantially smaller than stratum N. No runtime budget enforcement; researcher responsibility | **Met (configurable)** |
| Distance-to-closest-record arguments uninformative about membership-inference risk (Yao et al. 2025) | datamirror does not rely on DCR reasoning. Where a formal disclosure-risk statement is required, the appropriate language is membership-inference / attribute-disclosure in the sense of Snoke et al. 2018 | **Met (by construction)** |

---

## What this checklist does NOT cover

- Differential-privacy guarantees. datamirror does not claim DP; where DP is required, compose a DP mechanism on top of the extract-layer summaries.
- Consent-level disclosure rules unique to individual registers (health, tax, ethnically sensitive data). Custodian-specific review remains with the data agreement.
- Implicit-sample review across multiple datamirror runs with overlapping stratifications (FSRDC handbook §implicit samples). Researcher responsibility — datamirror is an enclave extraction tool, not a pre-cleared release pipeline.
- Weak-instrument or concentration-ratio-dependent disclosure checks on IV regressions with binary endogenous variables. Researcher responsibility — datamirror's fit metadata is sufficient for the researcher to perform this check.

---

## How to use this checklist

- **Data custodians** reviewing a datamirror bundle: inspect `metadata.csv` for the resolved gate values (`dm_min_cell_size`, `dm_quantile_trim`, `n_strata_skipped_*`) and confirm each row above against your agency's documented thresholds.
- **Researchers preparing a bundle** for a specific agency: raise `DM_MIN_CELL_SIZE` per the per-stratum guidance in the IAB/StatCan rows if you need 1%-granularity within strata. For FSRDC, perform the two post-processing steps flagged above before submitting for output review.
- **Disclosure officers** comparing against the primary sources: [COMPLIANCE.md](COMPLIANCE.md) has the full URL list and quoted thresholds.
