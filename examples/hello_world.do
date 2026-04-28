* =============================================================================
* datamirror hello-world example
* -----------------------------------------------------------------------------
* Five-minute round trip on Stata's built-in auto.dta:
*   1. Fit a regression on the real data.
*   2. Tag it as a checkpoint and export marginals + coefficients.
*   3. Rebuild a synthetic dataset from the export directory.
*   4. Fit the same regression on the synthetic data and verify the
*      coefficient comes back.
*
* To run this file from the repo root:
*   do examples/hello_world.do
*
* The companion log (examples/hello_world.log) shows what a successful
* run looks like. If your run diverges substantively, open an issue with
* the log attached.
* =============================================================================

clear all
set more off
set seed 20260422

di as result "=============================================================="
di as result "  datamirror hello-world  (Stata auto.dta, 74 obs, one model)"
di as result "=============================================================="

* -----------------------------------------------------------------------------
* 1. Load data and fit the target regression.
* -----------------------------------------------------------------------------
sysuse auto, clear
di as txt _n "{bf:Data:} " _N " cars, " c(k) " variables"

di as txt _n "{bf:Target regression:}"
regress price mpg weight foreign

scalar target_mpg     = _b[mpg]
scalar target_weight  = _b[weight]
scalar target_foreign = _b[foreign]
scalar target_cons    = _b[_cons]
di as txt _n "Target coefficients recorded for mpg, weight, foreign, _cons."

* -----------------------------------------------------------------------------
* 2. Open a datamirror session, checkpoint the regression, extract.
* -----------------------------------------------------------------------------
local outdir "/tmp/datamirror_hello_out"
cap mkdir "`outdir'"

di as txt _n "{bf:datamirror init}"
datamirror init, checkpoint_dir("`outdir'") replace min_cell_size(1)

di as txt _n "{bf:datamirror checkpoint}"
datamirror checkpoint, tag("price_model")

di as txt _n "{bf:datamirror extract}"
datamirror extract

datamirror close

* -----------------------------------------------------------------------------
* 3. Fresh session: rebuild synthetic data from the export directory.
*    In real use this step runs on a different machine with no access
*    to the original data; here we simulate that by clearing first.
* -----------------------------------------------------------------------------
di as txt _n "{bf:datamirror rebuild}  (fresh session, no access to original data)"
clear
datamirror rebuild using "`outdir'", clear seed(12345)

di as txt _n "{bf:Synthetic data:} " _N " rows, " c(k) " variables"

* -----------------------------------------------------------------------------
* 4. Fit the same regression on the synthetic data and compare.
* -----------------------------------------------------------------------------
di as txt _n "{bf:Same regression on synthetic data:}"
regress price mpg weight foreign

scalar synth_mpg     = _b[mpg]
scalar synth_weight  = _b[weight]
scalar synth_foreign = _b[foreign]
scalar synth_cons    = _b[_cons]

scalar se_mpg     = _se[mpg]
scalar se_weight  = _se[weight]
scalar se_foreign = _se[foreign]
scalar se_cons    = _se[_cons]

scalar dse_mpg     = abs(synth_mpg     - target_mpg)     / se_mpg
scalar dse_weight  = abs(synth_weight  - target_weight)  / se_weight
scalar dse_foreign = abs(synth_foreign - target_foreign) / se_foreign
scalar dse_cons    = abs(synth_cons    - target_cons)    / se_cons

di as txt _n "{bf:Coefficient recovery} (Δβ/SE; fidelity target < 3)"
di as txt "{hline 60}"
di as txt "  mpg     target="   %8.3f target_mpg     "  synth=" %8.3f synth_mpg     "  Δβ/SE=" %5.3f dse_mpg
di as txt "  weight  target="   %8.3f target_weight  "  synth=" %8.3f synth_weight  "  Δβ/SE=" %5.3f dse_weight
di as txt "  foreign target="   %8.3f target_foreign "  synth=" %8.3f synth_foreign "  Δβ/SE=" %5.3f dse_foreign
di as txt "  _cons   target="   %8.3f target_cons    "  synth=" %8.3f synth_cons    "  Δβ/SE=" %5.3f dse_cons
di as txt "{hline 60}"

scalar max_dse = max(dse_mpg, dse_weight, dse_foreign, dse_cons)
di as txt "{bf:Max Δβ/SE across all coefficients:} " %5.3f max_dse

if max_dse < 3 {
    di as result _n "✓ Hello-world round trip succeeded (Δβ/SE < 3)."
}
else {
    di as error _n "✗ Hello-world round trip exceeded Δβ/SE < 3 (" %5.3f max_dse ")"
}

di as txt _n "Export artifact left at: `outdir'/"
di as txt "Contents are disclosure-safe: marginals, correlations, checkpoint"
di as txt "coefficients. No individual-level data crosses the boundary."
