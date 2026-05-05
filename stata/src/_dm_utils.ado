* =============================================================================
* RegiStream DataMirror Utility Functions
* Utilities specific to the datamirror module
* Usage: _dm_utils subcommand [args]
* =============================================================================

* -----------------------------------------------------------------------------
* PRIVACY PARAMETER: Minimum Cell Size for Statistical Disclosure Control
* -----------------------------------------------------------------------------
* This threshold ensures no small groups are revealed in checkpoint files.
*
* Resolution order at session init (nearest override wins):
*   1. `min_cell_size(N)` option on `datamirror init`  (per-session)
*   2. `dm_min_cell_size` in the registream config file (persistent per user)
*   3. $DM_MIN_CELL_SIZE source-level default below    (fallback)
*
* Persistent changes: `registream config, dm_min_cell_size(N)` writes to
* ~/.registream/config_stata.csv and affects all future sessions until reset.
*
* Standards by Statistical Agency:
*   - US Census Bureau:     10
*   - UK ONS:               10
*   - Statistics Sweden:     5 (tables), 20 (microdata)
*   - Eurostat:              5 (tables), 20 (microdata)
*   - OECD:                  5
*
* DataMirror Recommendation:
*   - 50 = Maximum safety (strictest agencies, public release)
*   - 20 = Standard for synthetic microdata (recommended default)
*   - 10 = Minimum acceptable (internal use only)
*
* Source-level default: 50 (waterproof for all agencies)
* -----------------------------------------------------------------------------
global DM_MIN_CELL_SIZE = 50

* -----------------------------------------------------------------------------
* PRIVACY PARAMETER: Quantile trimming for continuous marginals
* -----------------------------------------------------------------------------
* The 101-point quantile grid includes q0 and q100, which are the raw minimum
* and maximum of each continuous variable. Storing raw extremes is a classical
* Statistical Disclosure Control channel (Hundepool et al. 2012, §5.3;
* Willenborg & de Waal 2001, ch. 6): outliers are often sample-unique on the
* extreme and can be re-identified if an attacker believes their target is an
* extreme on some variable. The risk is most acute for stratified marginals on
* small strata, where the min and max are near-single-observation statistics.
*
* DM_QUANTILE_TRIM is the percentile boundary (in percent) at which q0 and
* q100 are top/bottom-coded. With trim = 1, q0 is stored as the 1st percentile
* and q100 as the 99th percentile. Interior quantiles (q1..q99) are unchanged.
*
* Resolution order at session init (nearest override wins):
*   1. `quantile_trim(x)` option on `datamirror init`   (per-session)
*   2. `dm_quantile_trim` in the registream config file (persistent per user)
*   3. $DM_QUANTILE_TRIM source-level default below     (fallback)
*
* Trade-off: larger trim contracts the synthetic support and gives stronger
* SDC; smaller trim preserves more of the observed tail. Set to 0 only if the
* extract runs against data that is already top/bottom-coded upstream.
*
* Source-level default: 1 (top and bottom 1% of each continuous variable).
* -----------------------------------------------------------------------------
global DM_QUANTILE_TRIM = 1


program define _dm_utils, rclass
	version 16.0

	gettoken subcmd 0 : 0, parse(" ,")

	if ("`subcmd'" == "init") {
		_dm_init `0'
		return add
	}
	else if ("`subcmd'" == "checkpoint") {
		_dm_checkpoint `0'
		return add
	}
	else if ("`subcmd'" == "extract") {
		_dm_extract `0'
		return add
	}
	else if ("`subcmd'" == "rebuild") {
		_dm_rebuild `0'
		return add
	}
	else if ("`subcmd'" == "check") {
		_dm_check `0'
		return add
	}
	else if ("`subcmd'" == "close") {
		_dm_close `0'
		return add
	}
	else if ("`subcmd'" == "status") {
		_dm_status `0'
		return add
	}
	else if ("`subcmd'" == "auto") {
		_dm_auto `0'
		return add
	}
	else {
		di as error "Invalid _dm_utils subcommand: `subcmd'"
		exit 198
	}
end

* #############################################################################
* SECTION A: SESSION MANAGEMENT
* -----------------------------------------------------------------------------
* init / close / checkpoint — session lifecycle and global state
* #############################################################################


* -----------------------------------------------------------------------------
* init: Initialize checkpoint session
* -----------------------------------------------------------------------------
program define _dm_init
	version 16.0
	syntax , checkpoint_dir(string) [replace clear strata(varname) min_cell_size(integer -1) quantile_trim(real -1)]

	* Check if session already active
	if "$dm_checkpoint_dir" != "" & "`clear'" == "" & "`replace'" == "" {
		di as error "Checkpoint session already active: $dm_checkpoint_dir"
		di as error "Use 'datamirror close' first, or specify -clear- or -replace- option"
		exit 110
	}

	* Clear previous session if requested
	if "`clear'" != "" {
		_dm_utils close
	}

	* Validate strata variable if specified
	if "`strata'" != "" {
		cap confirm variable `strata'
		if _rc != 0 {
			di as error "Stratification variable '`strata'' not found in data"
			exit 111
		}

		* Check if data is xtset and strata differs from time variable
		cap qui xtset
		if _rc == 0 {
			local panelvar = r(panelvar)
			local timevar = r(timevar)

			if "`timevar'" != "" & "`strata'" != "`timevar'" {
				di as txt _n "{bf:WARNING:} Data is xtset with time variable '{bf:`timevar'}'"
				di as txt "           but stratification variable is '{bf:`strata'}'"
				di as txt "           Panel models will use {bf:`panelvar'} × {bf:`timevar'} structure"
				di as txt "           Stratification will use '{bf:`strata'}'"
				di as txt ""
				di as txt "           Is this intentional? Type 'yes' to continue:"
				di as txt "           " _request(confirm_strata)

				if "$confirm_strata" != "yes" {
					di as error "Initialization cancelled"
					exit 1
				}
			}
		}
	}

	* Check if directory already exists
	cap confirm file "`checkpoint_dir'/metadata.csv"
	if _rc == 0 & "`replace'" == "" {
		di as error _n "datamirror: {bf:`checkpoint_dir'/}" " already contains a bundle."
		di as error "To reuse the directory (overwrites existing files), add the " `"'replace'"' " option:"
		di as error "    datamirror init, checkpoint_dir(" `""`checkpoint_dir'""' ") replace"
		di as error "Or choose a different directory name."
		exit 602
	}

	* Wipe any stale v1.0 bundle files when -replace- is set. Intent
	* matches Stata's usual "replace" semantics (file write replace
	* erases the target): the subsequent extract should start from a
	* clean directory, so old-schema or half-written files can't leak
	* into the new bundle. Only named bundle files are removed; any
	* unrelated files the user has placed in the directory are left
	* alone.
	if "`replace'" != "" {
		local _bundle_files "metadata.csv schema.csv marginals_cont.csv marginals_cat.csv correlations.csv marginals_cont_stratified.csv marginals_cat_stratified.csv correlations_stratified.csv checkpoints.csv checkpoints_coef.csv manifest.csv"
		foreach f of local _bundle_files {
			cap erase "`checkpoint_dir'/`f'"
		}
		* Old-schema per-checkpoint coef files (pre-consolidation).
		forval i = 1/200 {
			cap erase "`checkpoint_dir'/checkpoint_`i'_coef.csv"
		}
	}

	* Create directory (with parent directories if needed).
	* _rs_utils mkdir_p is recursive, native, no shell.
	_rs_utils mkdir_p "`checkpoint_dir'"

	* Verify directory was created. Use _rs_utils confirmdir (cap cd test)
	* rather than `confirm file dir/.` — the latter returns r(601) for
	* directories on Stata for Windows regardless of whether the directory
	* exists, breaking init even after a successful mkdir.
	_rs_utils confirmdir "`checkpoint_dir'"
	if r(exists) != 1 {
		di as error "Could not create directory: `checkpoint_dir'/"
		exit 603
	}

	* Initialize session globals
	global dm_checkpoint_dir "`checkpoint_dir'"
	global dm_n_checkpoints = 0
	global dm_strata_var "`strata'"

	* Resolve session-level minimum cell size for privacy suppression.
	* Resolution order: option > registream config > source default.
	if `min_cell_size' > 0 {
		global dm_min_cell_size = `min_cell_size'
	}
	else {
		local resolved = $DM_MIN_CELL_SIZE
		cap _rs_utils get_dir
		if !_rc {
			local rs_dir "`r(dir)'"
			cap _rs_config get "`rs_dir'" "dm_min_cell_size"
			if !_rc & r(found) == 1 {
				local cfg_val = r(value)
				if real("`cfg_val'") > 0 {
					local resolved = real("`cfg_val'")
				}
			}
		}
		global dm_min_cell_size = `resolved'
	}

	* Resolve session-level quantile-trim percentile for continuous SDC.
	* Resolution order: option > registream config > source default.
	if `quantile_trim' >= 0 {
		global dm_quantile_trim = `quantile_trim'
	}
	else {
		local resolved_qt = $DM_QUANTILE_TRIM
		cap _rs_utils get_dir
		if !_rc {
			local rs_dir "`r(dir)'"
			cap _rs_config get "`rs_dir'" "dm_quantile_trim"
			if !_rc & r(found) == 1 {
				local cfg_val = r(value)
				if real("`cfg_val'") >= 0 {
					local resolved_qt = real("`cfg_val'")
				}
			}
		}
		global dm_quantile_trim = `resolved_qt'
	}

	* Store dataset signature for validation
	global dm_dataset_N = _N
	global dm_dataset_k = c(k)

	di as txt _n "══════════════════════════════════════════════════════════════"
	di as result "DATAMIRROR SESSION INITIALIZED"
	di as txt "══════════════════════════════════════════════════════════════"
	di as txt "Checkpoint directory: " as result "`checkpoint_dir'/"
	if $dm_min_cell_size != $DM_MIN_CELL_SIZE {
		di as txt "Min cell size:        " as result $dm_min_cell_size ///
			as txt " (default is $DM_MIN_CELL_SIZE)"
	}
	if $dm_quantile_trim != $DM_QUANTILE_TRIM {
		di as txt "Quantile trim:        " as result $dm_quantile_trim "%" ///
			as txt " (default is $DM_QUANTILE_TRIM%)"
	}
	if $dm_quantile_trim == 0 {
		di as txt "Warning: quantile_trim(0) stores raw max/min in q0/q100." ///
			_n "  Set only if the data were top/bottom-coded upstream."
	}
	if "`strata'" != "" {
		di as txt "Stratification:       " as result "`strata'"

		* Count strata levels
		qui levelsof `strata', local(strata_levels)
		local n_strata : word count `strata_levels'
		di as txt "Strata levels:        " as result "`n_strata'"
	}
	di as txt ""
	di as txt "Ready to checkpoint models. Usage:"
	di as txt "  1. Run your regression/model"
	di as txt `"  2. datamirror checkpoint, tag("name")"'
	di as txt "  3. Repeat for all models"
	di as txt "  4. datamirror extract"
	di as txt "  5. datamirror close"
	if "`strata'" != "" {
		di as txt ""
		di as txt "Note: Stratification enabled. Synthetic data will preserve"
		di as txt "      within-`strata' marginals and correlations."
	}
	di as txt "══════════════════════════════════════════════════════════════"
end

* -----------------------------------------------------------------------------
* close: Close checkpoint session and clear globals
* -----------------------------------------------------------------------------
program define _dm_close
	version 16.0

	* Check if session is active
	if "$dm_checkpoint_dir" == "" {
		di as txt "No active checkpoint session to close"
		exit 0
	}

	local dir "$dm_checkpoint_dir"
	local n_ckpts = $dm_n_checkpoints

	* Check if checkpoints were extracted
	if `n_ckpts' > 0 {
		cap confirm file "`dir'/metadata.csv"
		if _rc != 0 {
			di as error _n "WARNING: Session has `n_ckpts' checkpoint(s) that were NOT extracted!"
			di as error "         Data will be lost when you close this session."
			di as error ""
			di as error "         Run 'datamirror extract' before closing, or type 'yes' to discard:"
			di as txt "         " _request(confirm_close)

			if "$confirm_close" != "yes" {
				di as txt _n "Session close cancelled. Checkpoints preserved in memory."
				exit 0
			}
			di as txt ""
		}
	}

	* Clear all checkpoint globals
	forval i = 1/`n_ckpts' {
		global dm_cp`i'_tag ""
		global dm_cp`i'_notes ""
		global dm_cp`i'_cmd ""
		global dm_cp`i'_cmdline ""
		global dm_cp`i'_N ""
		global dm_cp`i'_depvar ""
		global dm_cp`i'_varnames ""
		global dm_cp`i'_r2 ""
		global dm_cp`i'_r2_a ""
		global dm_cp`i'_r2_p ""
		global dm_cp`i'_rmse ""
		global dm_cp`i'_sample_expr ""

		cap matrix drop dm_cp`i'_b
		cap matrix drop dm_cp`i'_V
	}

	* Clear session globals
	global dm_checkpoint_dir ""
	global dm_n_checkpoints ""
	global dm_strata_var ""
	global dm_dataset_N ""
	global dm_dataset_k ""
	global dm_min_cell_size ""
	global dm_quantile_trim ""

	* Clear per-command auto-tag counters (see _dm_checkpoint).
	foreach c in regress reg reghdfe ivregress logit logistic probit poisson nbreg {
		global dm_autocount_`c' ""
	}

	di as txt _n "══════════════════════════════════════════════════════════════"
	di as result "DATAMIRROR SESSION CLOSED"
	di as txt "══════════════════════════════════════════════════════════════"
	di as txt "Session: " as result "`dir'/"
	di as txt "Checkpoints created: " as result "`n_ckpts'"
	di as txt ""
	di as txt "All checkpoint globals cleared"
	di as txt "You can now start a new session with 'datamirror init'"
	di as txt "══════════════════════════════════════════════════════════════"
