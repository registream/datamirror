* DataMirror Master Test Runner
* Run from datamirror/ root: do stata/tests/run_all_tests.do

clear all
set more off

adopath ++ "stata/src"
adopath ++ "../registream/stata/src"
cap mkdir "stata/tests/output"
cap mkdir "stata/tests/logs"

di as txt _n "════════════════════════════════════════════════════════════"
di as txt "DATAMIRROR TEST SUITE"
di as txt "════════════════════════════════════════════════════════════"
di as txt "Starting test run: $S_DATE $S_TIME"
di as txt "════════════════════════════════════════════════════════════"

* Track test results via globals so they survive across sub-do calls
global dm_total = 0
global dm_passed = 0
global dm_failed = 0
global dm_failed_list = ""

capture program drop run_test
program define run_test
	args test_file test_name

	di as txt _n "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	di as txt "Running: `test_name'"
	di as txt "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

	global dm_total = $dm_total + 1
	cap noi do `test_file'
	if _rc == 0 {
		di as result "✓ PASSED: `test_name'"
		global dm_passed = $dm_passed + 1
	}
	else {
		di as error "✗ FAILED: `test_name' (rc=`=_rc')"
		global dm_failed = $dm_failed + 1
		global dm_failed_list = "$dm_failed_list `test_name';"
	}
end

di as txt _n "════════════════════════════════════════════════════════════"
di as txt "UNIT TESTS"
di as txt "════════════════════════════════════════════════════════════"

local TDIR "stata/tests/dofiles/unit"
run_test "`TDIR'/test_ols_basic.do"           "OLS Regression (regress)"
run_test "`TDIR'/test_reghdfe_basic.do"       "Fixed Effects (reghdfe)"
run_test "`TDIR'/test_iv_basic.do"            "IV Regression (ivregress)"
run_test "`TDIR'/test_logit_basic.do"         "Logit Regression"
run_test "`TDIR'/test_probit_basic.do"        "Probit Regression"
run_test "`TDIR'/test_poisson_basic.do"       "Poisson Regression"
run_test "`TDIR'/test_nbreg_basic.do"         "Negative Binomial Regression"
run_test "`TDIR'/test_multiple_checkpoints.do" "Multiple Checkpoints"
run_test "`TDIR'/test_discrete_numeric.do"    "Discrete Numeric Variables"
run_test "`TDIR'/test_unsupported_command.do" "Unsupported Commands Rejected"
run_test "`TDIR'/test_auto_prefix.do"         "Auto Prefix + Optional Tag"

di as txt _n "════════════════════════════════════════════════════════════"
di as txt "UKHLS INTEGRATION TESTS"
di as txt "════════════════════════════════════════════════════════════"

cap confirm file "stata/tests/data/ukhls_clean.dta"
if _rc == 0 {
	run_test "stata/tests/dofiles/ukhls/test_ukhls_comprehensive.do" "UKHLS Comprehensive"
}
else {
	di as txt "⚠ Skipping UKHLS tests — stata/tests/data/ukhls_clean.dta not found"
}

di as txt _n "════════════════════════════════════════════════════════════"
di as txt "TEST SUMMARY"
di as txt "════════════════════════════════════════════════════════════"
di as txt "Total tests: $dm_total"
di as result "Passed: $dm_passed"
if $dm_failed > 0 {
	di as error "Failed: $dm_failed"
	di as error "  $dm_failed_list"
}
else {
	di as txt "Failed: 0"
}

if $dm_failed == 0 & $dm_total > 0 {
	di as result _n "✓ ALL TESTS PASSED"
}
else if $dm_total == 0 {
	di as error _n "⚠ NO TESTS RUN"
	exit 1
}
else {
	di as error _n "✗ SOME TESTS FAILED"
	exit 1
}
