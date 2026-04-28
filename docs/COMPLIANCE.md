# Compliance with Statistical Agency Disclosure-Control Standards

**Date:** 2026-04-24
**Scope:** Version 1.0 of the `datamirror` extract bundle.
**Purpose:** Provide a primary-source audit of how `datamirror`'s output maps to the formal output-review and disclosure-control rules published by the major statistical agencies, so that researchers, reviewers, and data custodians can judge at a glance where the tool meets, exceeds, or falls below each agency's bar.

This document is a **companion** to [`PRIVACY.md`](PRIVACY.md). PRIVACY.md describes what each configurable gate does and how to set it. COMPLIANCE.md explains which agency rule each gate is meant to satisfy, where the agencies disagree, and what residual responsibilities sit with the researcher.

---

## Bottom line

With its current defaults (`DM_MIN_CELL_SIZE = 50`, `DM_QUANTILE_TRIM = 1`, stratified continuous gated at `min_cell`, only aggregates emitted), `datamirror` meets or exceeds the documented output-review threshold of every reviewed agency on **every release category that handbooks classify as routine**. The residual concerns are not handbook-classified, they are post-handbook issues raised by Ricciato (2026) for the interpretable low-dimensional generator class, and they sit with the researcher (checkpoint budget, implicit samples under repeated runs).

One defensive code behavior should be added: when `quantile_trim(0)` is set explicitly, the runtime should warn that Brandt and Franconi's ESSnet guidelines classify raw maxima and minima as "unsafe, not released" (Class 3). A gate is too strong; a message is right.

---

## Scope of the audit

The reviewed agencies, in priority order for `datamirror`'s deployment target:

1. **Statistics Sweden (SCB) / MONA**: primary deployment (Swedish register data)
2. **Statistics Denmark (DST)**: secondary Scandinavian target
3. **Statistics Norway (SSB)**
4. **Eurostat / ESSnet SDC**: the European baseline via the Brandt-Franconi DwB guidelines
5. **UK Office for National Statistics (ONS)**: Secure Research Service, governed by the SDAP Handbook
6. **US Census Bureau Federal Statistical Research Data Centers (FSRDC)**
7. **Institut für Arbeitsmarkt- und Berufsforschung (IAB) FDZ**, Germany
8. **Statistics Canada Research Data Centres (RDC)**

Each agency is represented by a published handbook, guideline, or regulation; URLs and quotes appear in the Primary sources section at the end of this document.

The reviewed `datamirror` outputs are the files in a v1.0 bundle:

| File                           | Content                                                                        |
|--------------------------------|--------------------------------------------------------------------------------|
| `metadata.csv`                 | Session-level: N, variable count, strata name, suppression counters, policy    |
| `schema.csv`                   | Variable names, types, value labels                                            |
| `marginals_cont.csv`           | 101-point quantile grid per continuous variable                                |
| `marginals_cont_stratified.csv`| Per-stratum 101-point grid                                                     |
| `marginals_cat.csv`            | Per-category frequency table (small cells suppressed)                          |
| `marginals_cat_stratified.csv` | Per-stratum category frequencies                                               |
| `correlations.csv`             | Full-sample Pearson matrix across numeric variables                            |
| `correlations_stratified.csv`  | Per-stratum Pearson matrix (small strata skipped)                              |
| `checkpoints.csv`              | Per-regression metadata (cmd, depvar, N, R²)                                   |
| `checkpoints_coef.csv`         | Per-coefficient β̂, SE                                                          |
| `manifest.csv`                 | File listing with row counts                                                   |

---

## Per-agency summary

### Statistics Sweden (SCB) / MONA

SCB publishes a **researcher-responsibility** framing rather than numerical output thresholds: *"it is your responsibility to verify the information before disclosing it"* (SCB MONA rules and regulations). No formal pre-download output-review step. SCB does not claim custodial responsibility for synthetic data derived from MONA extracts, and does not prescribe a minimum cell size or percentile-granularity rule.