end

* -----------------------------------------------------------------------------
* status: Report the current session state at a glance
* -----------------------------------------------------------------------------
program define _dm_status
	version 16.0

	if "$dm_checkpoint_dir" == "" {
		di as txt _n "No datamirror session is active."
		di as txt `"Start one with: datamirror init, checkpoint_dir("...")"'
		exit 0
	}

	di as txt _n "══════════════════════════════════════════════════════════════"
	di as result "DATAMIRROR SESSION STATUS"
	di as txt "══════════════════════════════════════════════════════════════"
	di as txt "Checkpoint dir:  " as result "$dm_checkpoint_dir/"
	if "$dm_strata_var" != "" {
		di as txt "Stratified by:   " as result "$dm_strata_var"
	}
	if "$dm_min_cell_size" != "" {
		di as txt "min_cell_size:   " as result "$dm_min_cell_size"
	}
	if "$dm_dataset_N" != "" {
		di as txt "Dataset at init: " as result "$dm_dataset_N" as txt " obs × " as result "$dm_dataset_k" as txt " vars"
	}

	local n = $dm_n_checkpoints
	if "`n'" == "" {
		local n = 0
	}
	di as txt "Checkpoints:     " as result "`n'"

	if `n' > 0 {
		di as txt ""
		di as txt "  #   tag                              cmd        depvar       N"
		di as txt "  ─── ──────────────────────────────── ────────── ──────────── ──────────"
		forval i = 1/`n' {
			local tag    "${dm_cp`i'_tag}"
			local cmd    "${dm_cp`i'_cmd}"
			local depvar "${dm_cp`i'_depvar}"
			local nobs   "${dm_cp`i'_N}"
			di as txt "  " %3.0f `i' " " %-32s abbrev("`tag'", 32) " " %-10s abbrev("`cmd'", 10) " " %-12s abbrev("`depvar'", 12) " " %10s "`nobs'"
		}
	}

	di as txt "══════════════════════════════════════════════════════════════"
	if `n' == 0 {
		di as txt "Next:  run a supported regression, then " as result "datamirror checkpoint"
	}
	else {
		di as txt "Next:  " as result "datamirror extract" as txt " to write the bundle to disk,"
		di as txt "       or " as result "datamirror close" as txt " to discard the session."
	}
end

* -----------------------------------------------------------------------------
* checkpoint: Capture regression results for reconstruction
* -----------------------------------------------------------------------------
program define _dm_checkpoint
	version 16.0
	syntax [, tag(string) notes(string)]

	* Check that session is initialized. If not, offer an implicit init
	* rather than sending the user back to the docs. Register research
	* scripts often have dozens of checkpoints and forgetting the init
	* line at the top is the most common first-run friction.
	if "$dm_checkpoint_dir" == "" {
		di as txt "No datamirror session is active."
		di as txt "Initialize in current directory as {bf:datamirror_out/}? (y/n)"
		di as txt _request(_dm_implicit_init)
		if lower(trim("$_dm_implicit_init")) == "y" {
			global _dm_implicit_init ""
			_dm_init, checkpoint_dir("datamirror_out") replace
		}
		else {
			global _dm_implicit_init ""
			di as error _n `"Checkpoint cancelled. Run 'datamirror init, checkpoint_dir("...")' to start a session."'
			exit 119
		}
	}

	* Validate dataset hasn't changed since init
	if "$dm_dataset_N" != "" {
		if _N != $dm_dataset_N | c(k) != $dm_dataset_k {
			di as txt _n "{bf:WARNING:} Dataset appears to have changed since initialization"
			di as txt "         Init: N=$dm_dataset_N, vars=$dm_dataset_k"
			di as txt "         Now:  N=" _N ", vars=" c(k)
			di as txt ""
			di as txt "         Checkpoints from different datasets cannot be combined."
			di as txt "         Continue anyway? Type 'yes' to proceed:"
			di as txt "         " _request(confirm_changed)

			if "$confirm_changed" != "yes" {
				di as error _n "Checkpoint cancelled. Use 'datamirror close' and re-initialize."
				exit 459
			}
			di as txt ""
		}
	}

	* Check that a model was just estimated. Name what to do next rather
	* than just reporting the missing state.
	if "`e(cmd)'" == "" {
		di as error _n "datamirror: no estimation results in memory."
		di as error "Run a supported regression (regress, reghdfe, ivregress, logit, probit, poisson, nbreg) first,"
		di as error "then call " `"'datamirror checkpoint'"' " to capture it."
		exit 301
	}

	* Supported-command allowlist. Reject unsupported commands early with a
	* clean error rather than storing a checkpoint that Layer 4 cannot
	* reconstruct at rebuild time. See docs/SUPPORTED_MODELS.md for the
	* current list; v1.1 will extend via the ROADMAP Tier 1 items.
	local supported_cmds "regress reg reghdfe ivregress logit logistic probit poisson nbreg"
	local cmd_found : list posof "`e(cmd)'" in supported_cmds
	if `cmd_found' == 0 {
		di as error _n "datamirror: command `'`e(cmd)'`' is not supported in v1.0."
		di as error "Supported commands: `supported_cmds'."
		di as error "See docs/SUPPORTED_MODELS.md for the current list and v1.1 roadmap."
		exit 199
	}

	* Duplicate-capture guard. Common case: user mixes 'datamirror auto'
	* with an explicit 'datamirror checkpoint' and the second call sees
	* the same e() results still in memory. Scan every stored checkpoint
	* for a matching cmd+cmdline+N triple; if one matches, no-op with a
	* message rather than storing the identical regression twice.
	local new_cmd     "`e(cmd)'"
	local new_cmdline "`e(cmdline)'"
	local new_N       = e(N)
	forval i = 1/$dm_n_checkpoints {
		if "${dm_cp`i'_cmd}" == "`new_cmd'" & ///
		   "${dm_cp`i'_cmdline}" == "`new_cmdline'" & ///
		   "${dm_cp`i'_N}" == "`new_N'" {
			di as txt _n "datamirror: this regression is already captured as tag " ///
				as result "'${dm_cp`i'_tag}'" as txt " (checkpoint `i'), skipping."
			exit 0
		}
	}

	* Auto-generate tag when omitted: <cmd>_<per-command counter>.
	* Per-command counters keep names predictable when a single script
	* mixes regress, logit, etc., so the user doesn't have to invent a
	* name for every regression.
	if "`tag'" == "" {
		local autotag_cmd "`e(cmd)'"
		local cur = 0
		cap local cur = ${dm_autocount_`autotag_cmd'}
		local cur = `cur' + 1
		global dm_autocount_`autotag_cmd' = `cur'
		local tag "`autotag_cmd'_`cur'"
	}

	* Check for duplicate tags
	forval i = 1/$dm_n_checkpoints {
		if "${dm_cp`i'_tag}" == "`tag'" {
			di as error "Checkpoint tag '`tag'' already exists (checkpoint `i')"
			di as error "Use a unique tag for each checkpoint"
			exit 110
		}
	}

	* Initialize checkpoint storage if first time
	if "$dm_n_checkpoints" == "" {
		global dm_n_checkpoints = 0
	}

	* Increment checkpoint counter
	global dm_n_checkpoints = $dm_n_checkpoints + 1
	local cp_num = $dm_n_checkpoints

	di as txt _n "Checkpoint `cp_num': `tag'"
	di as txt "  Command: " as result "`e(cmd)'"
	di as txt "  N = " as result e(N)

	* Store checkpoint metadata
	global dm_cp`cp_num'_tag "`tag'"
	global dm_cp`cp_num'_notes "`notes'"
	global dm_cp`cp_num'_cmd "`e(cmd)'"
	global dm_cp`cp_num'_cmdline "`e(cmdline)'"
	global dm_cp`cp_num'_N = e(N)
	global dm_cp`cp_num'_depvar "`e(depvar)'"

	* Get variable names from coefficient vector
	local varnames : colnames e(b)
	global dm_cp`cp_num'_varnames "`varnames'"

	* Store coefficient vector
	tempname b V
	matrix `b' = e(b)
	matrix `V' = e(V)

	matrix dm_cp`cp_num'_b = `b'
	matrix dm_cp`cp_num'_V = `V'

	* Store model-specific statistics
	if "`e(cmd)'" == "regress" | "`e(cmd)'" == "reg" {
		global dm_cp`cp_num'_r2 = e(r2)
		global dm_cp`cp_num'_r2_a = e(r2_a)
		global dm_cp`cp_num'_rmse = e(rmse)
		di as txt "  R² = " as result %5.4f e(r2)
	}
	else if "`e(cmd)'" == "logit" | "`e(cmd)'" == "logistic" {
		global dm_cp`cp_num'_r2_p = e(r2_p)
		global dm_cp`cp_num'_ll = e(ll)
		global dm_cp`cp_num'_ll_0 = e(ll_0)
		di as txt "  Pseudo-R² = " as result %5.4f e(r2_p)
		di as txt "  Log-likelihood = " as result %10.2f e(ll)

		* Check for factor variables and warn
		local has_factors = 0
		foreach vname of local varnames {
			if regexm("`vname'", "^[0-9]+[bo]?\.") {
				local has_factors = 1
			}
		}
		if `has_factors' {
			di as txt ""
			di as txt "{bf:⚠ WARNING:} Factor coefficients in logit models have theoretical limitation"
			di as txt "  Continuous predictors: Δβ < 0.05 (excellent)"
			di as txt "  Factor predictors:     Δβ ≈ 0.5-1.5 (limited by discrete outcome structure)"
			di as txt "  See documentation: docs/LAYER4.md (Mathematical Limitation section)"
		}
	}
	else if "`e(cmd)'" == "probit" {
		global dm_cp`cp_num'_r2_p = e(r2_p)
		global dm_cp`cp_num'_ll = e(ll)
		global dm_cp`cp_num'_ll_0 = e(ll_0)
		di as txt "  Pseudo-R² = " as result %5.4f e(r2_p)
		di as txt "  Log-likelihood = " as result %10.2f e(ll)

		* Check for factor variables and warn
		local has_factors = 0
		foreach vname of local varnames {
			if regexm("`vname'", "^[0-9]+[bo]?\.") {
				local has_factors = 1
			}
		}
		if `has_factors' {
			di as txt ""
			di as txt "{bf:⚠ WARNING:} Factor coefficients in probit models have theoretical limitation"
			di as txt "  Continuous predictors: Δβ < 0.05 (excellent)"
			di as txt "  Factor predictors:     Δβ ≈ 0.5-1.5 (limited by discrete outcome structure)"
			di as txt "  See documentation: docs/LAYER4.md (Mathematical Limitation section)"
		}
	}
	else if "`e(cmd)'" == "poisson" {
		global dm_cp`cp_num'_r2_p = e(r2_p)
		global dm_cp`cp_num'_ll = e(ll)
		global dm_cp`cp_num'_ll_0 = e(ll_0)
		di as txt "  Pseudo-R² = " as result %5.4f e(r2_p)
		di as txt "  Log-likelihood = " as result %10.2f e(ll)
	}
	else if "`e(cmd)'" == "nbreg" {
		global dm_cp`cp_num'_r2_p = e(r2_p)
		global dm_cp`cp_num'_ll = e(ll)
		global dm_cp`cp_num'_ll_0 = e(ll_0)
		global dm_cp`cp_num'_alpha = e(alpha)
		di as txt "  Pseudo-R² = " as result %5.4f e(r2_p)
		di as txt "  Log-likelihood = " as result %10.2f e(ll)
		di as txt "  Dispersion α = " as result %6.4f e(alpha)
	}

	* Store sample expression if present
	global dm_cp`cp_num'_sample_expr ""
	local cmdline "`e(cmdline)'"
	if strpos("`cmdline'", " if ") > 0 {
		local pos = strpos("`cmdline'", " if ")
		local after_if = substr("`cmdline'", `pos' + 4, .)
		* Find end of if expression (before "in" or end of string)
		local in_pos = strpos("`after_if'", " in ")
		if `in_pos' > 0 {
			local sample_expr = substr("`after_if'", 1, `in_pos' - 1)
		}
		else {
			local sample_expr "`after_if'"
		}
		global dm_cp`cp_num'_sample_expr "`sample_expr'"
		di as txt "  Sample: if `sample_expr'"
	}

	di as result "✓ Checkpoint `cp_num' saved"
end

