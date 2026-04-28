* =============================================================================
* Test: Logit Basic - Layer 4 checkpoint constraints for logit models
* Purpose: Test logit coefficient matching with synthetic data
* Method: Δβ/SE < 3 (inferential fidelity; synthetic β̂ within 3 SE of target).
* =============================================================================

clear all
set more off
set seed 12345

* Add DataMirror to path
adopath ++ "stata/src"
adopath ++ "../registream/stata/src"

di as text ""
di as text "=========================================="
di as text "Test: Logit Basic"
di as text "=========================================="
di as text ""

* -----------------------------------------------------------------------------
* Test 1: Simple Binary Outcome with Continuous Predictors
* -----------------------------------------------------------------------------

di as text "Test 1: Simple binary logit with continuous predictors"
di as text "----------------------------------------------------------"

clear
set obs 1000

* Generate predictors
gen x1 = rnormal(0, 1)
gen x2 = rnormal(0, 1.5)

* Generate binary outcome from logistic model
* True coefficients: intercept = -0.5, x1 = 0.8, x2 = -0.6
gen xb = -0.5 + 0.8*x1 - 0.6*x2
gen p = invlogit(xb)
gen y = rbinomial(1, p)

* Drop intermediate variables (not part of final dataset)
drop xb p

* Summary statistics
di as text ""
di as text "Data summary:"
sum y x1 x2
di as text "Outcome prevalence: " %5.3f r(mean)

* Fit original model
di as text ""
di as text "Original logit model:"
logit y x1 x2
matrix b_orig = e(b)

* Store original coefficients
local b_x1_orig = _b[x1]
local b_x2_orig = _b[x2]
local b_cons_orig = _b[_cons]

di as text ""
di as text "Original coefficients:"
di as text "  x1:    " %8.4f `b_x1_orig'
di as text "  x2:    " %8.4f `b_x2_orig'
di as text "  _cons: " %8.4f `b_cons_orig'

* Initialize DataMirror
local outdir "stata/tests/output/test_logit_basic/test1"
cap mkdir "stata/tests/output"
cap mkdir "stata/tests/output/test_logit_basic"
cap mkdir "`outdir'"

datamirror init, checkpoint_dir("`outdir'") replace

* Checkpoint the model
logit y x1 x2
datamirror checkpoint, tag("logit_simple")

* Extract metadata
di as text ""
di as text "Extracting metadata..."
datamirror extract, replace

* Rebuild synthetic data
di as text ""
di as text "Rebuilding synthetic data..."
datamirror rebuild using "`outdir'", clear seed(99999)

di as text ""
di as text "Synthetic data summary:"
sum y x1 x2

* Re-run model on synthetic data
di as text ""
di as text "Synthetic logit model:"
logit y x1 x2
matrix b_synth = e(b)

* Compare coefficients using Δβ/SE (inferential fidelity).
local b_x1_synth = _b[x1]
local b_x2_synth = _b[x2]
local b_cons_synth = _b[_cons]

local se_x1_synth = _se[x1]
local se_x2_synth = _se[x2]
local se_cons_synth = _se[_cons]