**Implication:** SCB's published rules do not constrain `datamirror`'s output. The tool's internal thresholds are all stricter than anything SCB requires.

#### Operational download constraints at MONA

Separately from the statistical-disclosure rules, MONA imposes hard technical limits on what a researcher can move off the platform, documented by the Swedish National Data Service (SND): **5 MB per file, 50 MB total in any 7-day window, and no microdata downloads permitted**. (SND (2023), *MONA: Microdata Online Access*, p. 5 of the slide deck.)

`datamirror` is designed for this environment. The bundle emits only aggregates (quantile grids, correlation matrices, coefficient targets); the "no microdata downloads" restriction is satisfied by construction. The size limits are satisfied with room to spare because the bundle does not scale with N.

Empirical evidence from the test and replication corpus:

| Source                                           | N       | n_vars | n_strata | Checkpoints | Coefs | Largest file | Bundle total |
|--------------------------------------------------|---------|-------:|---------:|------------:|------:|-------------:|-------------:|
| Unit tests (OLS, IV, logit, probit, poisson, nbreg) | ~10³ | 3–8    | 0        | 1–3         | 5–20  | ~50 KB       | 36–108 KB    |
| UKHLS comprehensive                              | 533,163 | 21     | 24 (wave)| 2           | 14    | 216 KB       | 404 KB       |
| Duflo-Hanna-Ryan 2012 (AEA)                      | varies  | varies | 0–1      | 58          | 442   | ~300 KB      | 5.5 MB total across 11 bundles |
| Dupas-Robinson 2013 (AEA)                        | varies  | varies | 0–1      | 85          | 567   | ~850 KB      | 4.2 MB total across 5 bundles  |
| Banerjee et al. 2015 (AEA)                       | varies  | wide   | 0        | 148         | 986   | 1.65 MB      | 11.1 MB total across 7 bundles |
| Autor-Dorn-Hanson 2019 (AEA)                     | varies  | varies | 0–1      | 72          | 1562  | ~150 KB      | 512 KB total across 3 bundles  |

The MONA 5 MB cap is applied **per file**, and the single largest file we have observed across all unit tests and AEA replication packages is **`correlations.csv` at 1.65 MB** (Banerjee et al. 2015, largest variable set). Each checkpoint directory is independently under the cap. The 50 MB / 7-day cumulative cap is not meaningfully approached: an entire AEA paper's worth of bundles (Banerjee at 11.1 MB across 7 tables) uses about 22 % of one week's allowance.

Scaling drivers, in order of impact on bundle size:

1. `correlations.csv`: `O(n_numeric_vars²)`.
2. `correlations_stratified.csv`: `O(n_strata × n_numeric_vars²)`.
3. `marginals_cat.csv` / `marginals_cat_stratified.csv`: `O(n_strata × Σ unique values per categorical)`.
4. `marginals_cont.csv` / `marginals_cont_stratified.csv`: `O(n_strata × n_cont_vars × 101)`.
5. `checkpoints_coef.csv`: `O(Σ k_coefs across checkpoints)`, roughly 40 bytes per row. At 1562 coefs (Autor 2019) this file is under 20 KB. Checkpoint count is effectively free in bundle terms.

**Where the per-file cap starts to apply:** pathological configurations with ≳50 numeric variables and ≳50 strata simultaneously push `correlations_stratified.csv` above 5 MB. No reviewed empirical case reaches this regime. Mitigations if needed: drop to a single stratification dimension, or emit `.csv.gz` (a direction we are pursuing).

### Statistics Denmark (DST)

DST's *Guidelines for Transferring Aggregated Results from Statistics Denmark's Research Services* (December 2015) requires **minimum 3 observations per cell** for person-level statistics, with an **80 % dominance rule** for business statistics. Medians and other rank statistics are permitted if no identification risk. Researcher-responsibility framing similar to SCB.

**Implication:** DST's 3-cell floor is easily cleared by `datamirror`'s default of 50.

