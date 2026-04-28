* =============================================================================
* Test: datamirror auto prefix + optional tag + implicit init
* Purpose: Verify B.1 (auto-generated tags), B.2 (implicit init path for
*          checkpoint), and C.1 (auto prefix routes through correctly).
* Method:  Run a few regressions through 'datamirror auto', inspect the
*          session state via 'datamirror status', and verify the extract
*          produces the expected checkpoints_coef.csv payload.
* =============================================================================

clear all
set more off
set seed 12345

adopath ++ "stata/src"
adopath ++ "../registream/stata/src"

di as text ""
di as text "=========================================="
di as text "Test: datamirror auto prefix"
di as text "=========================================="
di as text ""

clear
set obs 500
gen x1 = rnormal(0, 1)
gen x2 = rnormal(0, 1)
gen y = 1.0 + 2.0*x1 - 1.5*x2 + rnormal(0, 1)
gen byte z = rbinomial(1, 0.3)

local outdir "stata/tests/output/test_auto_prefix"
datamirror init, checkpoint_dir("`outdir'") replace

* Auto-prefix: should run regress AND checkpoint in one line, tag auto-
* generated as "regress_1".
datamirror auto regress y x1 x2

* Explicit checkpoint with a tag: should work alongside auto.
reg y x1
datamirror checkpoint, tag("explicit_short")

* Another auto: tag should be "regress_2" since counter is per-command.
datamirror auto regress y x2

* Different command: starts its own counter.
datamirror auto logit z x1 x2

* Duplicate-capture guard. After the previous logit, e() is still in memory;
* calling 'datamirror checkpoint' again on it should no-op, not create a
* second entry. If this fails, expect 5 checkpoints instead of 4.
datamirror checkpoint, tag("dup_of_logit")

datamirror status

datamirror extract

* Validate the extract produced the consolidated coef file with the
* expected checkpoint count.
preserve
import delimited "`outdir'/checkpoints.csv", varnames(1) clear stringcols(_all)
local n_ckpts = _N
di as txt "Checkpoints written: `n_ckpts'"
if `n_ckpts' != 4 {
    di as error "FAIL: expected 4 checkpoints, got `n_ckpts'"
    restore
    exit 1
}

levelsof tag, local(tags) clean
di as txt "Tags: `tags'"

* Verify the auto-tag names appear.
local have_r1 : list posof "regress_1" in tags
local have_r2 : list posof "regress_2" in tags
local have_explicit : list posof "explicit_short" in tags
local have_l1 : list posof "logit_1" in tags

if `have_r1' == 0 | `have_r2' == 0 | `have_explicit' == 0 | `have_l1' == 0 {
    di as error "FAIL: missing expected tag"
    di as error "  regress_1: `have_r1'"
    di as error "  regress_2: `have_r2'"
    di as error "  explicit_short: `have_explicit'"
    di as error "  logit_1: `have_l1'"
    restore
    exit 1
}
restore

* Verify manifest.csv exists with the consolidated coef row.
preserve
import delimited "`outdir'/manifest.csv", varnames(1) clear stringcols(_all)
qui count if kind == "checkpoints_coef"
if r(N) != 1 {
    di as error "FAIL: manifest.csv missing checkpoints_coef row"
    restore
    exit 1
}
restore

* Verify metadata version keys.
preserve
import delimited "`outdir'/metadata.csv", varnames(1) clear stringcols(_all)
qui count if key == "schema_version"
local has_schema = r(N)
qui count if key == "datamirror_version"
local has_ver = r(N)
if `has_schema' != 1 | `has_ver' != 1 {
    di as error "FAIL: metadata.csv missing version keys"
    restore
    exit 1
}
restore

datamirror close

di as result ""
di as result "=========================================="
di as result "ALL AUTO-PREFIX TESTS PASSED ✓"
di as result "=========================================="
exit 0
