* =============================================================================
* test_unsupported_command.do
* -----------------------------------------------------------------------------
* Verify that `datamirror checkpoint` after an unsupported estimation command
* exits with the documented "not supported" error (rc=199) rather than
* silently storing a checkpoint that Layer 4 cannot reconstruct.
*
* Commands tested (all deferred per docs/SUPPORTED_MODELS.md):
*   tobit, ologit, mlogit
*
* stcox is intentionally excluded: stset mutates the dataset (adds _st, _d,
* _t, _t0) which trips the session's dataset-invariance check before the
* allowlist gate. That invariance check is a separate safety feature; the
* allowlist test should not be entangled with it.
* =============================================================================

clear all
set more off
set seed 42

* Build a small dataset that exercises each estimator.
set obs 500
gen y_cens   = cond(rnormal() < 0, 0, rnormal())  /* left-censored */
gen y_ord    = floor(runiform() * 3) + 1          /* 1/2/3 */
gen x1       = rnormal()
gen x2       = rnormal()

qui datamirror init, checkpoint_dir("/tmp/unsupported_test_out") replace min_cell_size(1)

local n_correct_refusals = 0
local n_total_tests = 0

* ----- tobit -----
cap noi tobit y_cens x1 x2, ll(0)
if _rc == 0 {
    local n_total_tests = `n_total_tests' + 1
    cap datamirror checkpoint, tag("unsupported_tobit")
    if _rc == 199 {
        local n_correct_refusals = `n_correct_refusals' + 1
        di as result "  ✓ tobit correctly rejected (rc=199)"
    }
    else {
        di as error "  ✗ tobit NOT rejected (rc=`=_rc', expected 199)"
    }
}

* ----- ologit -----
cap noi ologit y_ord x1 x2
if _rc == 0 {
    local n_total_tests = `n_total_tests' + 1
    cap datamirror checkpoint, tag("unsupported_ologit")
    if _rc == 199 {
        local n_correct_refusals = `n_correct_refusals' + 1
        di as result "  ✓ ologit correctly rejected (rc=199)"
    }
    else {
        di as error "  ✗ ologit NOT rejected (rc=`=_rc', expected 199)"
    }
}

* ----- mlogit -----
cap noi mlogit y_ord x1 x2
if _rc == 0 {
    local n_total_tests = `n_total_tests' + 1
    cap datamirror checkpoint, tag("unsupported_mlogit")
    if _rc == 199 {
        local n_correct_refusals = `n_correct_refusals' + 1
        di as result "  ✓ mlogit correctly rejected (rc=199)"
    }
    else {
        di as error "  ✗ mlogit NOT rejected (rc=`=_rc', expected 199)"
    }
}

qui datamirror close
cap rm -rf /tmp/unsupported_test_out

* ----- Assert all attempted refusals succeeded -----
di as txt _n "────────────────────────────────────────────"
di as txt "Unsupported-command test: `n_correct_refusals'/`n_total_tests' refusals correct"
di as txt "────────────────────────────────────────────"

if `n_total_tests' == 0 {
    di as error "⚠ TEST SKIPPED: no unsupported-command fits succeeded (Stata install issue?)"
    exit 0
}

if `n_correct_refusals' != `n_total_tests' {
    di as error _n "✗ TEST FAILED: at least one unsupported command was accepted"
    exit 1
}

di as result _n "✓ TEST PASSED: unsupported commands rejected cleanly"