* -----------------------------------------------------------------------------
* auto: Prefix command that runs an estimation then auto-checkpoints.
*
* Usage:  datamirror auto <estimation command>
* Example: datamirror auto regress y x1 x2
*
* Motivation: the explicit pattern ({cmd:regress ... ; datamirror checkpoint,
* tag("...")} doubles the line count of a script and forces the analyst to
* invent a tag for every regression. The {cmd:auto} prefix wraps the
* estimation, runs it as-typed, and calls {cmd:_dm_checkpoint} with no tag
* (auto-generated as <cmd>_<counter>). Failures in the estimation propagate
* as-is; failures in the checkpoint step only warn and do not roll back the
* estimation results.
*
* This is the reliable Stata-idiomatic mechanism. True "invisible trace-based
* capture" is not supported because Stata provides no post-estimation hook
* that fires for arbitrary estimation commands; every workable mechanism
* reduces to some form of prefix or wrapper.
* -----------------------------------------------------------------------------
program define _dm_auto, eclass
	version 16.0

	if `"`0'"' == "" {
		di as error _n "datamirror auto: no estimation command supplied."
		di as error "Usage: datamirror auto <estimation cmd>"
		di as error "Example: datamirror auto regress y x1 x2"
		exit 198
	}

	* Run the user command. ereturn results propagate to the caller
	* because this program is declared eclass.
	`0'

	* Silently no-op if nothing got estimated (some prefix commands,
	* like -xi- when it only builds indicators, don't post e() results).
	if "`e(cmd)'" == "" {
		exit 0
	}

	_dm_checkpoint
end

* #############################################################################
* SECTION B: EXTRACT
* -----------------------------------------------------------------------------
* schema, marginals, correlations, stratified marginals → CSV files
* #############################################################################

* -----------------------------------------------------------------------------
* Helper function: Classify variable as categorical (1) or continuous (0)
* This is the SINGLE source of truth for variable classification
* -----------------------------------------------------------------------------
program define _dm_classify_variable
	args varname

	* Get variable type
	local vtype : type `varname'

	* Strings are always categorical
	if substr("`vtype'", 1, 3) == "str" {
		c_local is_categorical 1
		exit
	}

	* For numeric variables, check unique values
	cap qui tab `varname'
	if _rc != 0 {
		* Tab failed (too many values) - treat as continuous
		c_local is_categorical 0
		exit
	}
	local nuniq = r(r)

	* Check for value label
	local vlab : value label `varname'

	* Classification logic (consistent everywhere):
	* Categorical if:
	*   - Has value label AND ≤100 unique values AND < 1% density
	*   - OR ≤100 unique values AND < 5% density (no value label required)
	* Otherwise continuous
	*
	* Rationale: Variables like months (30 values), weeks (52 values), etc.
	* are discrete even without value labels
	* UPDATED: Threshold increased to support school IDs (64 unique values, ~2% density)
	if "`vlab'" != "" & `nuniq' <= 100 & `nuniq' < _N/100 {
		c_local is_categorical 1
	}
	else if `nuniq' <= 100 & `nuniq' < _N/20 {
		c_local is_categorical 1
	}
	else {
		c_local is_categorical 0
	}
end

