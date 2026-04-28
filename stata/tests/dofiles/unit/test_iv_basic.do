* Test: IV regression checkpoint (unit test)
* Purpose: Test ivregress 2sls checkpoint and Layer 4 adjustment
* Method: Δβ/SE < 3 (inferential fidelity; synthetic β̂ within 3 SE of target).

clear all
set more off
set seed 20250121
adopath ++ "stata/src"
adopath ++ "../registream/stata/src"

di as txt _n "════════════════════════════════════════════════════════════"
di as txt "TEST: IV REGRESSION (ivregress 2sls)"
di as txt "════════════════════════════════════════════════════════════"

* Generate synthetic data with IV structure
set obs 500

* Instrument (z) - exogenous
gen z = rnormal()

* Endogenous variable (educ) - correlated with instrument
gen educ = 0.7*z + rnormal()

* Outcome (wage) - depends on educ
gen u = rnormal()
gen wage = 3 + 2*educ + u

di _n "Data generated: N=500, true beta_educ = 2.0"

* Show correlations
di _n "Correlations:"
corr wage educ z u

* Run IV regression (ORIGINAL)
di _n "=== ORIGINAL IV MODEL ==="
ivregress 2sls wage (educ = z), robust

* Store original coefficients
local b_educ_orig = _b[educ]
local b_cons_orig = _b[_cons]

* Show what's in e(b)
di _n "Coefficient matrix e(b):"
matrix list e(b)

di _n "Variable lists:"
di "  instd (endogenous): `e(instd)'"
di "  insts (instruments): `e(insts)'"
di "  exogr (exogenous): `e(exogr)'"

di _n "Colnames in e(b):"
local cn : colnames e(b)
di "  `cn'"

* First stage diagnostics
di _n "=== FIRST STAGE DIAGNOSTICS ==="
estat firststage
matrix fs = r(singleresults)
local fstat = fs[1,1]
di _n "First-stage F-statistic: " %6.2f `fstat'
if `fstat' > 10 {
    di as result "  ✓ Strong instruments (F > 10)"
}
else {
    di as error "  ✗ Weak instruments (F < 10)"
}

* Now test checkpoint workflow
local outdir "stata/tests/output/iv_basic"
cap rm -rf "`outdir'"

di _n "=== TESTING CHECKPOINT WORKFLOW ==="

* Initialize
datamirror init, checkpoint_dir("`outdir'") replace

* Checkpoint the IV model
ivregress 2sls wage (educ = z), robust
datamirror checkpoint, tag("iv_model")

* Extract
datamirror extract, replace

* Check coefficient file
di _n "Checking checkpoint files..."
cap confirm file "`outdir'/checkpoints_coef.csv"
if _rc == 0 {
    di as result "  ✓ checkpoints_coef.csv exists"
    import delimited "`outdir'/checkpoints_coef.csv", clear
    keep if cp_num == 1
    list
}
else {
    di as error "  ✗ checkpoints_coef.csv not found"
    exit 1
}

* Close session
datamirror close

* Rebuild (NOW with Layer 4!)
di _n "=== REBUILDING SYNTHETIC DATA ==="
datamirror rebuild using "`outdir'", clear seed(99999)

di _n "Synthetic data structure:"
describe, short

* Run IV on synthetic (with Layer 4)
di _n "=== SYNTHETIC IV MODEL (WITH LAYER 4) ==="
ivregress 2sls wage (educ = z), robust

* Get synthetic coefficients and SEs
local b_educ_synth = _b[educ]
local b_cons_synth = _b[_cons]
local se_educ_synth = _se[educ]
local se_cons_synth = _se[_cons]

local delta_educ = abs(`b_educ_synth' - `b_educ_orig')
local delta_cons = abs(`b_cons_synth' - `b_cons_orig')

local dse_educ = `delta_educ' / `se_educ_synth'
local dse_cons = `delta_cons' / `se_cons_synth'

di _n "Coefficient comparison:"
di "  Variable      Original    Synthetic       Δ      Δ/SE"
di "  {hline 60}"
di "  educ       " %10.4f `b_educ_orig' "  " %10.4f `b_educ_synth' "  " %8.4f `delta_educ' "  " %6.3f `dse_educ'
di "  _cons      " %10.4f `b_cons_orig' "  " %10.4f `b_cons_synth' "  " %8.4f `delta_cons' "  " %6.3f `dse_cons'

local max_dse_all = max(`dse_educ', `dse_cons')
di "  {hline 60}"
di "  Max Δβ/SE: " %6.3f `max_dse_all'

if `max_dse_all' < 3.0 {
    di as result _n "✓ TEST PASSED: IV Layer 4 works! (all Δβ/SE < 3)"
}
else {
    di as error _n "✗ TEST FAILED: Max Δβ/SE = " %6.3f `max_dse_all' " (target < 2)"
    exit 1
}

* Check first-stage
estat firststage
matrix fs = r(singleresults)
local fstat = fs[1,1]
di _n "First-stage F-statistic: " %6.2f `fstat'
if `fstat' > 10 {
    di as result "✓ Instruments remain strong"
}

di _n "=== TEST COMPLETE ==="