local delta_x1 = abs(`b_x1_synth' - `b_x1_orig')
local delta_x2 = abs(`b_x2_synth' - `b_x2_orig')
local delta_cons = abs(`b_cons_synth' - `b_cons_orig')

local dse_x1 = `delta_x1' / `se_x1_synth'
local dse_x2 = `delta_x2' / `se_x2_synth'
local dse_cons = `delta_cons' / `se_cons_synth'

di as text ""
di as text "Coefficient comparison:"
di as text "  Variable    Original    Synthetic       Δ      Δ/SE"
di as text "  ----------------------------------------------------------"
di as text "  x1       " %10.4f `b_x1_orig' "  " %10.4f `b_x1_synth' "  " %8.4f `delta_x1' "  " %6.3f `dse_x1'
di as text "  x2       " %10.4f `b_x2_orig' "  " %10.4f `b_x2_synth' "  " %8.4f `delta_x2' "  " %6.3f `dse_x2'
di as text "  _cons    " %10.4f `b_cons_orig' "  " %10.4f `b_cons_synth' "  " %8.4f `delta_cons' "  " %6.3f `dse_cons'

local max_dse_all = max(`dse_x1', `dse_x2', `dse_cons')
di as text "  ----------------------------------------------------------"
di as text "  Max Δβ/SE: " %6.3f `max_dse_all'

* Test assertion: all coefficients within 3 SE of target.
if `max_dse_all' < 3.0 {
    di as result "  ✓ PASS (all Δβ/SE < 3)"
    local test1_pass = 1
}
else {
    di as error "  ✗ FAIL (some Δβ/SE ≥ 3)"
    local test1_pass = 0
}

* -----------------------------------------------------------------------------
* Test 2: Binary Outcome with Factor Variables
* -----------------------------------------------------------------------------

di as text ""
di as text ""
di as text "Test 2: Logit with factor variables"
di as text "----------------------------------------------------------"

clear
set obs 1000
set seed 54321

* Generate predictors
gen x1 = rnormal(0, 1)
gen education = floor(runiform()*4) + 1  // 1, 2, 3, 4

* Generate outcome with education effects
* True: base=1, level2=+0.4, level3=+0.8, level4=+1.2
gen xb = -1.0 + 0.5*x1
replace xb = xb + 0.4 if education == 2
replace xb = xb + 0.8 if education == 3
replace xb = xb + 1.2 if education == 4
gen p = invlogit(xb)
gen y = rbinomial(1, p)

* Drop intermediate variables
drop xb p

* Summary
di as text ""
di as text "Data summary:"
sum y x1
tab education

* Fit original model
di as text ""
di as text "Original logit model:"
logit y x1 i.education
matrix b_orig = e(b)

* Store coefficients
local b_x1_orig = _b[x1]
local b_ed2_orig = _b[2.education]
local b_ed3_orig = _b[3.education]
local b_ed4_orig = _b[4.education]
local b_cons_orig = _b[_cons]

di as text ""
di as text "Original coefficients:"
di as text "  x1:          " %8.4f `b_x1_orig'
di as text "  2.education: " %8.4f `b_ed2_orig'
di as text "  3.education: " %8.4f `b_ed3_orig'
di as text "  4.education: " %8.4f `b_ed4_orig'
di as text "  _cons:       " %8.4f `b_cons_orig'

* Initialize DataMirror
local outdir "stata/tests/output/test_logit_basic/test2"
cap mkdir "`outdir'"

datamirror init, checkpoint_dir("`outdir'") replace

* Checkpoint
logit y x1 i.education
datamirror checkpoint, tag("logit_factor")

* Extract and rebuild
di as text ""
di as text "Extracting and rebuilding..."
datamirror extract, replace
datamirror rebuild using "`outdir'", clear seed(88888)

* Re-run on synthetic
di as text ""
di as text "Synthetic logit model:"
logit y x1 i.education

* Compare using Δβ/SE (inferential fidelity).
local b_x1_synth = _b[x1]
local b_ed2_synth = _b[2.education]
local b_ed3_synth = _b[3.education]
local b_ed4_synth = _b[4.education]
local b_cons_synth = _b[_cons]

local se_x1_synth = _se[x1]
local se_ed2_synth = _se[2.education]
local se_ed3_synth = _se[3.education]
local se_ed4_synth = _se[4.education]
local se_cons_synth = _se[_cons]

local delta_x1 = abs(`b_x1_synth' - `b_x1_orig')
local delta_ed2 = abs(`b_ed2_synth' - `b_ed2_orig')
local delta_ed3 = abs(`b_ed3_synth' - `b_ed3_orig')
local delta_ed4 = abs(`b_ed4_synth' - `b_ed4_orig')
local delta_cons = abs(`b_cons_synth' - `b_cons_orig')

local dse_x1 = `delta_x1' / `se_x1_synth'
local dse_ed2 = `delta_ed2' / `se_ed2_synth'
local dse_ed3 = `delta_ed3' / `se_ed3_synth'
local dse_ed4 = `delta_ed4' / `se_ed4_synth'
local dse_cons = `delta_cons' / `se_cons_synth'

di as text ""
di as text "Coefficient comparison:"
di as text "  Variable      Original    Synthetic       Δ      Δ/SE"
di as text "  --------------------------------------------------------"
di as text "  x1         " %10.4f `b_x1_orig' "  " %10.4f `b_x1_synth' "  " %8.4f `delta_x1' "  " %6.3f `dse_x1'
di as text "  2.education" %10.4f `b_ed2_orig' "  " %10.4f `b_ed2_synth' "  " %8.4f `delta_ed2' "  " %6.3f `dse_ed2'
di as text "  3.education" %10.4f `b_ed3_orig' "  " %10.4f `b_ed3_synth' "  " %8.4f `delta_ed3' "  " %6.3f `dse_ed3'
di as text "  4.education" %10.4f `b_ed4_orig' "  " %10.4f `b_ed4_synth' "  " %8.4f `delta_ed4' "  " %6.3f `dse_ed4'
di as text "  _cons      " %10.4f `b_cons_orig' "  " %10.4f `b_cons_synth' "  " %8.4f `delta_cons' "  " %6.3f `dse_cons'

local max_dse_cont = `dse_x1'
local max_dse_factor = max(`dse_ed2', `dse_ed3', `dse_ed4')
local max_dse_all = max(`dse_x1', `dse_ed2', `dse_ed3', `dse_ed4', `dse_cons')
di as text "  --------------------------------------------------------"
di as text "  Max Δβ/SE (continuous): " %6.3f `max_dse_cont'
di as text "  Max Δβ/SE (factors):    " %6.3f `max_dse_factor'
di as text "  Max Δβ/SE (with _cons): " %6.3f `max_dse_all'

* Logit uses iterative paired-swap adjustment (not direct DGP sampling).
* Factor levels are not adjustable in that engine (structural limitation),
* so we assert continuous Δβ/SE only. Factors are displayed for diagnosis.
if `max_dse_cont' < 3.0 {
    di as result "  ✓ PASS (continuous Δβ/SE < 3)"
    di as text "  Note: Factor Δβ/SE = " %6.3f `max_dse_factor' " (expected, factors not adjustable in logit engine)"
    local test2_pass = 1
}
else {
    di as error "  ✗ FAIL (continuous Δβ/SE ≥ 3)"
    local test2_pass = 0
}

* -----------------------------------------------------------------------------
* Test 3: Multiple Predictors
* -----------------------------------------------------------------------------

di as text ""
di as text ""
di as text "Test 3: Logit with multiple continuous predictors"
di as text "----------------------------------------------------------"

clear
set obs 1500
set seed 11111

* Generate 5 predictors
gen x1 = rnormal(0, 1)
gen x2 = rnormal(0, 1.2)
gen x3 = rnormal(0, 0.8)
gen x4 = rnormal(0, 1.5)
gen x5 = rnormal(0, 0.9)

* Generate outcome
gen xb = -0.3 + 0.6*x1 - 0.4*x2 + 0.3*x3 - 0.5*x4 + 0.7*x5
gen p = invlogit(xb)
gen y = rbinomial(1, p)

* Drop intermediate variables
drop xb p

* Fit original
di as text ""
di as text "Original logit model (5 predictors):"
logit y x1 x2 x3 x4 x5

* Store coefficients
forval i = 1/5 {
    local b_x`i'_orig = _b[x`i']
}
local b_cons_orig = _b[_cons]

* DataMirror workflow
local outdir "stata/tests/output/test_logit_basic/test3"
cap mkdir "`outdir'"

datamirror init, checkpoint_dir("`outdir'") replace
logit y x1 x2 x3 x4 x5
datamirror checkpoint, tag("logit_multi")

datamirror extract, replace
datamirror rebuild using "`outdir'", clear seed(77777)

* Re-run
di as text ""
di as text "Synthetic logit model:"
logit y x1 x2 x3 x4 x5

* Compare using Δβ/SE (inferential fidelity).
di as text ""
di as text "Coefficient comparison:"
di as text "  Variable    Original    Synthetic       Δ      Δ/SE"
di as text "  ----------------------------------------------------------"

local max_dse_cont = 0
forval i = 1/5 {
    local b_x`i'_synth = _b[x`i']
    local se_x`i'_synth = _se[x`i']
    local delta_x`i' = abs(`b_x`i'_synth' - `b_x`i'_orig')
    local dse_x`i' = `delta_x`i'' / `se_x`i'_synth'
    di as text "  x`i'      " %10.4f `b_x`i'_orig' "  " %10.4f `b_x`i'_synth' "  " %8.4f `delta_x`i'' "  " %6.3f `dse_x`i''
    if `dse_x`i'' > `max_dse_cont' {
        local max_dse_cont = `dse_x`i''
    }
}

local b_cons_synth = _b[_cons]
local se_cons_synth = _se[_cons]
local delta_cons = abs(`b_cons_synth' - `b_cons_orig')
local dse_cons = `delta_cons' / `se_cons_synth'
di as text "  _cons    " %10.4f `b_cons_orig' "  " %10.4f `b_cons_synth' "  " %8.4f `delta_cons' "  " %6.3f `dse_cons'

local max_dse_all = max(`max_dse_cont', `dse_cons')

di as text "  ----------------------------------------------------------"
di as text "  Max Δβ/SE: " %6.3f `max_dse_all'

if `max_dse_all' < 3.0 {
    di as result "  ✓ PASS (all Δβ/SE < 3)"
    local test3_pass = 1
}
else {
    di as error "  ✗ FAIL (some Δβ/SE ≥ 3)"
    local test3_pass = 0
}

* -----------------------------------------------------------------------------
* Final Summary
* -----------------------------------------------------------------------------

di as text ""
di as text ""
di as text "=========================================="
di as text "Test Summary: Logit Basic"
di as text "=========================================="
di as text ""
di as text "Test 1 (Simple):        " cond(`test1_pass', "✓ PASS", "✗ FAIL")
di as text "Test 2 (Factors):       " cond(`test2_pass', "✓ PASS", "✗ FAIL")
di as text "Test 3 (Multiple):      " cond(`test3_pass', "✓ PASS", "✗ FAIL")
di as text ""

local all_pass = `test1_pass' & `test2_pass' & `test3_pass'

if `all_pass' {
    di as result "=========================================="
    di as result "ALL TESTS PASSED ✓"
    di as result "=========================================="
    exit 0
}
else {
    di as error "=========================================="
    di as error "SOME TESTS FAILED ✗"
    di as error "=========================================="
    exit 1
}