* -----------------------------------------------------------------------------
* extract: Export data and checkpoints
* -----------------------------------------------------------------------------
program define _dm_extract
	version 16.0
	syntax [, replace]

	* Check that session is initialized
	if "$dm_checkpoint_dir" == "" {
		di as error "No checkpoint session initialized"
		di as error "Use 'datamirror init, checkpoint_dir(\"name\")' first"
		exit 119
	}

	* Checkpoints are now optional - if none exist, extract only Layers 1-3
	if "$dm_n_checkpoints" == "" {
		global dm_n_checkpoints = 0
	}

	* Resolve session-level privacy threshold (falls back to file default
	* if the session was initialized before this feature existed).
	if "$dm_min_cell_size" != "" {
		local min_cell = $dm_min_cell_size
	}
	else {
		local min_cell = `min_cell'
	}

	* Resolve session-level quantile trim (percent to top/bottom-code off
	* the continuous quantile grid). Falls back to source default if the
	* session was initialized before this feature existed.
	if "$dm_quantile_trim" != "" {
		local qtrim = $dm_quantile_trim
	}
	else {
		local qtrim = $DM_QUANTILE_TRIM
	}
	local qtrim_hi = 100 - `qtrim'

	* Suppression counters — accumulated across all privacy passes and
	* persisted into metadata.csv at the end of extract for audit trail.
	local n_suppressed = 0
	local n_categories = 0
	local n_suppressed_strat = 0
	local n_categories_strat = 0
	local n_strata_skipped = 0
	local n_strata_skipped_cont = 0

	* Use checkpoint_dir from session
	local outdir "$dm_checkpoint_dir"

	if "`replace'" == "" {
		cap confirm file "`outdir'/metadata.csv"
		if _rc == 0 {
			di as error "Output directory `outdir' already exists"
			di as error "Files would be overwritten. Use -replace- option, or datamirror init with -replace-"
			exit 602
		}
	}

	di as txt _n "══════════════════════════════════════════════════════════════"
	di as result "DATAMIRROR EXTRACT"
	di as txt "══════════════════════════════════════════════════════════════"

	* Metadata is written LAST so it can record privacy-suppression counts
	* accumulated across all subsequent passes (marginals, stratified, corr).

	* Export schema
	di as txt "Exporting schema..."

	* Capture ALL variables in dataset (not just checkpoint vars)
	qui ds
	local allvars "`r(varlist)'"

	di as txt "Capturing " as result "`=c(k)'" as txt " variables from dataset"

	file open schema using "`outdir'/schema.csv", write replace
	file write schema "varname,type,format,storage,is_integer" _n

	foreach var of local allvars {
		local vtype : type `var'
		local vfmt : format `var'

		* Classify as continuous or categorical using helper
		_dm_classify_variable `var'
		local storage = cond(`is_categorical', "categorical", "continuous")

		* Check if variable is integer-valued (all non-missing values are integers)
		local is_integer = 0
		cap confirm numeric variable `var'
		if _rc == 0 {
			qui count if !missing(`var') & `var' != floor(`var')
			if r(N) == 0 {
				local is_integer = 1
			}
		}

		file write schema "`var',`vtype',`vfmt',`storage',`is_integer'" _n
	}
	file close schema

	di as result "✓ schema.csv"

	* Export marginals for continuous variables
	di as txt "Exporting marginals (continuous)..."

	file open marg using "`outdir'/marginals_cont.csv", write replace
	file write marg "varname"
	forval q = 0(1)100 {
		file write marg ",q`q'"
	}
	file write marg _n

	foreach var of local allvars {
		* Check if continuous using helper
		_dm_classify_variable `var'

		if !`is_categorical' {
				* Continuous variable - get quantiles.
				* PRIVACY: the tails of the grid are top/bottom-coded at
				* DM_QUANTILE_TRIM percent to suppress raw extremes
				* (Hundepool et al. 2012, §5.3). With trim = k:
				*   q[0..k]       plateau at the k-th percentile
				*   q[k+1..99-k]  natural empirical quantile
				*   q[100-k..100] plateau at the (100-k)-th percentile
				* Trim = 0 disables this (raw min/max in q0/q100).
				* The grid stays monotonic, so rebuild's linear
				* interpolation on [q_lower, q_upper] is unaffected.
				qui sum `var', detail
				if `qtrim' > 0 {
					qui _pctile `var', p(`qtrim')
					local v_lo = r(r1)
					qui _pctile `var', p(`qtrim_hi')
					local v_hi = r(r1)
				}

				file write marg "`var'"
				forval q = 0(1)100 {
					if `qtrim' <= 0 & `q' == 0 {
						local val = r(min)
					}
					else if `qtrim' <= 0 & `q' == 100 {
						local val = r(max)
					}
					else if `qtrim' > 0 & `q' <= `qtrim' {
						local val = `v_lo'
					}
					else if `qtrim' > 0 & `q' >= `qtrim_hi' {
						local val = `v_hi'
					}
					else {
						qui _pctile `var', p(`q')
						local val = r(r1)
					}

					if "`val'" == "" | "`val'" == "." {
						file write marg ",NA"
					}
					else {
						file write marg "," (`val')
					}
				}
				file write marg _n
			}
		}
	file close marg

	di as result "✓ marginals_cont.csv"

	* Export marginals for categorical variables
	di as txt "Exporting marginals (categorical)..."

	file open cat using "`outdir'/marginals_cat.csv", write replace
	file write cat "varname,value,freq,prop" _n

	foreach var of local allvars {
		* Check if categorical using helper
		_dm_classify_variable `var'

		if `is_categorical' {
			local vtype : type `var'
			* Get unique values
			cap qui levelsof `var', local(levels)
			if _rc != 0 {
				* Levelsof failed (too many values), skip
				continue
			}

			* Count each level
			if substr("`vtype'", 1, 3) == "str" {
				* String variable - need quotes
				foreach lev of local levels {
					qui count if `var' == "`lev'"
					local freq = r(N)
					local n_categories = `n_categories' + 1

					* PRIVACY: Suppress small cells
					if `freq' < `min_cell' {
						local n_suppressed = `n_suppressed' + 1
						continue
					}

					local prop = `freq' / _N
					file write cat "`var',`lev',`freq',`prop'" _n
				}
			}
			else {
				* Numeric variable
				foreach lev of local levels {
					qui count if `var' == `lev'
					local freq = r(N)
					local n_categories = `n_categories' + 1

					* PRIVACY: Suppress small cells
					if `freq' < `min_cell' {
						local n_suppressed = `n_suppressed' + 1
						continue
					}

					local prop = `freq' / _N
					file write cat "`var',`lev',`freq',`prop'" _n
				}
			}
		}
	}
	file close cat

	di as result "✓ marginals_cat.csv"
	if `n_suppressed' > 0 {
		di as txt "  Privacy: Suppressed `n_suppressed'/`n_categories' categories (< `min_cell' obs)"
	}

	* Rare-binary diagnostic. Gaussian copula correlations are not well
	* preserved for binary variables with prevalence below roughly 0.1;
	* regressions involving such variables may have elevated Δβ/SE after
	* rebuild. We flag these at extract time so the researcher knows
	* before they hit unexpected fidelity numbers. Threshold: 10%.
	local rare_bin_vars ""
	local n_rare_bin = 0
	foreach var of local allvars {
		_dm_classify_variable `var'
		if !`is_categorical' continue
		local vtype : type `var'
		if substr("`vtype'", 1, 3) == "str" continue

		cap qui levelsof `var', local(levels_rb)
		if _rc != 0 continue
		local nlev : word count `levels_rb'
		if `nlev' != 2 continue

		local freq_min = .
		foreach lev of local levels_rb {
			qui count if `var' == `lev' & !missing(`var')
			if r(N) < `freq_min' local freq_min = r(N)
		}
		if `freq_min' == . continue

		qui count if !missing(`var')
		local n_nonmiss = r(N)
		if `n_nonmiss' == 0 continue

		local prev = `freq_min' / `n_nonmiss'
		if `prev' < 0.10 {
			local n_rare_bin = `n_rare_bin' + 1
			local rare_bin_vars "`rare_bin_vars' `var'(p=`:di %4.3f `prev'')"
		}
	}
	if `n_rare_bin' > 0 {
		di as txt _n "  {bf:Rare-binary diagnostic}: `n_rare_bin' binary variable(s) with prevalence < 0.10:"
		di as txt "    `rare_bin_vars'"
		di as txt "  Gaussian copula may not preserve correlations involving these variables well."
		di as txt "  Regressions where they appear may show Δβ/SE > 0.3 after rebuild."
		di as txt "  See docs/SUPPORTED_MODELS.md (Known limitations) for the v1.1 copula fix path."
	}

	* Export stratified marginals if strata variable specified
	if "$dm_strata_var" != "" {
		local strata_var "$dm_strata_var"

		di as txt "Exporting stratified marginals for strata variable: `strata_var'..."

		* Get unique strata values
		qui levelsof `strata_var', local(strata_levels)

		* Export stratified continuous marginals
		file open marg_strat using "`outdir'/marginals_cont_stratified.csv", write replace
		file write marg_strat "varname,stratum"
		forval q = 0(1)100 {
			file write marg_strat ",q`q'"
		}
		file write marg_strat _n

		foreach stratum of local strata_levels {
			* PRIVACY: Skip strata below DM_MIN_CELL_SIZE before computing
			* continuous quantiles. At small N the per-stratum min and max
			* are near-single-observation statistics; this gate mirrors the
			* one on categorical stratified marginals and stratified
			* correlations. Counted in n_strata_skipped_cont.
			qui count if `strata_var' == `stratum'
			if r(N) < `min_cell' {
				local n_strata_skipped_cont = `n_strata_skipped_cont' + 1
				continue
			}

			foreach var of local allvars {
				* Skip strata variable
				if "`var'" == "`strata_var'" {
					continue
				}

				* Check if continuous using helper
				_dm_classify_variable `var'

				if !`is_categorical' {
						* Get quantiles within this stratum. Tails are
						* plateaued at DM_QUANTILE_TRIM percent (see the
						* full-sample loop above for the semantics).
						qui sum `var' if `strata_var' == `stratum', detail
						if `qtrim' > 0 {
							qui _pctile `var' if `strata_var' == `stratum', p(`qtrim')
							local v_lo = r(r1)
							qui _pctile `var' if `strata_var' == `stratum', p(`qtrim_hi')
							local v_hi = r(r1)
						}

						file write marg_strat "`var',`stratum'"
						forval q = 0(1)100 {
							if `qtrim' <= 0 & `q' == 0 {
								local val = r(min)
							}
							else if `qtrim' <= 0 & `q' == 100 {
								local val = r(max)
							}
							else if `qtrim' > 0 & `q' <= `qtrim' {
								local val = `v_lo'
							}
							else if `qtrim' > 0 & `q' >= `qtrim_hi' {
								local val = `v_hi'
							}
							else {
								qui _pctile `var' if `strata_var' == `stratum', p(`q')
								local val = r(r1)
							}

							if "`val'" == "" | "`val'" == "." {
								file write marg_strat ",NA"
							}
							else {
								file write marg_strat "," (`val')
							}
						}
						file write marg_strat _n
					}
				}
			}
		file close marg_strat
		di as result "✓ marginals_cont_stratified.csv"
		if `n_strata_skipped_cont' > 0 {
			di as txt "  Privacy: Skipped `n_strata_skipped_cont' stratum(a) with N < `min_cell' from continuous marginals"
		}

		* Export stratified categorical marginals
		file open cat_strat using "`outdir'/marginals_cat_stratified.csv", write replace
		file write cat_strat "varname,stratum,value,freq,prop" _n

		foreach stratum of local strata_levels {
			* Count observations in this stratum
			qui count if `strata_var' == `stratum'
			local n_stratum = r(N)

			foreach var of local allvars {
				* Skip the strata variable itself
				if "`var'" == "`strata_var'" {
					continue
				}

				* Check if categorical using helper
				_dm_classify_variable `var'

				if `is_categorical' {
					local vtype : type `var'
					cap qui levelsof `var' if `strata_var' == `stratum', local(levels_s)
					if _rc != 0 {
						continue
					}

					* Count each level within this stratum
					if substr("`vtype'", 1, 3) == "str" {
						foreach lev of local levels_s {
							qui count if `strata_var' == `stratum' & `var' == "`lev'"
							local freq = r(N)
							local n_categories_strat = `n_categories_strat' + 1

							* PRIVACY: Suppress small cells
							if `freq' < `min_cell' {
								local n_suppressed_strat = `n_suppressed_strat' + 1
								continue
							}

							local prop = `freq' / `n_stratum'
							file write cat_strat "`var',`stratum',`lev',`freq',`prop'" _n
						}
					}
					else {
						foreach lev of local levels_s {
							qui count if `strata_var' == `stratum' & `var' == `lev'
							local freq = r(N)
							local n_categories_strat = `n_categories_strat' + 1

							* PRIVACY: Suppress small cells
							if `freq' < `min_cell' {
								local n_suppressed_strat = `n_suppressed_strat' + 1
								continue
							}

							local prop = `freq' / `n_stratum'
							file write cat_strat "`var',`stratum',`lev',`freq',`prop'" _n
						}
					}
				}
			}
		}
		file close cat_strat
		di as result "✓ marginals_cat_stratified.csv"
		if `n_suppressed_strat' > 0 {
			di as txt "  Privacy: Suppressed `n_suppressed_strat'/`n_categories_strat' categories (< `min_cell' obs)"
		}
	}

	* Export correlations (FULL correlation matrix including categoricals)
	di as txt "Exporting correlations..."

	* Get list of ALL numeric variables (continuous + categorical)
	* We'll compute correlations on numeric representations, treating categoricals
	* as latent continuous variables (Gaussian copula approach)
	local allnumvars ""
	local skipped_vars ""
	foreach var of local allvars {
		_dm_classify_variable `var'
		* Include both continuous and categorical (numeric only, skip strings)
		local vtype : type `var'
		if substr("`vtype'", 1, 3) != "str" {
			* Check if variable is constant (only 1 unique value)
			* Use sum instead of tab to avoid "too many values" error
			qui sum `var'
			if r(min) == r(max) | (r(N) == 0) {
				local skipped_vars "`skipped_vars' `var'"
				di as txt "  Skipping constant/empty variable: `var'"
			}
			else {
				local allnumvars "`allnumvars' `var'"
			}
		}
	}

	if "`allnumvars'" != "" {
		* SEQUENTIAL RECODING FIX for high-cardinality categorical variables
		* Problem: Categorical variables with non-sequential codes (e.g., school IDs: 12211, 13211, 15111)
		* cause meaningless Pearson correlations. Solution: Recode to sequential 1,2,3,...,k before
		* computing correlations, then map back to original codes during generation.

		local allnumvars_recoded ""
		local has_recoded = 0

		foreach var of local allnumvars {
			_dm_classify_variable `var'
			local is_cat = `is_categorical'

			if `is_cat' {
				* Check cardinality (use cap to handle variables with too many values)
				cap qui tab `var'
				if _rc == 0 {
					local nlevels = r(r)
				}
				else {
					* tab failed (likely > 12,000 unique values) - assume high cardinality
					local nlevels = 99999
				}

				* Recode if high cardinality (>20 levels)
				* Rationale: zip codes, school IDs, etc. need sequential encoding for meaningful correlations
				if `nlevels' > 20 {
					if `nlevels' < 99999 {
						di as txt "  Recoding high-cardinality categorical `var' (`nlevels' levels) to sequential..."
					}
					else {
						di as txt "  Recoding very high-cardinality categorical `var' (>12,000 levels) to sequential..."
					}
					qui egen `var'_dmseq = group(`var')
					local allnumvars_recoded "`allnumvars_recoded' `var'_dmseq"
					local has_recoded = 1
				}
				else {
					local allnumvars_recoded "`allnumvars_recoded' `var'"
				}
			}
			else {
				* Continuous variable - use as-is
				local allnumvars_recoded "`allnumvars_recoded' `var'"
			}
		}

		* Compute correlation matrix using recoded variables
		* (each r(X,Y) uses observations where both X and Y are non-missing)
		* This captures continuous-continuous, continuous-categorical, and categorical-categorical associations
		local nvars : word count `allnumvars_recoded'
		di as txt "  Computing correlation matrix for `nvars' variables..."

		* Automatically increase matsize if needed
		if `nvars' > c(matsize) {
			di as txt "  Increasing matsize from `=c(matsize)' to `nvars'..."
			set matsize `nvars'
		}

		cap qui pwcorr `allnumvars_recoded', sig
		if _rc != 0 {
			di as error "  ERROR: Failed to compute correlation matrix (rc=`=_rc')"
			di as error "  Number of variables: `nvars'"
			di as error "  Current matsize: `=c(matsize)'"
			di as error ""
			di as error "  This may be due to:"
			di as error "    - Insufficient memory (try 'set max_memory .')"
			di as error "    - Variables with insufficient variation"
			di as error "    - Other matrix operation issue"
			exit _rc
		}
		matrix C = r(C)

		* Check for and impute missing correlations with 0 (independence assumption)
		* (Missing correlations occur when variables have no overlapping non-missing observations)
		local n_imputed = 0
		forval i = 1/`nvars' {
			forval j = 1/`nvars' {
				local val = C[`i', `j']
				if `val' >= . {
					* Missing correlation - impute with 0 (independence)
					if `i' == `j' {
						* Diagonal should be 1.0
						matrix C[`i', `j'] = 1.0
					}
					else {
						* Off-diagonal - assume independence
						matrix C[`i', `j'] = 0.0
						local n_imputed = `n_imputed' + 1
					}
				}
			}
		}

		if `n_imputed' > 0 {
			di as txt "  Imputed `n_imputed' missing correlations with 0 (independence assumption)"
		}

		* Export correlation matrix
		* Strip "_dmseq" suffix from recoded variable names for export
		file open corr using "`outdir'/correlations.csv", write replace
		file write corr "var1,var2,corr" _n

		forval i = 1/`nvars' {
			local var1_raw : word `i' of `allnumvars_recoded'
			local var1 : subinstr local var1_raw "_dmseq" "", all
			forval j = 1/`nvars' {
				local var2_raw : word `j' of `allnumvars_recoded'
				local var2 : subinstr local var2_raw "_dmseq" "", all
				local val = C[`i', `j']
				file write corr "`var1',`var2',`val'" _n
			}
		}
		file close corr
	}

	di as result "✓ correlations.csv (full matrix: continuous + categorical)"

	* Export stratified correlations if strata variable specified
	if "$dm_strata_var" != "" & "`allnumvars_recoded'" != "" {
		local strata_var "$dm_strata_var"

		di as txt "Exporting stratified correlations for strata variable: `strata_var'..."

		* Get unique strata values
		qui levelsof `strata_var', local(strata_levels)

		* Filter out strata variable from correlation vars (using recoded names)
		local corr_vars_recoded ""
		foreach v of local allnumvars_recoded {
			* Strip _dmseq to compare with strata_var
			local v_orig : subinstr local v "_dmseq" "", all
			if "`v_orig'" != "`strata_var'" {
				local corr_vars_recoded "`corr_vars_recoded' `v'"
			}
		}

		file open corr_strat using "`outdir'/correlations_stratified.csv", write replace
		file write corr_strat "stratum,var1,var2,corr" _n

		local n_strata_total : word count `strata_levels'
		local strat_idx = 0
		foreach stratum of local strata_levels {
			local strat_idx = `strat_idx' + 1
			if mod(`strat_idx', 10) == 0 | `strat_idx' == `n_strata_total' {
				di as txt "  [progress] stratified correlations: `strat_idx' / `n_strata_total' strata"
			}
			* PRIVACY: Check if we have enough observations in this stratum
			qui count if `strata_var' == `stratum'
			if r(N) < `min_cell' {
				* Skip strata with too few observations
				local n_strata_skipped = `n_strata_skipped' + 1
				continue
			}

			* Ensure matsize is adequate (should already be set from main correlations)
			local nvars_s : word count `corr_vars_recoded'
			if `nvars_s' > c(matsize) {
				set matsize `nvars_s'
			}

			* Compute full correlation matrix within this stratum using pairwise deletion
			cap qui pwcorr `corr_vars_recoded' if `strata_var' == `stratum', sig
			if _rc == 0 {
				matrix C_s = r(C)

				local nvars_s : word count `corr_vars_recoded'
				forval i = 1/`nvars_s' {
					local var1_raw : word `i' of `corr_vars_recoded'
					local var1 : subinstr local var1_raw "_dmseq" "", all
					forval j = 1/`nvars_s' {
						local var2_raw : word `j' of `corr_vars_recoded'
						local var2 : subinstr local var2_raw "_dmseq" "", all
						local val = C_s[`i', `j']
						file write corr_strat "`stratum',`var1',`var2',`val'" _n
					}
				}
			}
		}
		file close corr_strat
		di as result "✓ correlations_stratified.csv (full matrix: continuous + categorical)"
	}

	* Clean up temporary recoded variables (moved here AFTER stratified correlations)
	if `has_recoded' {
		foreach var of local allnumvars {
			cap drop `var'_dmseq
		}
	}

	* Export checkpoints (optional - only if checkpoints exist).
	*
	* Two files: checkpoints.csv (index, one row per tagged regression) and
	* checkpoints_coef.csv (long-format coefficient payload, one row per
	* coefficient across all checkpoints with cp_num as foreign key). This
	* replaces the earlier per-checkpoint checkpoint_<N>_coef.csv files,
	* which scaled linearly with the number of tagged regressions and made
	* the checkpoint directory hard to read when many checkpoints were set.
	if $dm_n_checkpoints > 0 {
		di as txt "Exporting checkpoints..."

		file open ckpt using "`outdir'/checkpoints.csv", write replace
		file write ckpt "cp_num,tag,cmd,cmdline,depvar,N,notes,alpha" _n

		file open coef using "`outdir'/checkpoints_coef.csv", write replace
		file write coef "cp_num,varname,coef,se" _n

		forval cp = 1/$dm_n_checkpoints {
			local tag "${dm_cp`cp'_tag}"
			local cmd "${dm_cp`cp'_cmd}"
			local cmdline "${dm_cp`cp'_cmdline}"
			local depvar "${dm_cp`cp'_depvar}"
			local N = ${dm_cp`cp'_N}
			local notes "${dm_cp`cp'_notes}"

			* nbreg stores overdispersion α; empty for all other models.
			* Persisting it here decouples rebuild from in-memory session
			* state (previously _dm_apply_checkpoint_constraints read this
			* from the ${dm_cp`cp'_alpha} global, which broke whenever
			* rebuild was called in a fresh Stata session).
			local alpha "${dm_cp`cp'_alpha}"

			* Index row (cmdline is already properly quoted).
			file write ckpt `"`cp',`tag',`cmd',"`cmdline'",`depvar',`N',`notes',`alpha'"' _n

			* Coefficient rows with cp_num foreign key.
			matrix b = dm_cp`cp'_b
			matrix V = dm_cp`cp'_V
			local varnames "${dm_cp`cp'_varnames}"

			local k = colsof(b)
			forval i = 1/`k' {
				local vn : word `i' of `varnames'
				local val = b[1, `i']
				local se = sqrt(V[`i', `i'])
				file write coef "`cp',`vn',`val',`se'" _n
			}
		}
		file close ckpt
		file close coef

		di as result "✓ checkpoints.csv"
		di as result "✓ checkpoints_coef.csv"
	}
	else {
		di as txt "No checkpoints to export (Layers 1-3 only)"
	}

	* Export metadata LAST so privacy-suppression counts from the full
	* pipeline above are persisted for audit. Reviewers reading the
	* checkpoint bundle can verify the threshold used and how many
	* cells/strata were suppressed without re-running the extract.
	*
	* schema_version tracks the on-disk file layout contract. Bump it
	* whenever readers in older releases would misinterpret a newer
	* directory (e.g. column renames, file splits, new required keys).
	local schema_version "1.0"

	di as txt _n "Exporting metadata..."

	file open meta using "`outdir'/metadata.csv", write replace
	file write meta "key,value" _n
	* Normalise datamirror_version: the template placeholder survives
	* in the dev tree (where datamirror.ado has not been through
	* export_package.py). Record "dev" in that case for audit clarity.
	* detect_installed_modules reads the *! version header from the
	* on-disk datamirror.ado — no session global needed.
	cap _rs_utils detect_installed_modules
	local dm_ver "`r(datamirror_version)'"
	if "`dm_ver'" == "{{VERSION}}" | "`dm_ver'" == "" {
		local dm_ver "dev"
	}

	file write meta "schema_version,`schema_version'" _n
	file write meta "datamirror_version,`dm_ver'" _n
	file write meta "N," (_N) _n
	file write meta "n_vars," (c(k)) _n
	file write meta "n_checkpoints," ($dm_n_checkpoints) _n
	file write meta "seed,20250118" _n
	if "$dm_strata_var" != "" {
		file write meta "strata_var,$dm_strata_var" _n
	}
	file write meta "dm_min_cell_size,`min_cell'" _n
	file write meta "dm_quantile_trim,`qtrim'" _n
	file write meta "n_cat_categories,`n_categories'" _n
	file write meta "n_cat_suppressed,`n_suppressed'" _n
	if "$dm_strata_var" != "" {
		file write meta "n_cat_categories_strat,`n_categories_strat'" _n
		file write meta "n_cat_suppressed_strat,`n_suppressed_strat'" _n
		file write meta "n_strata_skipped_corr,`n_strata_skipped'" _n
		file write meta "n_strata_skipped_cont,`n_strata_skipped_cont'" _n
	}
	file close meta

	di as result "✓ metadata.csv"

	* Write manifest.csv: one row per file in the bundle, with row
	* counts and a one-line description. The directory becomes self-
	* documenting so a reviewer can open it cold and see what is what
	* without consulting the docs. Row counts are computed by counting
	* lines in each file (minus header), using a pure-Stata file read.
	di as txt _n "Exporting manifest..."

	tempname mh
	file open `mh' using "`outdir'/manifest.csv", write replace
	file write `mh' "filename,kind,rows,description" _n

	_dm_manifest_row, outdir("`outdir'") ///
		filename("metadata.csv") kind("metadata") ///
		description("Bundle metadata: schema+module versions, N, k, suppression counts") handle(`mh')
	_dm_manifest_row, outdir("`outdir'") ///
		filename("schema.csv") kind("schema") ///
		description("Variable names, types, and classification (continuous/categorical)") handle(`mh')
	_dm_manifest_row, outdir("`outdir'") ///
		filename("marginals_cont.csv") kind("marginals_cont") ///
		description("Continuous marginals: 101-point quantile grid per variable") handle(`mh')
	_dm_manifest_row, outdir("`outdir'") ///
		filename("marginals_cat.csv") kind("marginals_cat") ///
		description("Categorical marginals: level frequencies per variable") handle(`mh')
	_dm_manifest_row, outdir("`outdir'") ///
		filename("correlations.csv") kind("correlations") ///
		description("Pairwise rank correlations for the Gaussian copula") handle(`mh')
	if "$dm_strata_var" != "" {
		_dm_manifest_row, outdir("`outdir'") ///
			filename("marginals_cont_stratified.csv") kind("marginals_cont_stratified") ///
			description("Continuous marginals within each stratum") handle(`mh')
		_dm_manifest_row, outdir("`outdir'") ///
			filename("marginals_cat_stratified.csv") kind("marginals_cat_stratified") ///
			description("Categorical marginals within each stratum") handle(`mh')
		_dm_manifest_row, outdir("`outdir'") ///
			filename("correlations_stratified.csv") kind("correlations_stratified") ///
			description("Pairwise correlations within each stratum") handle(`mh')
	}
	if $dm_n_checkpoints > 0 {
		_dm_manifest_row, outdir("`outdir'") ///
			filename("checkpoints.csv") kind("checkpoints") ///
			description("Checkpoint index: one row per tagged regression") handle(`mh')
		_dm_manifest_row, outdir("`outdir'") ///
			filename("checkpoints_coef.csv") kind("checkpoints_coef") ///
			description("Coefficient payload: one row per coefficient, cp_num foreign key") handle(`mh')
	}

	file close `mh'
	di as result "✓ manifest.csv"

	di as txt _n "══════════════════════════════════════════════════════════════"
	di as result "EXPORT COMPLETE"
	di as txt "══════════════════════════════════════════════════════════════"
	di as txt "Output directory: " as result "`outdir'/"
	di as txt "See " as result "manifest.csv" as txt " for the file listing."
end

* Helper: write one manifest row. Opens the target file fresh to count
* lines (robust against whatever state the caller is in) and appends a
* row to an already-open manifest handle. Silently skips missing files
* so callers don't have to re-check existence.
program define _dm_manifest_row
	syntax , outdir(string) filename(string) kind(string) description(string) handle(string)

	local fullpath "`outdir'/`filename'"

	cap confirm file "`fullpath'"
	if _rc != 0 {
		exit 0
	}

	tempname rh
	local nlines = 0
	file open `rh' using "`fullpath'", read
	file read `rh' line
	while r(eof) == 0 {
		local nlines = `nlines' + 1
		file read `rh' line
	}
	file close `rh'

	* Subtract the header row, guarding against empty files.
	local nrows = max(0, `nlines' - 1)

	file write `handle' `"`filename',`kind',`nrows',"`description'""' _n
end

* #############################################################################
* SECTION C: COEFFICIENT-AWARE COPULA
* -----------------------------------------------------------------------------
* adjust correlation matrix to encode checkpoint constraints (pre-sampling)
* #############################################################################


* -----------------------------------------------------------------------------
* Adjust correlation matrix to bake in checkpoint coefficients
* #############################################################################
* SECTION D: REBUILD
* -----------------------------------------------------------------------------
* copula sampling → marginal inverse transform → checkpoint refinement
* #############################################################################


* -----------------------------------------------------------------------------
* rebuild: Generate synthetic data from export
* -----------------------------------------------------------------------------
program define _dm_rebuild
	version 16.0
	syntax using/ , [clear seed(integer 12345) verify]

	if "`clear'" == "" & c(changed) {
		di as error "datamirror: rebuild would overwrite unsaved changes in memory."
		di as error "Save the current dataset first, or add the " `"'clear'"' " option:"
		di as error "    datamirror rebuild using " `""<dir>""' ", clear"
		exit 4
	}

	* Set directory
	local indir = subinstr("`using'", ".csv", "", .)

	* Check directory exists and has the expected schema.
	cap confirm file "`indir'/metadata.csv"
	if _rc != 0 {
		di as error _n "datamirror: cannot find {bf:`indir'/metadata.csv}."
		di as error "The rebuild path expects the directory produced by " `"'datamirror extract'"' "."
		di as error "Check the path, or rerun extract to regenerate the bundle."
		exit 601
	}
	cap confirm file "`indir'/schema.csv"
	if _rc != 0 {
		di as error _n "datamirror: {bf:`indir'/} is missing schema.csv."
		di as error "Bundles produced by " `"'datamirror extract'"' " always include schema.csv."
		di as error "See docs/LAYER4.md for the on-disk layout contract."
		exit 601
	}

	clear

	set seed `seed'

	di as txt _n "══════════════════════════════════════════════════════════════"
	di as result "DATAMIRROR REBUILD"
	di as txt "══════════════════════════════════════════════════════════════"

	* Read metadata first to check for stratification
	di as txt _n "Reading metadata..."

	preserve
	import delimited "`indir'/metadata.csv", varnames(1) clear stringcols(_all)
	qui levelsof value if key == "N", local(N) clean
	qui levelsof value if key == "n_vars", local(n_vars) clean
	qui levelsof value if key == "n_checkpoints", local(n_ckpts) clean

	* Check if strata_var exists in metadata
	cap confirm variable key
	if _rc == 0 {
		qui levelsof value if key == "strata_var", local(strata_var) clean
	}
	restore

	di as txt "  N = " as result "`N'"
	di as txt "  Variables = " as result "`n_vars'"
	di as txt "  Checkpoints = " as result "`n_ckpts'"

	* Check if stratified files exist and strata_var is defined
	cap confirm file "`indir'/marginals_cont_stratified.csv"
	local has_stratified = (_rc == 0)

	if `has_stratified' & "`strata_var'" != "" {
		* Call stratified rebuild
		_dm_rebuild_stratified "`indir'" `seed' "`strata_var'"
		if "`verify'" != "" {
			_dm_check using "`indir'"
		}
		exit
	}
	else if `has_stratified' & "`strata_var'" == "" {
		di as txt _n "{bf:Note:} Stratified files detected but no strata_var in metadata"
		di as txt "         Using overall statistics for rebuild"
	}

	* Read schema
	di as txt _n "Reading schema..."

	preserve
	import delimited "`indir'/schema.csv", varnames(1) clear stringcols(_all)
	tempfile schema_file
	save `schema_file', replace
	restore

	* Read marginals (continuous)
	di as txt "Reading marginal distributions (continuous)..."

	preserve
	import delimited "`indir'/marginals_cont.csv", varnames(1) clear
	tempfile marg_cont
	save `marg_cont', replace

	qui ds
	local contvars_list "`r(varlist)'"
	local contvars_list : subinstr local contvars_list "varname" "", word
	restore

	* Read marginals (categorical)
	di as txt "Reading marginal distributions (categorical)..."

	preserve
	import delimited "`indir'/marginals_cat.csv", varnames(1) clear
	tempfile marg_cat
	save `marg_cat', replace

	levelsof varname, local(catvars_list)
	restore

	* Read correlations
	di as txt "Reading correlations..."

	preserve
	import delimited "`indir'/correlations.csv", varnames(1) clear
	tempfile corr_file
	save `corr_file', replace
	restore

	* Read checkpoints (optional - only if exist)
	cap confirm file "`indir'/checkpoints.csv"
	local has_checkpoints = (_rc == 0)

	if `has_checkpoints' {
		di as txt "Reading checkpoints..."
		preserve
		import delimited "`indir'/checkpoints.csv", varnames(1) clear stringcols(_all)
		tempfile ckpt_file
		save `ckpt_file', replace
		restore
	}
	else {
		di as txt "No checkpoints found - using Layers 1-3 only"
	}

	di as result "✓ All files loaded"

	* ══════════════════════════════════════════════════════════════════════
	* STEP 0: Adjust correlations for checkpoint constraints (coefficient-aware copula)
	* Only if checkpoints exist
	* ══════════════════════════════════════════════════════════════════════

	if `has_checkpoints' {
		_dm_constraints corr_for_ckpt "`indir'" "`corr_file'" "`marg_cont'"

		* Reload adjusted correlation file
		preserve
		import delimited "`corr_file'", varnames(1) clear
		tempfile corr_file_adjusted
		save `corr_file_adjusted', replace
		restore
		local corr_file "`corr_file_adjusted'"
	}

	* ══════════════════════════════════════════════════════════════════════
	* STEP 1: Generate base synthetic data using Gaussian copula
	* ══════════════════════════════════════════════════════════════════════

	di as txt _n "══════════════════════════════════════════════════════════════"
	di as txt "STEP 1: Generating Synthetic Data (Gaussian Copula)"
	di as txt "══════════════════════════════════════════════════════════════"

	clear
	set obs `N'

	* Generate correlated normals
	local ncontvars : word count `contvars_list'
	if `ncontvars' > 0 {
		di as txt "Generating `ncontvars' correlated normal variates..."

		* Read correlation matrix
		use `corr_file', clear
		levelsof var1, local(vars)
		local nvars : word count `vars'

		* Build correlation matrix
		matrix C = I(`nvars')
		local i = 1
		foreach v1 of local vars {
			local j = 1
			foreach v2 of local vars {
				qui sum corr if var1 == "`v1'" & var2 == "`v2'"
				matrix C[`i', `j'] = r(mean)
				local j = `j' + 1
			}
			local i = `i' + 1
		}

		* Decompose: C = L L'
		matrix symeigen eigvec eigval = C

		* Generate uncorrelated normals
		clear
		set obs `N'
		forval i = 1/`nvars' {
			gen z`i' = rnormal()
		}

		* Apply correlation structure: X = Z * L
		* Simplified: use correlation matrix directly
		forval i = 1/`nvars' {
			gen xtemp`i' = 0
			forval j = 1/`nvars' {
				replace xtemp`i' = xtemp`i' + C[`i',`j'] * z`j'
			}
			* Standardize
			qui sum xtemp`i'
			replace xtemp`i' = (xtemp`i' - r(mean)) / r(sd)
		}

		* Transform to uniform [0,1]
		forval i = 1/`nvars' {
			gen u`i' = normal(xtemp`i')
			drop xtemp`i'
		}

		tempfile copula_data
		save `copula_data', replace
	}

	* ══════════════════════════════════════════════════════════════════════
	* STEP 2: Transform to match marginal distributions
	* ══════════════════════════════════════════════════════════════════════

	di as txt _n "══════════════════════════════════════════════════════════════"
	di as txt "STEP 2: Matching Marginal Distributions"
	di as txt "══════════════════════════════════════════════════════════════"

	* Get list of variables in correlation matrix
	use `corr_file', clear
	levelsof var1, local(corr_vars)

	* Generate continuous variables from quantiles
	use `marg_cont', clear
	local nrows = _N

	forval row = 1/`nrows' {
		* Load marginals to get variable info
		use `marg_cont', clear
		local vname = varname[`row']

		* Get quantile values
		forval q = 0(1)100 {
			local q`q' = q`q'[`row']
		}

		* Get is_integer flag from schema
		preserve
		use `schema_file', clear
		qui levelsof is_integer if varname == "`vname'", local(is_int) clean
		if "`is_int'" == "" {
			local is_int = 0
		}
		restore

		* Generate variable by interpolating quantiles
		use `copula_data', clear

		* Find index in correlation matrix, or generate independent uniform
		local idx = 0
		local i = 1
		foreach cv of local corr_vars {
			if "`cv'" == "`vname'" {
				local idx = `i'
			}
			local i = `i' + 1
		}

		* If variable is in correlation matrix, use corresponding u variable
		* Otherwise, generate independent uniform
		if `idx' > 0 {
			local u_var = "u`idx'"
		}
		else {
			tempvar u_temp
			gen `u_temp' = runiform()
			local u_var = "`u_temp'"
		}

		* Use uniform [0,1] to map to quantiles
		gen `vname' = .

		* Simple interpolation: map uniform to quantiles
		forval i = 1/`=_N' {
			local u_val = `u_var'[`i']
			local pct = `u_val' * 100

			* Find bracket
			local lower_q = floor(`pct')
			local upper_q = ceil(`pct')

			* Check if quantile values are NA
			if "`q`lower_q''" == "NA" | "`q`upper_q''" == "NA" {
				* Missing value - assign missing
				qui replace `vname' = . in `i'
			}
			else if `lower_q' == `upper_q' {
				local val = `q`lower_q''
				qui replace `vname' = `val' in `i'
			}
			else {
				* Linear interpolation
				local frac = `pct' - `lower_q'
				local val = `q`lower_q'' + `frac' * (`q`upper_q'' - `q`lower_q'')
				qui replace `vname' = `val' in `i'
			}
		}

		* Round to integer if original variable was integer-valued
		if "`is_int'" == "1" {
			qui replace `vname' = round(`vname')
		}

		save `copula_data', replace

		di as txt "  ✓ `vname'"
	}

	* Generate categorical variables
	use `marg_cat', clear
	levelsof varname, local(catvars)

	foreach cvar of local catvars {
		use `marg_cat', clear
		keep if varname == "`cvar'"

		* Get value-proportion pairs
		local nvals = _N
		forval i = 1/`nvals' {
			local val`i' = value[`i']
			local prop`i' = prop[`i']
		}

		* Check variable type from schema
		use `schema_file', clear
		qui levelsof type if varname == "`cvar'", local(vtype) clean
		local is_string = substr("`vtype'", 1, 3) == "str"

		use `copula_data', clear

		* Generate uniform random
		gen u_temp = runiform()

		* Assign categories based on proportions
		if `is_string' == 1 {
			* Create string variable
			gen `cvar' = ""
			local cumul = 0
			forval i = 1/`nvals' {
				local cumul = `cumul' + `prop`i''
				qui replace `cvar' = "`val`i''" if u_temp <= `cumul' & `cvar' == ""
			}
		}
		else {
			gen `cvar' = .
			local cumul = 0
			forval i = 1/`nvals' {
				local cumul = `cumul' + `prop`i''
				qui replace `cvar' = `val`i'' if u_temp <= `cumul' & missing(`cvar')
			}
		}
		drop u_temp

		save `copula_data', replace

		di as txt "  ✓ `cvar'"
	}

	* Clean up helper variables
	use `copula_data', clear

	* Drop only the temporary copula variables (z1-z101, u1-u101, u_temp)
	* xtemp variables are already dropped during copula generation
	* NOT user variables that happen to start with these letters
	qui ds
	local allvars "`r(varlist)'"
	foreach v of local allvars {
		* Drop if variable name matches pattern: z or u followed by digits only
		* DO NOT drop x followed by digits (those are user variables)
		if regexm("`v'", "^[zu][0-9]+$") | "`v'" == "u_temp" {
			drop `v'
		}
	}

	di as result _n "✓ Synthetic data generated: " _N " observations"

	* ══════════════════════════════════════════════════════════════════════
	* STEP 3: LAYER 4 - Enforce checkpoint constraints (if checkpoints exist)
	* ══════════════════════════════════════════════════════════════════════

	* Apply checkpoint constraints to match model results (only if checkpoints exist)
	if `has_checkpoints' {
		_dm_constraints apply "`indir'"
	}
	else {
		di as txt _n "Skipping Layer 4 (no checkpoints)"
	}

	* ══════════════════════════════════════════════════════════════════════
	* Summary
	* ══════════════════════════════════════════════════════════════════════

	di as txt _n "══════════════════════════════════════════════════════════════"
	di as result "REBUILD COMPLETE"
	di as txt "══════════════════════════════════════════════════════════════"

	di as txt _n "Synthetic dataset created:"
	di as txt "  Observations: " as result _N
	qui ds
	local nvars : word count `r(varlist)'
	di as txt "  Variables: " as result `nvars'

	di as txt _n "Methods used:"
	di as txt "  ✓ Gaussian copula for correlation structure"
	di as txt "  ✓ Quantile matching for marginal distributions"
	di as txt "  ✓ Categorical proportions preserved"

	if "`verify'" != "" {
		* Collapse rebuild + check into one call. Inline, not as a
		* separate subcommand, so users who do it repeatedly don't have
		* to type the output directory twice.
		_dm_check using "`indir'"
	}
end

* -----------------------------------------------------------------------------
* rebuild_stratified: Helper for stratified rebuild (basic version)
* -----------------------------------------------------------------------------
program define _dm_rebuild_stratified
	args indir seed strata_var

	di as txt _n "══════════════════════════════════════════════════════════════"
	di as txt "STRATIFIED REBUILD MODE"
	di as txt "══════════════════════════════════════════════════════════════"
	di as txt "Stratification variable: " as result "`strata_var'"

	* Read schema (needed throughout)
	preserve
	import delimited "`indir'/schema.csv", varnames(1) clear stringcols(_all)
	tempfile schema_file
	save `schema_file', replace
	restore

	* Get list of strata from stratified marginals
	preserve
	import delimited "`indir'/marginals_cont_stratified.csv", varnames(1) clear
	qui levelsof stratum, local(strata_levels)
	restore

	* If no continuous stratified marginals, try categorical
	if "`strata_levels'" == "" {
		preserve
		import delimited "`indir'/marginals_cat_stratified.csv", varnames(1) clear
		qui levelsof stratum, local(strata_levels)
		restore
	}

	local n_strata : word count `strata_levels'
	di as txt "Number of strata: " as result "`n_strata'"

	* Read overall marginals to get variable lists
	preserve
	import delimited "`indir'/marginals_cont.csv", varnames(1) clear
	qui ds
	local contvars_full "`r(varlist)'"
	local contvars_full : subinstr local contvars_full "varname" "", word
	tempfile marg_cont_overall
	save `marg_cont_overall', replace
	restore

	preserve
	import delimited "`indir'/marginals_cat.csv", varnames(1) clear
	qui levelsof varname, local(catvars_list)
	tempfile marg_cat_overall
	save `marg_cat_overall', replace
	restore

	* Initialize empty dataset for stacking
	tempfile stacked_data
	clear
	gen _placeholder = .
	save `stacked_data', replace

	* Process each stratum
	local stratum_num = 0
	foreach stratum of local strata_levels {
		local stratum_num = `stratum_num' + 1

		di as txt _n "{hline 60}"
		di as txt "Processing stratum `stratum_num'/`n_strata': " as result "`stratum'"
		di as txt "{hline 60}"

		* Get N for this stratum from stratified categorical marginals
		tempfile cat_check
		preserve
		import delimited "`indir'/marginals_cat_stratified.csv", varnames(1) clear
		qui keep if stratum == `stratum'
		local has_cat_data = (_N > 0)
		if `has_cat_data' {
			local N_stratum = freq[1] / prop[1]
			local N_stratum = round(`N_stratum')
		}
		restore

		* If no categorical data, get N from overall metadata
		if !`has_cat_data' {
			preserve
			import delimited "`indir'/metadata.csv", varnames(1) clear stringcols(_all)
			qui levelsof value if key == "N", local(N_total) clean
			restore
			local N_stratum = round(`N_total' / `n_strata')
		}

		di as txt "  N = " as result "`N_stratum'"

		* Generate data for this stratum
		* Step 1: Load stratum-specific correlations
		cap confirm file "`indir'/correlations_stratified.csv"
		local has_corr_file = (_rc == 0)

		if `has_corr_file' {
			* Load correlation data into tempfile
			tempfile corr_data
			preserve
			import delimited "`indir'/correlations_stratified.csv", varnames(1) clear
			qui keep if stratum == `stratum'
			local has_corr_data = (_N > 0)
			if `has_corr_data' {
				qui levelsof var1, local(corr_vars) clean

				* Remove strata variable from corr_vars (it's constant within strata)
				local corr_vars_filtered ""
				foreach v of local corr_vars {
					if "`v'" != "`strata_var'" {
						local corr_vars_filtered "`corr_vars_filtered' `v'"
					}
				}
				local corr_vars "`corr_vars_filtered'"
				local nvars : word count `corr_vars'

				* Filter out variables with missing correlations (KEY FIX)
				local corr_vars_valid ""
				foreach v of local corr_vars {
					* Check if this variable has valid correlation with itself
					qui sum corr if var1 == "`v'" & var2 == "`v'"
					if r(N) > 0 & !missing(r(mean)) {
						local corr_vars_valid "`corr_vars_valid' `v'"
					}
					else {
						di as txt "    Excluding `v' from correlation matrix (missing data)"
					}
				}
				local corr_vars "`corr_vars_valid'"
				local nvars : word count `corr_vars'

				* Build correlation matrix with valid variables only
				matrix C = I(`nvars')
				local i = 1
				foreach v1 of local corr_vars {
					local j = 1
					foreach v2 of local corr_vars {
						qui sum corr if var1 == "`v1'" & var2 == "`v2'"
						if r(N) > 0 & !missing(r(mean)) {
							matrix C[`i', `j'] = r(mean)
						}
						local j = `j' + 1
					}
					local i = `i' + 1
				}

				* Debug: Show correlation matrix dimensions and check for missing
				if "$DM_DEBUG" == "1" di as txt "    DEBUG: Correlation matrix is " `nvars' "×" `nvars'
				matrix list C
			}
			restore
		}
		else {
			local has_corr_data = 0
		}

		* Generate base dataset with correlations or independent
		clear
		set obs `N_stratum'

		di as txt "  has_corr_data = `has_corr_data', nvars = `nvars'"

		* Generate base normal variables
		if `has_corr_data' {
			* Generate correlated normals
			forval i = 1/`nvars' {
				qui gen z`i' = rnormal()
			}

			* Debug: Check z1
			cap qui count if !missing(z1)
			if _rc == 0 {
				if "$DM_DEBUG" == "1" di as txt "  DEBUG: z1 has " r(N) " non-missing values after generation"
			}

			* Apply correlation structure
			di as txt "  Generating x variables..."
			forval i = 1/`nvars' {
				qui gen x`i' = 0
				forval j = 1/`nvars' {
					qui replace x`i' = x`i' + C[`i',`j'] * z`j'
				}

				* Standardize (handle constant case - KEY BUG FIX)
				qui sum x`i'
				if r(sd) > 1e-10 {
					qui replace x`i' = (x`i' - r(mean)) / r(sd)
				}
				else {
					* Variable is constant within stratum - use independent normal
					qui replace x`i' = rnormal()
				}
			}
			di as txt "  ✓ x variables created"

			* Debug: Check x1 values
			cap qui count if !missing(x1)
			if _rc == 0 {
				if "$DM_DEBUG" == "1" di as txt "  DEBUG: x1 has " r(N) " non-missing values"
			}

			* Transform to uniform [0,1]
			di as txt "  Generating u variables..."
			forval i = 1/`nvars' {
				qui gen u`i' = normal(x`i')
			}
			di as txt "  ✓ u variables created"

			* Debug: Check u1 values
			cap qui count if !missing(u1)
			if _rc == 0 {
				if "$DM_DEBUG" == "1" di as txt "  DEBUG: u1 has " r(N) " non-missing values after creation"
			}
		}
		else {
			* No correlation data - generate independent normals and uniforms
			local nvars : word count `corr_vars'
			if `nvars' > 0 {
				forval i = 1/`nvars' {
					qui gen z`i' = rnormal()
					qui gen u`i' = normal(z`i')
				}
			}
			else {
				local corr_vars ""
			}
		}

		tempfile copula_stratum
		save `copula_stratum', replace

		* Debug: check initial copula
		qui ds
		di as txt "    Initial copula after creation: `r(varlist)'"

		* Debug: Check if u variables have values in initial copula
		cap confirm variable u1
		if _rc == 0 {
			qui count if !missing(u1)
			if "$DM_DEBUG" == "1" di as txt "    DEBUG (initial copula): u1 has " r(N) " non-missing values"
			qui sum u1
			if "$DM_DEBUG" == "1" di as txt "    DEBUG: u1 range = [" r(min) ", " r(max) "]"
		}
		else {
			if "$DM_DEBUG" == "1" di as txt "    DEBUG: u1 does not exist in initial copula"
		}

		* Step 2: Generate continuous variables from stratum-specific quantiles
		cap confirm file "`indir'/marginals_cont_stratified.csv"
		if _rc == 0 {
			* Extract ALL continuous variable info into locals FIRST (outside the copula)
			preserve
			import delimited "`indir'/marginals_cont_stratified.csv", varnames(1) clear
			qui keep if stratum == `stratum'
			local nrows = _N

			if `nrows' > 0 {
				* Store all variable names
				qui levelsof varname, local(contvars_stratum) clean

				* Read integer flags from schema
				tempfile marg_temp
				qui save `marg_temp'
				use `schema_file', clear
				forval row = 1/`nrows' {
					use `marg_temp', clear
					local vname = varname[`row']
					use `schema_file', clear
					qui levelsof is_integer if varname == "`vname'", local(is_int_`row') clean
					if "`is_int_`row''" == "" {
						local is_int_`row' = 0
					}
				}
				use `marg_temp', clear

				* For each continuous variable, extract all quantile values into locals
				forval row = 1/`nrows' {
					local vname = varname[`row']
					local vname_`row' "`vname'"

					* Store all quantiles for this variable
					forval q = 0(1)100 {
						local q`q'_`row' = q`q'[`row']
					}
				}
			}
			restore

			* Now load copula ONCE and generate ALL continuous variables in memory
			if `nrows' > 0 {
				use `copula_stratum', clear

				* Debug: Check if u variables have values BEFORE continuous generation
				cap confirm variable u1
				if _rc == 0 {
					qui count if !missing(u1)
					if "$DM_DEBUG" == "1" di as txt "    DEBUG (before cont gen): u1 has " r(N) " non-missing values"
					qui sum u1
					if "$DM_DEBUG" == "1" di as txt "    DEBUG: u1 range = [" r(min) ", " r(max) "]"
				}

				di as txt "    Generating " as result "`nrows'" as txt " continuous variables..."

				forval row = 1/`nrows' {
					local vname "`vname_`row''"
					di as txt "      - `vname' (`row'/`nrows')"

					* Find index in correlation matrix
					local idx = 0
					local i = 1
					foreach cv of local corr_vars {
						if "`cv'" == "`vname'" {
							local idx = `i'
						}
						local i = `i' + 1
					}

					* Get uniform variable
					if `idx' > 0 {
						local u_var = "u`idx'"
					}
					else {
						tempvar u_temp
						qui gen `u_temp' = runiform()
						local u_var = "`u_temp'"
					}

					* Map uniform to quantiles using vectorized approach
					qui gen `vname' = .

					* For each observation, map uniform value to quantile
					qui gen double __pct = `u_var' * 100
					qui gen int __lower_q = floor(__pct)
					qui gen int __upper_q = ceil(__pct)

					* Handle cases where quantiles are NA
					forval q = 0(1)100 {
						if "`q`q'_`row''" != "NA" {
							qui replace `vname' = `q`q'_`row'' if __lower_q == `q' & __upper_q == `q'
						}
					}

					* Linear interpolation for in-between values
					forval q = 0(1)99 {
						local q_next = `q' + 1
						if "`q`q'_`row''" != "NA" & "`q`q_next'_`row''" != "NA" {
							qui replace `vname' = `q`q'_`row'' + (__pct - `q') * (`q`q_next'_`row'' - `q`q'_`row'') ///
								if __lower_q == `q' & __upper_q == `q_next' & missing(`vname')
						}
					}

					* Round to integer if original variable was integer-valued
					if "`is_int_`row''" == "1" {
						qui replace `vname' = round(`vname')
					}

					qui drop __pct __lower_q __upper_q
				}

				* Save ONCE after all continuous variables generated
				qui save `copula_stratum', replace

				* Debug: check what's in copula after continuous generation
				qui ds
				di as txt "    After continuous gen, copula has: `r(varlist)'"

				* Debug: Check if u variables have values
				cap confirm variable u1
				if _rc == 0 {
					qui count if !missing(u1)
					if "$DM_DEBUG" == "1" di as txt "    DEBUG: u1 has " r(N) " non-missing values"
				}
				cap confirm variable u2
				if _rc == 0 {
					qui count if !missing(u2)
					if "$DM_DEBUG" == "1" di as txt "    DEBUG: u2 has " r(N) " non-missing values"
				}
			}
		}

		* Step 3: Generate categorical variables from stratum-specific frequencies
		* NOTE: Do NOT clean up u variables yet - we need them for categorical generation!
		cap confirm file "`indir'/marginals_cat_stratified.csv"
		if _rc == 0 {
			* Load categorical marginals for this stratum into tempfile (NOT using preserve/restore)
			tempfile cat_marg_strat
			preserve
			import delimited "`indir'/marginals_cat_stratified.csv", varnames(1) clear
			qui keep if stratum == `stratum'
			local has_cat_vars = (_N > 0)

			if `has_cat_vars' {
				qui levelsof varname, local(catvars_stratum)
				save `cat_marg_strat', replace
			}
			restore

			* Extract all variable info into locals (do this AFTER restore so locals persist!)
			if `has_cat_vars' {
				di as txt "    Generating " as result `: word count `catvars_stratum'' as txt " categorical variables..."

				preserve
				use `cat_marg_strat', clear

				foreach cvar of local catvars_stratum {
					* Skip strata variable itself
					if "`cvar'" == "`strata_var'" {
						continue
					}

					* Get value-proportion pairs by iterating through rows
					qui count if varname == "`cvar'"
					local nvals_`cvar' = r(N)

					local row_num = 0
					forval obs = 1/`=_N' {
						if varname[`obs'] == "`cvar'" {
							local row_num = `row_num' + 1
							local val_`cvar'_`row_num' = value[`obs']
							local prop_`cvar'_`row_num' = prop[`obs']
						}
					}
				}

				* Also get variable types from schema while we're at it
				import delimited "`indir'/schema.csv", varnames(1) clear stringcols(_all)
				foreach cvar of local catvars_stratum {
					if "`cvar'" != "`strata_var'" {
						qui levelsof type if varname == "`cvar'", local(vtype_`cvar') clean
					}
				}

				restore
			}

			* Now load copula ONCE and generate ALL categorical variables
			if `has_cat_vars' {
				use `copula_stratum', clear

				* Debug: check what variables exist in copula
				qui ds
				local copula_vars "`r(varlist)'"
				if "$DM_DEBUG" == "1" di as txt "    Variables in copula: `copula_vars'"

				* Debug: Check if u variables have values after loading
				cap confirm variable u1
				if _rc == 0 {
					qui count if !missing(u1)
					if "$DM_DEBUG" == "1" di as txt "    DEBUG (after load): u1 has " r(N) " non-missing values"
				}
				cap confirm variable u2
				if _rc == 0 {
					qui count if !missing(u2)
					if "$DM_DEBUG" == "1" di as txt "    DEBUG (after load): u2 has " r(N) " non-missing values"
				}

				foreach cvar of local catvars_stratum {
					* Skip strata variable itself
					if "`cvar'" == "`strata_var'" {
						continue
					}
					di as txt "      - `cvar' (nvals=`nvals_`cvar'')"

					* Debug: show first value/prop
					if `nvals_`cvar'' > 0 {
						if "$DM_DEBUG" == "1" di as txt "        val1=`val_`cvar'_1', prop1=`prop_`cvar'_1'"
					}

					* Find index in correlation matrix (if correlated)
					local idx = 0
					local i = 1
					foreach cv of local corr_vars {
						if "`cv'" == "`cvar'" {
							local idx = `i'
						}
						local i = `i' + 1
					}

					* Get uniform variable - use correlated if available, otherwise independent
					if `idx' > 0 {
						local u_var = "u`idx'"
						qui gen u_temp = `u_var'
						if "$DM_DEBUG" == "1" di as txt "        Using correlated u`idx'"
					}
					else {
						qui gen u_temp = runiform()
						if "$DM_DEBUG" == "1" di as txt "        Using independent runiform()"
					}

					* Debug: check u_temp
					qui count if !missing(u_temp)
					di as txt "        u_temp has " as result r(N) as txt " non-missing values"

					* Check if string type
					local is_string = substr("`vtype_`cvar''", 1, 3) == "str"

					* Assign categories based on proportions
					if `is_string' == 1 {
						qui gen `cvar' = ""
						local cumul = 0
						forval i = 1/`nvals_`cvar'' {
							local cumul = `cumul' + `prop_`cvar'_`i''

							* Always respect cumulative threshold to preserve missing values
							* If proportions intentionally don't sum to 1.0, observations with
							* u_temp > cumul will correctly remain missing
							qui replace `cvar' = "`val_`cvar'_`i''" if u_temp <= `cumul' & `cvar' == ""
						}
					}
					else {
						qui gen `cvar' = .
						local cumul = 0
						forval i = 1/`nvals_`cvar'' {
							local cumul = `cumul' + `prop_`cvar'_`i''
							local thisval = `val_`cvar'_`i''

							* Always respect cumulative threshold to preserve missing values
							* If proportions intentionally don't sum to 1.0, observations with
							* u_temp > cumul will correctly remain missing
							qui replace `cvar' = `thisval' if u_temp <= `cumul' & missing(`cvar')
						}
					}
					qui drop u_temp

					* Debug: check if variable has values
					qui count if !missing(`cvar')
					local n_nonmiss = r(N)
					if "$DM_DEBUG" == "1" di as txt "        → `n_nonmiss' non-missing values"
				}

				* Save copula ONCE after all categorical variables generated
				qui save `copula_stratum', replace
			}
		}

		* Step 4: Add strata variable
		* Check strata variable type from schema
		use `schema_file', clear
		qui levelsof type if varname == "`strata_var'", local(strata_type) clean
		local is_string = substr("`strata_type'", 1, 3) == "str"

		* Generate strata variable in copula dataset
		use `copula_stratum', clear

		if `is_string' == 1 {
			qui gen `strata_var' = "`stratum'"
		}
		else {
			qui gen `strata_var' = `stratum'
		}

		* Clean up temporary correlation variables (numbered only: z1, x1, u1, etc.)
		qui ds
		local all_vars "`r(varlist)'"
		local drop_vars ""
		foreach v of local all_vars {
			* Only drop if variable name is z/x/u followed by a number
			if regexm("`v'", "^[zxu][0-9]+$") {
				local drop_vars "`drop_vars' `v'"
			}
		}
		if "`drop_vars'" != "" {
			qui drop `drop_vars'
		}

		qui save `copula_stratum', replace

		* Debug: show what variables exist
		qui ds
		local vars_in_copula "`r(varlist)'"
		if "$DM_DEBUG" == "1" di as txt "    Variables in copula_stratum: " as result "`: word count `vars_in_copula''"

		di as txt "  ✓ Generated `N_stratum' observations for stratum `stratum'"

		* Append to stacked dataset
		use `stacked_data', clear
		cap drop _placeholder
		qui ds
		di as txt "    Variables in stacked_data before append: " as result "`: word count `r(varlist)''"
		append using `copula_stratum'
		qui ds
		di as txt "    Variables in stacked_data after append: " as result "`: word count `r(varlist)''"
		save `stacked_data', replace
	}

	* Load final stacked dataset
	use `stacked_data', clear
	cap drop _placeholder

	* Fallback for sparse categorical variables: generate from overall marginal.
	* When a categorical variable has mostly-missing values, extract can end up
	* with zero rows in marginals_cat_stratified.csv for it, so the stratified
	* loop above silently skips the variable. If such a variable is needed by
	* a checkpoint regression, Layer 4 would then error with r(111). We close
	* that gap by checking which schema-listed variables are still absent and
	* generating them from marginals_cat.csv (the non-stratified overall
	* distribution) as a best-effort fallback.
	cap confirm file "`indir'/marginals_cat.csv"
	if _rc == 0 {
		qui ds
		local existing_vars "`r(varlist)'"

		preserve
		qui use `schema_file', clear
		qui levelsof varname, local(schema_vars) clean
		restore

		foreach v of local schema_vars {
			if "`v'" == "`strata_var'" continue
			local pos : list posof "`v'" in existing_vars
			if `pos' > 0 continue

			* Read overall marginal for this variable.
			preserve
			qui import delimited "`indir'/marginals_cat.csv", varnames(1) clear
			qui keep if varname == "`v'"
			local nrows_fb = _N
			if `nrows_fb' > 0 {
				forval r = 1/`nrows_fb' {
					local fb_val_`r' = value[`r']
					local fb_prop_`r' = prop[`r']
				}
			}
			restore

			* Look up type to decide string vs numeric generation.
			preserve
			qui use `schema_file', clear
			qui levelsof type if varname == "`v'", local(vtype) clean
			restore
			local is_string = substr("`vtype'", 1, 3) == "str"

			if `nrows_fb' == 0 {
				* Not in overall marginal either; fill with missing.
				if `is_string' {
					qui gen `v' = ""
				}
				else {
					qui gen `v' = .
				}
				if "$DM_DEBUG" == "1" di as txt "    Fallback (missing marginal): `v' = ."
				continue
			}

			tempvar u_fb
			qui gen `u_fb' = runiform()
			if `is_string' {
				qui gen `v' = ""
				local cumul = 0
				forval r = 1/`nrows_fb' {
					local cumul = `cumul' + `fb_prop_`r''
					qui replace `v' = "`fb_val_`r''" if `u_fb' <= `cumul' & `v' == ""
				}
			}
			else {
				qui gen `v' = .
				local cumul = 0
				forval r = 1/`nrows_fb' {
					local cumul = `cumul' + `fb_prop_`r''
					qui replace `v' = `fb_val_`r'' if `u_fb' <= `cumul' & missing(`v')
				}
			}
			qui drop `u_fb'
			if "$DM_DEBUG" == "1" di as txt "    Fallback (overall marginal): generated `v' from `nrows_fb' levels"
		}
	}

	* LAYER 4: Apply checkpoint constraints
	_dm_constraints apply "`indir'"

	* Debug: check final dataset
	qui ds
	local final_vars "`r(varlist)'"
	di as txt _n "══════════════════════════════════════════════════════════════"
	di as result "STRATIFIED REBUILD COMPLETE (WITH CHECKPOINT CONSTRAINTS)"
	di as txt "══════════════════════════════════════════════════════════════"
	di as txt "Total observations: " as result _N
	di as txt "Strata: " as result "`n_strata'"
	di as txt "Variables: " as result "`: word count `final_vars''"

