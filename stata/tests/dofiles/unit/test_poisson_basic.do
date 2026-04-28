* =============================================================================
* Test: Poisson Basic - Layer 4 checkpoint constraints for Poisson models
* Purpose: Test Poisson coefficient matching with synthetic count data
* Method: Δβ/SE < 3 (inferential fidelity; synthetic β̂ within 3 SE of target).
*         Poisson uses direct DGP sampling (y ~ Poisson(exp(Xβ*))), so
*         both continuous and factor coefficients land within O(1/√N) of
*         target. The Δβ/SE metric is the principled finite-N check.
* =============================================================================

clear all
set more off
set seed 12345

* Add DataMirror to path
adopath ++ "stata/src"
adopath ++ "../registream/stata/src"

di as text ""
di as text "=========================================="
di as text "Test: Poisson Basic"
di as text "=========================================="
di as text ""

* -----------------------------------------------------------------------------
* Test 1: Simple Count Outcome with Continuous Predictors
* -----------------------------------------------------------------------------

di as text "Test 1: Simple Poisson with continuous predictors"
di as text "----------------------------------------------------------"

clear
set obs 1000

* Generate predictors
gen x1 = rnormal(0, 1)
gen x2 = rnormal(0, 1.5)

* Generate count outcome from Poisson model
* True coefficients: intercept = 0.5, x1 = 0.3, x2 = -0.2
gen xb = 0.5 + 0.3*x1 - 0.2*x2
gen y = rpoisson(exp(xb))

* Drop intermediate variables (not part of final dataset)
drop xb

* Summary statistics
di as text ""
di as text "Data summary:"
sum y x1 x2
di as text "Mean count: " %5.3f r(mean)

* Fit original model
di as text ""
di as text "Original Poisson model:"
poisson y x1 x2
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
local outdir "stata/tests/output/test_poisson_basic/test1"
cap mkdir "stata/tests/output"
cap mkdir "stata/tests/output/test_poisson_basic"
cap mkdir "`outdir'"

datamirror init, checkpoint_dir("`outdir'") replace

* Checkpoint the model
poisson y x1 x2
datamirror checkpoint, tag("poisson_simple")

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
di as text "Synthetic Poisson model:"
poisson y x1 x2
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
* Test 2: Count Outcome with Factor Variables
* -----------------------------------------------------------------------------

di as text ""
di as text ""
di as text "Test 2: Poisson with factor variables"
di as text "----------------------------------------------------------"

clear
set obs 1000
set seed 54321

* Generate predictors
gen x1 = rnormal(0, 1)
gen region = floor(runiform()*4) + 1  // 1, 2, 3, 4

* Generate outcome with region effects
* True: base=1, level2=+0.2, level3=+0.4, level4=+0.6
gen xb = 0.8 + 0.25*x1
replace xb = xb + 0.2 if region == 2
replace xb = xb + 0.4 if region == 3
replace xb = xb + 0.6 if region == 4
gen y = rpoisson(exp(xb))

* Drop intermediate variables
drop xb

* Summary
di as text ""
di as text "Data summary:"
sum y x1
tab region

* Fit original model
di as text ""
di as text "Original Poisson model:"
poisson y x1 i.region
matrix b_orig = e(b)

* Store coefficients
local b_x1_orig = _b[x1]
local b_reg2_orig = _b[2.region]
local b_reg3_orig = _b[3.region]
local b_reg4_orig = _b[4.region]
local b_cons_orig = _b[_cons]

di as text ""
di as text "Original coefficients:"
di as text "  x1:        " %8.4f `b_x1_orig'
di as text "  2.region:  " %8.4f `b_reg2_orig'
di as text "  3.region:  " %8.4f `b_reg3_orig'
di as text "  4.region:  " %8.4f `b_reg4_orig'
di as text "  _cons:     " %8.4f `b_cons_orig'

* Initialize DataMirror
local outdir "stata/tests/output/test_poisson_basic/test2"
cap mkdir "`outdir'"

datamirror init, checkpoint_dir("`outdir'") replace

* Checkpoint
poisson y x1 i.region
datamirror checkpoint, tag("poisson_factor")

* Extract and rebuild
di as text ""
di as text "Extracting and rebuilding..."
datamirror extract, replace
datamirror rebuild using "`outdir'", clear seed(88888)

* Re-run on synthetic
di as text ""
di as text "Synthetic Poisson model:"
poisson y x1 i.region