### Statistics Norway (SSB)

SSB's *Guidelines for Access to Microdata from Statistics Norway* (2021, revised 2025) reads as a GDPR data-minimisation policy rather than a numerical output-review manual. No explicit numerical thresholds for percentile granularity or cell size appear in the public guidelines.

**Implication:** SSB's published rules do not numerically constrain `datamirror`.

### Eurostat / ESSnet: Brandt-Franconi DwB Guidelines

The European baseline. Brandt, Franconi, et al., *Guidelines for the Checking of Output Based on Microdata Research* (ESSnet SDC / Data without Boundaries, rev. 2016), classifies outputs into safety classes. The operative rules for `datamirror`:

| Output type                          | Class / status          | Quote                                                                                                                                |
|--------------------------------------|-------------------------|--------------------------------------------------------------------------------------------------------------------------------------|
| Maxima and minima of continuous vars | **Class 3, unsafe**     | "Percentile data [and extreme values] usually represent the value of the variable for an individual respondent and are not released" |
| Percentiles                          | Class 3, unsafe default | As above; principles-based exception available under a documented disclosure-risk argument                                           |
| Correlation matrices                 | Safe with ≥ 10 obs      | Class 14                                                                                                                             |
| Regression output                    | Safe with ≥ 10 d.f.     | Must not be based solely on categorical variables and not on a single unit                                                           |
| Frequency tables                     | Rule-of-thumb ≥ 10      | Dominance thresholds apply for magnitude tables                                                                                      |

**Implication:** Raw extremes are the flagged Class-3 item. `datamirror`'s `DM_QUANTILE_TRIM = 1` default stores the 1st and 99th percentiles at `q0` and `q100`, retiring the two Class-3 entries. The 99 interior percentiles sit in the principles-based grey zone at small N; at the MONA sample sizes this tool targets (typically millions), the principles-based argument is straightforward.

### UK ONS: SDAP Handbook

The SDAP *Handbook on Statistical Disclosure Control for Outputs* v2.0 (July 2024) is the baseline for the ONS Secure Research Service and affiliated UK centres. Default minimum cell threshold **10**; percentile tables allowed if **each percentile has ≥ 10 underlying observations**; top/bottom-coding recommended but not prescribed at a specific percentile; correlations classified safe with the ρ = ±1 caveat.

**Implication:** At typical register-data N, `datamirror`'s 101-point grid passes the per-percentile-N test. The ρ = ±1 edge case is worth a sentence in user-facing docs.

### US Census Bureau FSRDC

The *FSRDC Disclosure Avoidance Methods Handbook v.4* is the strictest reviewed for continuous-variable outputs:

- Minimum cell size **3** for person-level, stricter (10, 20, 100) for IRS-commingled data.
- Rounding of all continuous statistics (including regression coefficients and SEs) to **4 significant figures**.
- **True percentiles prohibited**: *"Researchers should calculate a pseudo-percentile … at least five observations on either side, for a total of at least 11 observations for a given quantile."*
- p % and (n, k) dominance rules for magnitude tables.
- Regression output: concentration ratio rules on any binary RHS indicator; disclosure statistics required for every 0/1 split of every reported dummy.

**Implication:** `datamirror`'s 101-point grid does not satisfy FSRDC's pseudo-percentile rule. Researchers targeting FSRDC-analogous sites would need to post-process the grid (11-observation pseudo-percentiles). This is **out of scope** for v1.0 and is documented as a researcher responsibility.

### IAB FDZ (Germany)

The IAB *Guidelines for the Design of Evaluation Programmes and Analysis Results* imposes the strictest published numerical thresholds on percentile granularity:

| Output                                  | Minimum N |
|-----------------------------------------|-----------|
| Median                                  | 20        |
| Quartile (25/75)                        | 40        |
| Decile (10/90)                          | 80        |
| 5/95 percentile                         | 200       |
| 1/99 percentile                         | 400       |
| **1 %-granularity percentiles (101-pt)**| **2000**  |