end

* #############################################################################
* SECTION E: LAYER 4 CONSTRAINT SOLVERS
* -----------------------------------------------------------------------------
* per-model iterative coefficient-matching (OLS / FE / IV / logit / probit / poisson / nbreg)
* #############################################################################

* =============================================================================
* DataMirror: Layer 4 - Checkpoint Constraint Enforcement
* Apply checkpoint constraints to synthetic data
* =============================================================================

* -----------------------------------------------------------------------------
* Apply checkpoint constraints to adjust synthetic data
* Input: Current synthetic data, checkpoint specifications
* Output: Adjusted data where running models gives β ≈ β_original
* -----------------------------------------------------------------------------
* OLS Model Adjuster (Modular)

* -----------------------------------------------------------------------------
* Fixed Effects Model Adjuster (Modular)

* -----------------------------------------------------------------------------
* IV Model Adjuster (Modular)
* Adjusts endogenous variables AND instruments to maintain instrument validity

* #############################################################################
* SECTION F: VALIDATION
* -----------------------------------------------------------------------------
* post-rebuild fidelity check: marginals, correlations, checkpoint β
* #############################################################################


* -----------------------------------------------------------------------------
* check: Validate synthetic data fidelity
* -----------------------------------------------------------------------------
program define _dm_check
	version 16.0
	syntax using/ , [detail]

	* Set directory
	local indir = subinstr("`using'", ".csv", "", .)

	* Check directory exists
	cap confirm file "`indir'/metadata.csv"
	if _rc != 0 {
		di as error "Cannot find `indir'/metadata.csv"
		exit 601
	}

	di as txt _n "══════════════════════════════════════════════════════════════"
	di as result "DATAMIRROR CHECK - Fidelity Validation"
	di as txt "══════════════════════════════════════════════════════════════"

	* Read checkpoints (optional)
	cap confirm file "`indir'/checkpoints.csv"
	local has_checkpoints = (_rc == 0)

	if `has_checkpoints' {
		preserve
		import delimited "`indir'/checkpoints.csv", varnames(1) clear stringcols(_all)
		local n_ckpts = _N
		tempfile ckpts
		save `ckpts', replace
		restore

		* Load consolidated coefficients once (cp_num foreign key)
		tempfile all_coef_file
		preserve
		import delimited "`indir'/checkpoints_coef.csv", varnames(1) clear
		save `all_coef_file', replace
		restore

		di as txt _n "Found `n_ckpts' checkpoints to validate"
	}
	else {
		local n_ckpts = 0
		di as txt _n "No checkpoints found - checking Layers 1-3 only"
	}

	* Save current data for checkpoint validation
	tempfile orig_data
	save `orig_data', replace

	* Check if stratification was used
	preserve
	import delimited "`indir'/metadata.csv", varnames(1) clear stringcols(_all)
	qui count if key == "strata_var"
	local has_strata = (r(N) > 0)
	if `has_strata' {
		qui keep if key == "strata_var"
		local strata_var = value[1]
		local strata_var = strtrim("`strata_var'")
	}
	restore

	* Validate stratification if used
	if `has_strata' & "`strata_var'" != "" {
		di as txt _n "══════════════════════════════════════════════════════════════"
		di as result "STRATIFICATION VALIDATION"
		di as txt "══════════════════════════════════════════════════════════════"
		di as txt "Stratification variable: " as result "`strata_var'"

		* Get strata levels from current data
		qui levelsof `strata_var', local(strata_levels)
		local n_strata : word count `strata_levels'
		di as txt "Number of strata: " as result "`n_strata'"

		* Load stratified marginals into tempfile
		cap confirm file "`indir'/marginals_cont_stratified.csv"
		local has_cont_strat = (_rc == 0)

		if `has_cont_strat' {
			tempfile cont_strat_marg
			preserve
			import delimited "`indir'/marginals_cont_stratified.csv", varnames(1) clear
			save `cont_strat_marg', replace
			restore
		}

		* Load categorical marginals into tempfile
		tempfile cat_strat_marg
		cap confirm file "`indir'/marginals_cat_stratified.csv"
		if _rc == 0 {
			preserve
			import delimited "`indir'/marginals_cat_stratified.csv", varnames(1) clear
			save `cat_strat_marg', replace
			restore
		}

		* Validate continuous marginals by stratum
		if `has_cont_strat' {
			di as txt _n "Validating continuous marginals by stratum..."

			foreach stratum of local strata_levels {
				di as txt _n "  Stratum `stratum':"

				* Get variables for this stratum
				preserve
				use `cont_strat_marg', clear
				qui keep if stratum == `stratum'
				qui levelsof varname, local(cont_vars_strat) clean
				local nrows = _N

				* For each variable, get expected median
				if `nrows' > 0 {
					local all_good = 1
					foreach vname of local cont_vars_strat {
						if "`vname'" == "`strata_var'" {
							continue
						}

						* Get expected median
						qui sum q50 if varname == "`vname'"
						local exp_median = r(mean)

						* Get observed median
						use `orig_data', clear
						qui keep if `strata_var' == `stratum'
						qui sum `vname', detail
						local obs_median = r(p50)

						* Calculate relative difference
						if abs(`exp_median') > 0.001 {
							local rel_diff = abs((`obs_median' - `exp_median') / `exp_median')
						}
						else {
							local rel_diff = abs(`obs_median' - `exp_median')
						}

						* Report
						if `rel_diff' < 0.05 {
							di as txt "    ✓ `vname': median = " %8.3f `obs_median' " (exp: " %8.3f `exp_median' ")"
						}
						else {
							di as error "    ✗ `vname': median = " %8.3f `obs_median' " (exp: " %8.3f `exp_median' ") - diff = " %5.1f `rel_diff'*100 "%"
							local all_good = 0
						}

						* Return to marginals data
						use `cont_strat_marg', clear
						qui keep if stratum == `stratum'
					}

					if `all_good' {
						di as result "    Overall: ✓ All marginals match"
					}
					else {
						di as error "    Overall: ⚠ Some marginals deviate"
					}
				}
				restore
			}
		}

		* Validate strata sample sizes
		di as txt _n "Validating stratum sample sizes..."
		cap confirm file "`indir'/marginals_cat_stratified.csv"
		if _rc == 0 {
			preserve
			cap use `cat_strat_marg', clear
			if _rc == 0 {
				cap qui keep if varname == "`strata_var'"
				if _rc == 0 {
					local has_strata_data = (_N > 0)
				}
				else {
					local has_strata_data = 0
				}

				if `has_strata_data' {
					foreach stratum of local strata_levels {
						cap qui sum freq if stratum == `stratum'
						if _rc == 0 & r(N) > 0 {
							local exp_N = r(mean)

							* Get observed N
							use `orig_data', clear
							qui count if `strata_var' == `stratum'
							local obs_N = r(N)

							if `obs_N' == `exp_N' {
								di as txt "  Stratum `stratum': N = " as result `obs_N' as txt " ✓"
							}
							else {
								di as error "  Stratum `stratum': N = `obs_N' (expected `exp_N') ✗"
							}

							* Return to marginals data
							use `cat_strat_marg', clear
							qui keep if varname == "`strata_var'"
						}
					}
				}
				else {
					di as txt "  (No categorical data available for sample size validation)"
				}
			}
			else {
				di as txt "  (Unable to load categorical marginals)"
			}
			restore
		}
	}

	* Validate each checkpoint (only if checkpoints exist)
	if `has_checkpoints' {
	forval cp = 1/`n_ckpts' {
		use `ckpts', clear
		local tag = tag[`cp']
		local cmd = cmd[`cp']
		local cmdline = cmdline[`cp']
		local depvar = depvar[`cp']
		local orig_N = n[`cp']

		* Read original coefficients (filter consolidated file by cp_num)
		preserve
		use `all_coef_file', clear
		qui keep if cp_num == `cp'
		qui drop cp_num
		local ncoefs = _N
		tempfile orig_coefs
		save `orig_coefs', replace
		restore

		di as txt _n "─────────────────────────────────────────────────────────────"
		di as txt "Checkpoint `cp': " as result "`tag'"
		di as txt "─────────────────────────────────────────────────────────────"

		* Use stored cmdline if available (preserves fixed effects, clustered SEs, etc.)
		if "`cmdline'" != "" & "`cmdline'" != "." {
			* Use the full cmdline including if/in qualifiers
			* This ensures Layer 4 optimizes for the same conditional regression as the checkpoint
			local model_spec "`cmdline'"

			di as txt "  Command: " as result "`model_spec'"

			* Load synthetic data and run model
			use `orig_data', clear
			cap `model_spec'
			local run_rc = _rc
		}
		else {
			* Fallback: Reconstruct regression command from coefficient names
			di as txt "  Note: cmdline not available, reconstructing from coefficients"
			use `orig_coefs', clear

		* Get predictor variables (exclude _cons).
		* Interactions with # are not normalised here; we handle simple
		* factor prefixes (1b., 2., i.) only. Compound interactions fall
		* back to whatever Stata put in the e(b) colname.
		local predictors ""
		forval i = 1/`ncoefs' {
			local vn = varname[`i']
			if "`vn'" != "_cons" {
				if strpos("`vn'", ".") > 0 {
					* Factor variable: extract base name after the first
					* dot, add as i.base. Token-wise membership check;
					* strpos on a flat string false-positives when a name
					* is a substring of another (e.g. `id' in `pid').
					local base_var = substr("`vn'", strpos("`vn'", ".") + 1, .)
					local pos_factor : list posof "i.`base_var'" in predictors
					local pos_plain  : list posof "`base_var'"    in predictors
					if `pos_factor' == 0 & `pos_plain' == 0 {
						local predictors `predictors' i.`base_var'
					}
				}
				else {
					* Plain variable.
					local pos : list posof "`vn'" in predictors
					if `pos' == 0 {
						local predictors `predictors' `vn'
					}
				}
			}
		}

			* Clean up predictor list
			local predictors = strtrim("`predictors'")

			di as txt "  Command: " as result "`cmd' `depvar' `predictors'"

			* Load the synthetic data before running regression
			use `orig_data', clear

			* Run regression on current (synthetic) data
			cap `cmd' `depvar' `predictors'
			local run_rc = _rc
		}

		if `run_rc' != 0 {
			di as error "  Failed to run regression (error `run_rc')"
			continue
		}

		* Compare coefficients
		matrix synth_b = e(b)

		di as txt _n "  Coefficient Comparison:"
		di as txt "  {hline 60}"
		di as txt "  Variable" _col(25) "Original" _col(40) "Synthetic" _col(55) "Δ"
		di as txt "  {hline 60}"

		scalar max_delta = 0

		use `orig_coefs', clear
		forval i = 1/`ncoefs' {
			local vn = varname[`i']
			local orig = coef[`i']

			* Find matching coefficient in synthetic results
			local found = 0
			local ncols = colsof(synth_b)
			forval j = 1/`ncols' {
				local colname : word `j' of `: colnames synth_b'
				if "`colname'" == "`vn'" {
					local synth = synth_b[1, `j']
					local found = 1
					continue, break
				}
			}

			if `found' {
				local delta = abs(`synth' - `orig')
				if `delta' > max_delta {
					scalar max_delta = `delta'
				}

				di as txt "  `vn'" _col(25) %8.4f `orig' _col(40) %8.4f `synth' _col(55) %8.4f `delta'
			}
			else {
				di as txt "  `vn'" _col(25) %8.4f `orig' _col(40) "(missing)" _col(55) "-"
			}
		}

		di as txt "  {hline 60}"
		di as txt "  Max |Δβ| = " as result %6.4f max_delta

		* Evaluate fidelity
		if max_delta < 0.01 {
			di as result "  ✓ EXCELLENT (Δβ < 0.01)"
		}
		else if max_delta < 0.05 {
			di as result "  ✓ GOOD (Δβ < 0.05)"
		}
		else if max_delta < 0.10 {
			di as txt "  ⚠ ACCEPTABLE (Δβ < 0.10)"
		}
		else {
			di as error "  ✗ POOR (Δβ > 0.10)"
		}
	}
	}  // end if has_checkpoints

	di as txt _n "══════════════════════════════════════════════════════════════"
	di as result "VALIDATION COMPLETE"
	di as txt "══════════════════════════════════════════════════════════════"
end