* Compare using Δβ/SE (inferential fidelity).
local b_x1_synth = _b[x1]
local b_reg2_synth = _b[2.region]
local b_reg3_synth = _b[3.region]
local b_reg4_synth = _b[4.region]
local b_cons_synth = _b[_cons]

local se_x1_synth = _se[x1]
local se_reg2_synth = _se[2.region]
local se_reg3_synth = _se[3.region]
local se_reg4_synth = _se[4.region]
local se_cons_synth = _se[_cons]

local delta_x1 = abs(`b_x1_synth' - `b_x1_orig')
local delta_reg2 = abs(`b_reg2_synth' - `b_reg2_orig')
local delta_reg3 = abs(`b_reg3_synth' - `b_reg3_orig')
local delta_reg4 = abs(`b_reg4_synth' - `b_reg4_orig')
local delta_cons = abs(`b_cons_synth' - `b_cons_orig')

local dse_x1 = `delta_x1' / `se_x1_synth'
local dse_reg2 = `delta_reg2' / `se_reg2_synth'
local dse_reg3 = `delta_reg3' / `se_reg3_synth'
local dse_reg4 = `delta_reg4' / `se_reg4_synth'
local dse_cons = `delta_cons' / `se_cons_synth'

di as text ""
di as text "Coefficient comparison:"
di as text "  Variable      Original    Synthetic       Δ      Δ/SE"
di as text "  --------------------------------------------------------"
di as text "  x1         " %10.4f `b_x1_orig' "  " %10.4f `b_x1_synth' "  " %8.4f `delta_x1' "  " %6.3f `dse_x1'
di as text "  2.region   " %10.4f `b_reg2_orig' "  " %10.4f `b_reg2_synth' "  " %8.4f `delta_reg2' "  " %6.3f `dse_reg2'
di as text "  3.region   " %10.4f `b_reg3_orig' "  " %10.4f `b_reg3_synth' "  " %8.4f `delta_reg3' "  " %6.3f `dse_reg3'
di as text "  4.region   " %10.4f `b_reg4_orig' "  " %10.4f `b_reg4_synth' "  " %8.4f `delta_reg4' "  " %6.3f `dse_reg4'
di as text "  _cons      " %10.4f `b_cons_orig' "  " %10.4f `b_cons_synth' "  " %8.4f `delta_cons' "  " %6.3f `dse_cons'

local max_dse_cont = `dse_x1'
local max_dse_factor = max(`dse_reg2', `dse_reg3', `dse_reg4')
local max_dse_all = max(`dse_x1', `dse_reg2', `dse_reg3', `dse_reg4', `dse_cons')
di as text "  --------------------------------------------------------"
di as text "  Max Δβ/SE (continuous): " %6.3f `max_dse_cont'
di as text "  Max Δβ/SE (factors):    " %6.3f `max_dse_factor'
di as text "  Max Δβ/SE (with _cons): " %6.3f `max_dse_all'

* With DGP sampling (direct Poisson draw at target β*), all coefficients,
* continuous AND factor, should land within ~2 SE of target.
if `max_dse_all' < 3.0 {
    di as result "  ✓ PASS (all Δβ/SE < 3)"
    local test2_pass = 1
}
else {
    di as error "  ✗ FAIL (some Δβ/SE ≥ 3)"
    local test2_pass = 0
}

* -----------------------------------------------------------------------------
* Test 3: Multiple Predictors
* -----------------------------------------------------------------------------

di as text ""
di as text ""
di as text "Test 3: Poisson with multiple continuous predictors"
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
gen xb = 0.3 + 0.25*x1 - 0.15*x2 + 0.1*x3 - 0.2*x4 + 0.3*x5
gen y = rpoisson(exp(xb))

* Drop intermediate variables
drop xb

* Fit original
di as text ""
di as text "Original Poisson model (5 predictors):"
poisson y x1 x2 x3 x4 x5

* Store coefficients
forval i = 1/5 {
    local b_x`i'_orig = _b[x`i']
}
local b_cons_orig = _b[_cons]

* DataMirror workflow
local outdir "stata/tests/output/test_poisson_basic/test3"
cap mkdir "`outdir'"

datamirror init, checkpoint_dir("`outdir'") replace
poisson y x1 x2 x3 x4 x5
datamirror checkpoint, tag("poisson_multi")

datamirror extract, replace
datamirror rebuild using "`outdir'", clear seed(77777)

* Re-run
di as text ""
di as text "Synthetic Poisson model:"
poisson y x1 x2 x3 x4 x5

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
di as text "Test Summary: Poisson Basic"
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