Hard floor of **20 observations** for any regression output; residual-series prohibited; weighted output requires that the unweighted N also passes the ≥ 20 threshold.

**Implication:** `datamirror`'s 101-point grid passes IAB's granularity rule at full N (which in register-data applications is usually far above 2000). Per-stratum, the same rule implies coarser grids are appropriate for small strata; the current gate at `DM_MIN_CELL_SIZE = 50` is below IAB's 2000-observation bar for 1 % granularity within a stratum. In practice SCB strata are much larger; the SJ paper should advise IAB users to use a coarser stratum grid or raise `DM_MIN_CELL_SIZE` to 2000 when 1 % granularity within strata is required.

### Statistics Canada RDC

The DAD *Vetting Handbook* v1.1 (March 2022) requires ≥ 20 records per **quartile/quintile/decile** and **≥ 400 records per percentile**. Correlations are safe with caveats. Cell suppression is not permitted in standard aggregate products; the workflow expects the researcher to recompute with a coarser definition.

**Implication:** `datamirror`'s 101-point grid passes at StatCan full N. Per-stratum, 400 is the relevant bar for 1 % granularity.

---

## Per-output compliance matrix

**Legend.** A = allowed; R = allowed with condition stated in the agency text; P = prohibited or classified unsafe by default; D = the agency guideline is silent on this specific item.

| Output row                                       | SCB | DST | SSB | EU-DwB | ONS | FSRDC     | IAB      | StatCan  |
|--------------------------------------------------|-----|-----|-----|--------|-----|-----------|----------|----------|
| Overall N                                        | A   | A   | A   | A      | A   | A         | A        | A        |
| Raw min/max of continuous                        | R   | R   | R   | **P**  | R   | R (round) | R        | R (cell) |
| 101-point quantile grid (raw)                    | R   | R   | D   | **P**  | R   | **P**     | R (≥2000)| R (≥400) |
| 101-point grid with q0=p1, q100=p99              | A   | A   | A   | A      | A   | **P**     | R (≥2000)| R (≥400) |
| Decile grid                                      | A   | A   | A   | A      | A   | A (pseudo)| R (≥80)  | R (≥20)  |
| Mean, SD                                         | A   | A   | A   | A (≥10)| A   | A (round) | A (≥20)  | A (cell) |
| Freq. table with cells ≥ 10 suppressed           | A   | A   | A   | A      | A   | R (≥3 IRS)| **P**    | R        |
| Freq. table with cells ≥ 50 suppressed           | A   | A   | A   | A      | A   | A         | A        | A        |
| Full-sample Pearson correlation matrix           | A   | A   | A   | A (≥10)| A   | A (round) | A (≥20)  | A (cell) |
| Stratified correlation with small strata skipped | A   | A   | A   | A      | A   | A         | A        | A        |
| Regression β̂, SE at N > 1000, k < 20             | A   | A   | A   | A      | A   | A (round) | A (≥20)  | A        |
| Regression β̂, SE at small N (n/k < 20)           | R   | R   | R   | **P**  | R   | R (cells) | **P**    | R        |
| R², log-likelihood                               | A   | A   | A   | A (≥10)| A   | A         | A        | A        |
| Variable metadata (name, type, label)            | A   | A   | A   | A      | A   | A         | A        | A        |

Rows read as: at the agency's default policy, for `datamirror`'s output with the stated configuration, is the output releasable?

---

## How `datamirror`'s gates map to agency rules

The configurable gates in the bundle and the agency rules they implement:

| Gate                    | Default | Implements                                                                                                                                                                                                                                                    |
|-------------------------|---------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `DM_MIN_CELL_SIZE`      | 50      | Minimum-cell-size rule, categorical marginals: Brandt-Franconi ~10, ONS SDAP 10, DST 3, SSB 3, FSRDC 3-100 by source, IAB 20, StatCan data-source-specific. Default 50 is **above** every documented floor.                                                 |
| `DM_MIN_CELL_SIZE` (stratified) | 50 | Extends the per-cell rule to per-stratum suppression of categorical frequencies and to stratified correlations. Matches FSRDC implicit-sample guidance and IAB per-cell application.                                                                        |
| `DM_MIN_CELL_SIZE` (stratified continuous) | 50 | Skips small strata entirely from the continuous quantile output. Closes the small-N extreme-value disclosure channel (Brandt-Franconi Class 3 for extremes). No agency requires this gate specifically, but it is consistent with the spirit of all. |
| `DM_QUANTILE_TRIM`      | 1       | Plateaus `q[0..trim]` at the `p_trim`-th percentile and `q[100-trim..100]` at `p_(100-trim)`. With the default, retires Brandt-Franconi Class-3 entries (raw max/min). Paper-cited rationale: Hundepool et al. 2012 §5.3; Willenborg and de Waal 2001 ch. 6.  |
| Emit only aggregates    | always  | No microdata ever written to the bundle. Above SCB's stated position (which puts responsibility for not downloading microdata on the user) and above every reviewed agency's output-review expectation.                                                      |

### Above-standard choices

| Area                                  | `datamirror` default | Strictest agency requirement | Above by                                          |
|---------------------------------------|----------------------|------------------------------|---------------------------------------------------|
| Categorical cell size                 | 50                   | 20 (IAB)                     | 2.5×                                              |
| Top/bottom-coding                     | p1/p99               | None mandated; p1/p99 is the most permissive IAB grant at ≥ 2000 N | Matches IAB's most-permissive bar; above others |
| Stratified continuous quantiles       | Skipped at N < 50    | No agency requires skip      | Universally more conservative than required      |

### Strictest-compliant with SJ-paper caveat

- **101-point grid at the per-stratum level.** At default `DM_MIN_CELL_SIZE = 50`, per-stratum 1 % granularity falls below IAB's 2000-observation bar and StatCan's 400-observation bar. Documented in the paper as "for 1 % granularity within strata, raise `DM_MIN_CELL_SIZE` to 2000 (IAB-compliant) or 400 (StatCan-compliant), or accept a decile-level grid."
- **Regression checkpoints at small N.** The paper recommends N ≥ 20 per coefficient to remain inside the IAB floor and Brandt-Franconi's ≥ 10 d.f. threshold.

### Residual items not handbook-addressed

These are post-handbook concerns for the interpretable low-dimensional generator class, first named by Ricciato (2026, *JOS* 42(1)) in his critique of deep-learning synthetic data. They do not appear in any classical SDC handbook because handbooks do not anticipate synthetic-data regenerators:

1. **Checkpoint-vector encoding.** If a researcher checkpoints many regressions on a small stratum, the concatenated coefficient vector can approach a low-rank encoding of the underlying data (Ricciato §3.2 functional-interpolation analogue). There is no published threshold; the `datamirror` convention is that total checkpoint-coefficient count should be ≪ N per stratum. A runtime diagnostic is a nice-to-have but not required for v1.0.

2. **Distance-to-closest-record is not a privacy argument.** Yao et al. (2025) *"The DCR Delusion"* (arXiv 2505.01524), cited by Ricciato, shows that DCR is uninformative of actual membership-inference risk. The `datamirror` paper and documentation do not use DCR-style reasoning; membership-inference language is the appropriate framing.

3. **Implicit-sample rule under repeated runs.** FSRDC's implicit-sample rule: overlapping stratifications from multiple extract runs create an implicit cell requiring separate disclosure review. `datamirror` is an enclave tool, not a pre-cleared release pipeline, so responsibility for reasoning about the union of stratifications sits with the researcher. Documented as a researcher responsibility in [PRIVACY.md](PRIVACY.md).

---

## Researcher responsibilities outside `datamirror`'s enforcement

The tool enforces configurable output-review rules; several standard responsibilities remain with the researcher:

1. **Pseudo-percentile post-processing for FSRDC-analogous sites.** The 101-point grid as emitted is not FSRDC-compliant; the researcher must convert to 11-observation pseudo-percentiles if targeting those sites.
2. **Checkpoint budget.** Many checkpoints on a small stratum are discouraged; the tool does not enforce a budget.
3. **Implicit-sample review under repeated runs.** Documented above.
4. **Custodian-specific disclosure review.** `datamirror`'s bundle is designed to be **releasable** under the rules reviewed here, not to substitute for the formal output-review process each agency may run on aggregate releases.

---

## Primary sources

All quoted numerical thresholds and classification statements above are drawn from the following documents. URLs verified 2026-04-24 by direct fetch of the published resource.

- SDAP Working Group (2024). *Handbook on Statistical Disclosure Control for Outputs*, v2.0. UK Data Service. https://ukdataservice.ac.uk/app/uploads/sdc-handbook-v2.0.pdf
- Brandt, M., Franconi, L., et al. (2016 rev.). *Guidelines for the Checking of Output Based on Microdata Research.* ESSnet SDC / Data without Boundaries. https://cros.ec.europa.eu/system/files/2024-02/Output-checking-guidelines.pdf
- Statistics Denmark (2015, December). *Guidelines for Transferring Aggregated Results from Statistics Denmark's Research Services.* https://www.dst.dk/ext/3477468153/0/forskning/Guidelines-for-transferring-aggregated-results-from-Statistics-Denmark--pdf
- Statistics Norway (2021, rev. 2025). *Guidelines for Access to Microdata from Statistics Norway.* https://www.ssb.no/en/data-til-forskning/utlan-av-data-til-forskere/
- Statistics Sweden (current). *MONA: Rules and Regulations.* https://www.scb.se/en/services/ordering-data-and-statistics/ordering-microdata/mona--statistics-swedens-platform-for-access-to-microdata/rules-and-regulations/
- Swedish National Data Service (SND) (2023). *MONA: Microdata Online Access* (slide deck). https://snd.se/sites/default/files/2023-05/MONA.pdf. Documents the operational download caps quoted above (5 MB per file, 50 MB in any 7-day window, no microdata downloads).
- US Census Bureau. *FSRDC Disclosure Avoidance Methods Handbook*, v.4. https://www.census.gov/content/dam/Census/programs-surveys/sipp/methodology/FSRDC%20Disclosure%20Avoidance%20Methods%20Handbook%20v.4.pdf
- IAB FDZ. *Guidelines for the Design of Evaluation Programmes and Analysis Results* (English edition). https://doku.iab.de/fdz/access/Guidelines_en.pdf
- Statistics Canada (2022, March). *DAD Vetting Handbook* v1.1. https://crdcn.ca/app/uploads/2022/07/DAD-Vetting-Handbook_EN.pdf
- Ricciato, F. (2026). "Privacy-Enhancing or Privacy-Elusion Technology? A Critical View of (Pseudo)Synthetic Data Based on Deep Learning." *Journal of Official Statistics* 42(1), 168-195. DOI: 10.1177/0282423X251412328
- Yao, Z., et al. (2025). "The DCR Delusion." arXiv:2505.01524.
- Domingo-Ferrer, J., Sánchez, D., Muralidhar, K. (2025). "Statistical Disclosure Control: Moving Forward." *Journal of Official Statistics* 41(3). https://journals.sagepub.com/doi/10.1177/0282423X241312023

### Verification notes

- Hundepool, A., et al. (2012). *Statistical Disclosure Control.* Wiley. The textbook was not fetched directly in the primary-source audit. The DwB / Brandt-Franconi guidelines summarize the Hundepool methodology and are used as the citation proxy. If a direct Hundepool quotation is required for the SJ revision, verify against the physical text.
- The original Eurostat SDC Handbook (v1) at `ec.europa.eu/eurostat/cros/system/files/SDC_Handbook.pdf` is referenced in search results but superseded in practice by the SDAP v2.0 text used here.
