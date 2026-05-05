* =============================================================================
* RegiStream DataMirror: Coefficient Adjustment Engines
* -----------------------------------------------------------------------------
* Layer 4 of the architecture: make synthetic data reproduce checkpoint
* regression coefficients. Two families of adjustment live here.
*
*   Pre-sampling (copula adjustment):
*     _dm_constrain_correlations  Modify the correlation matrix before Gaussian
*                               copula sampling so the sampled X,Y carry the
*                               target β by construction (to leading order).
*
*   Post-sampling (outcome adjustment):
*     _dm_apply_checkpoint_constraints   Front-door dispatcher. Reads
*                                        checkpoints.csv + per-checkpoint coef
*                                        CSVs, routes each checkpoint to the
*                                        right engine based on e(cmd).
*
*     _dm_constrain_ols            regress: y += lambda * Delta_beta * (x - xbar)
*     _dm_constrain_fe             reghdfe: same as OLS but respects the
*                               estimation sample after singleton-dropping
*     _dm_constrain_iv             ivregress: adjusts y via instruments Z, not
*                               endogenous X, to preserve instrument validity
*     _dm_constrain_nonlinear      logit/probit/poisson/nbreg: unified
*                               gradient-descent engine with factor-variable
*                               swapping for binary outcomes and α-constraint
*                               for nbreg
*     _dm_constrain_logit / _probit / _poisson / _nbreg
*                               Thin wrappers that call _dm_constrain_nonlinear
*                               with the model_type argument.
* =============================================================================

* -----------------------------------------------------------------------------
* Dispatcher: single externally-callable entry point for the adjusters file.
* Stata auto-loads an ado by filename matching the program name; having
* _dm_constraints here lets the whole file (with all its sub-programs) register
* when any adjuster is invoked. Mirrors autolabel's _al_utils pattern.
*
* Usage:
*   _dm_constraints corr_for_ckpt  indir corr_file marg_cont
*   _dm_constraints apply          indir outdir [n_passes]
* -----------------------------------------------------------------------------
program define _dm_constraints, rclass
	version 16.0

	gettoken subcmd 0 : 0, parse(" ,")

	if ("`subcmd'" == "corr_for_ckpt") {
		_dm_constrain_correlations `0'
		return add
	}
	else if ("`subcmd'" == "apply") {
		_dm_apply_checkpoint_constraints `0'
		return add
	}
	else {
		di as error "Invalid _dm_constraints subcommand: `subcmd'"
		di as error "Valid subcommands: corr_for_ckpt, apply"
		exit 198
	}
end

* -----------------------------------------------------------------------------
program define _dm_constrain_correlations
	args indir corr_file marg_cont

	* Check if checkpoints exist
	cap confirm file "`indir'/checkpoints.csv"
	if _rc != 0 {
		di as txt "  No checkpoints found - using original correlations"
		exit
	}

	di as txt _n "{hline 60}"
	di as result "COEFFICIENT-AWARE COPULA: Encoding checkpoint constraints"
	di as txt "{hline 60}"

	* Step 1: Gather all information first (deferred execution approach)
	* Get variable list from correlation matrix
	use "`corr_file'", clear
	levelsof var1, local(all_vars) clean
	local nvars : word count `all_vars'
	di as txt "Variables: `all_vars'"
	di as txt "Original correlation matrix: `nvars' x `nvars'"

	* Get standard deviations from marginals
	di as txt "Reading marginals for SD computation..."
	preserve
	qui use "`marg_cont'", clear
	di as txt "  Loaded `=_N' variables"
	local n_marginals = _N
	forval i = 1/`n_marginals' {
		local vname = varname[`i']
		local q25 = q25[`i']
		local q75 = q75[`i']
		local iqr = `q75' - `q25'
		local sd_`vname' = `iqr' / 1.349
		di as txt "    `vname': SD = " %6.3f `sd_`vname''
	}
	restore
	di as txt "  ✓ Computed SDs for `n_marginals' variables"

	* Get checkpoint information
	preserve
	import delimited "`indir'/checkpoints.csv", varnames(1) clear stringcols(_all)
	local n_ckpts = _N
	forval cp = 1/`n_ckpts' {
		local cp_id_`cp' = cp_num[`cp']
		local cp_depvar_`cp' = depvar[`cp']
		local cp_cmd_`cp' = cmd[`cp']
	}
	restore

	* Step 2: Write adjustment script to temp .do file
	tempname script
	tempfile scriptfile
	file open `script' using "`scriptfile'", write replace

	file write `script' `"* Auto-generated correlation adjustment script"' _n
	file write `script' `"* Load correlation matrix"' _n
	file write `script' `"use "`corr_file'", clear"' _n
	file write `script' `""' _n

	file write `script' `"* Build matrix R"' _n
	file write `script' `"local nvars = `nvars'"' _n
	file write `script' `"matrix R = I(`nvars')"' _n
	file write `script' `"local all_vars `all_vars'"' _n
	file write `script' `""' _n

	file write `script' `"local i = 1"' _n
	file write `script' `"foreach v1 of local all_vars {"' _n
	file write `script' `"    local j = 1"' _n
	file write `script' `"    foreach v2 of local all_vars {"' _n
	file write `script' `"        qui sum corr if var1 == "\`v1'" & var2 == "\`v2'""' _n
	file write `script' `"        matrix R[\`i', \`j'] = r(mean)"' _n
	file write `script' `"        local j = \`j' + 1"' _n
	file write `script' `"    }"' _n
	file write `script' `"    local i = \`i' + 1"' _n
	file write `script' `"}"' _n
	file write `script' `""' _n

	* Load consolidated coefficients once (long format, cp_num foreign key)
	tempfile all_coef_file
	local have_coef_file = 0
	cap confirm file "`indir'/checkpoints_coef.csv"
	if _rc == 0 {
		preserve
		qui import delimited "`indir'/checkpoints_coef.csv", varnames(1) clear stringcols(_all)
		qui save `all_coef_file', replace
		restore
		local have_coef_file = 1
	}

	* Process each checkpoint
	forval cp = 1/`n_ckpts' {
		local cp_id = `cp_id_`cp''
		local cp_depvar = "`cp_depvar_`cp''"
		local cp_cmd = "`cp_cmd_`cp''"

		if inlist("`cp_cmd'", "regress", "reghdfe") {
			di as txt "  Checking checkpoint `cp': `cp_depvar' (cmd: `cp_cmd')"
			if `have_coef_file' {
				* Read coefficients (filter consolidated file by cp_num)
				di as txt "    Loading coefficients..."
				preserve
				qui use `all_coef_file', clear
				qui keep if cp_num == "`cp_id'"
				di as txt "    Loaded `=_N' coefficients"

				* Extract ALL coefficient info before restoring
				local predictors ""
				local n_pred = 0
				local n_coefs = _N
				forval j = 1/`n_coefs' {
					local vname = varname[`j']
					* Filter out: intercept (_cons), factor level indicators (2.var), base levels (1b.var), omitted levels (2o.var)
					if "`vname'" != "_cons" & !regexm("`vname'", "^[0-9]+[bo]?\.") {
						local n_pred = `n_pred' + 1
						local pred_`n_pred' = "`vname'"
						local beta_`n_pred' = real(coef[`j'])
						local predictors "`predictors' `vname'"
						di as txt "      Predictor `n_pred': `vname' (β = " %6.3f `beta_`n_pred'' ")"
					}
				}
				restore

				di as txt "    Extracted `n_pred' predictors"

				if `n_pred' > 0 & "`sd_`cp_depvar''" != "" {
					* Check if all predictors have SDs (are continuous)
					local all_preds_have_sd = 1
					forval i = 1/`n_pred' {
						if "`sd_`pred_`i'''" == "" {
							local all_preds_have_sd = 0
							di as txt "    ⚠ Skipping checkpoint `cp': predictor `pred_`i'' is categorical (no SD available for standardization)"
						}
					}

					if `all_preds_have_sd' {
						di as txt "Processing checkpoint `cp': `cp_depvar' (`n_pred' predictors)"

						* Write commands to script
						file write `script' `"* Checkpoint `cp': `cp_depvar'"' _n

					* Write matrix operations
					file write `script' `"matrix R_XX_`cp' = I(`n_pred')"' _n
					file write `script' `"matrix beta_std_`cp' = J(`n_pred', 1, 0)"' _n

					* Build R_XX and beta_std
					forval i = 1/`n_pred' {
						local vi = "`pred_`i''"
						local beta_i = `beta_`i''
						local beta_std_i = `beta_i' * (`sd_`vi'' / `sd_`cp_depvar'')

						file write `script' `"matrix beta_std_`cp'[`i', 1] = `beta_std_i'"' _n

						forval j = 1/`n_pred' {
							local vj = "`pred_`j''"

							* Find indices
							local idx_i = 0
							local idx_j = 0
							local k = 1
							foreach v of local all_vars {
								if "`v'" == "`vi'" local idx_i = `k'
								if "`v'" == "`vj'" local idx_j = `k'
								local k = `k' + 1
							}

							if `idx_i' > 0 & `idx_j' > 0 {
								file write `script' `"matrix R_XX_`cp'[`i', `j'] = R[`idx_i', `idx_j']"' _n
							}
						}
					}

					* Compute r_XY = R_XX * beta_std
					file write `script' `"matrix r_XY_`cp' = R_XX_`cp' * beta_std_`cp'"' _n

					* Inject into R matrix
					forval i = 1/`n_pred' {
						local vname = "`pred_`i''"

						local idx_x = 0
						local idx_y = 0
						local k = 1
						foreach v of local all_vars {
							if "`v'" == "`vname'" local idx_x = `k'
							if "`v'" == "`cp_depvar'" local idx_y = `k'
							local k = `k' + 1
						}

						if `idx_x' > 0 & `idx_y' > 0 {
							file write `script' `"matrix R[`idx_x', `idx_y'] = r_XY_`cp'[`i', 1]"' _n
							file write `script' `"matrix R[`idx_y', `idx_x'] = r_XY_`cp'[`i', 1]"' _n
						}
					}

					file write `script' `""' _n
					}
				}
			}
		}
	}

	* Step 3: Add matrix save commands to script
	file write `script' `"* Check if adjusted matrix is positive definite"' _n
	file write `script' `"matrix symeigen eigvec eigval = R"' _n
	file write `script' `"local min_eigval = eigval[1,1]"' _n
	file write `script' `"forval i = 1/\`nvars' {"' _n
	file write `script' `"    if eigval[\`i',1] < \`min_eigval' {"' _n
	file write `script' `"        local min_eigval = eigval[\`i',1]"' _n
	file write `script' `"    }"' _n
	file write `script' `"}"' _n
	file write `script' `""' _n

	file write `script' `"if \`min_eigval' < 0 {"' _n
	file write `script' `"    * Applying eigenvalue clipping"' _n
	file write `script' `"    forval i = 1/\`nvars' {"' _n
	file write `script' `"        if eigval[\`i',1] < 0.001 {"' _n
	file write `script' `"            matrix eigval[\`i',1] = 0.001"' _n
	file write `script' `"        }"' _n
	file write `script' `"    }"' _n
	file write `script' `"    matrix D = diag(eigval)"' _n
	file write `script' `"    matrix R = eigvec * D * eigvec'"' _n
	file write `script' `"    * Rescale diagonal to 1"' _n
	file write `script' `"    forval i = 1/\`nvars' {"' _n
	file write `script' `"        local scale_i = sqrt(R[\`i',\`i'])"' _n
	file write `script' `"        forval j = 1/\`nvars' {"' _n
	file write `script' `"            local scale_j = sqrt(R[\`j',\`j'])"' _n
	file write `script' `"            matrix R[\`i',\`j'] = R[\`i',\`j'] / (\`scale_i' * \`scale_j')"' _n
	file write `script' `"        }"' _n
	file write `script' `"    }"' _n
	file write `script' `"}"' _n
	file write `script' `"else {"' _n
	file write `script' `"    * Adjusted matrix is positive definite"' _n
	file write `script' `"}"' _n
	file write `script' `""' _n

	file write `script' `"* Save adjusted matrix back to file"' _n
	file write `script' `"clear"' _n
	file write `script' `"local obs_needed = \`nvars' * \`nvars'"' _n
	file write `script' `"set obs \`obs_needed'"' _n
	* str32 because Stata variable names max at 32 characters
	file write `script' `"gen str32 var1 = """' _n
	file write `script' `"gen str32 var2 = """' _n
	file write `script' `"gen double corr = ."' _n
	file write `script' `"local row = 1"' _n
	file write `script' `"local i = 1"' _n
	file write `script' `"foreach v1 of local all_vars {"' _n
	file write `script' `"    local j = 1"' _n
	file write `script' `"    foreach v2 of local all_vars {"' _n
	file write `script' `"        qui replace var1 = "\`v1'" in \`row'"' _n
	file write `script' `"        qui replace var2 = "\`v2'" in \`row'"' _n
	file write `script' `"        qui replace corr = R[\`i', \`j'] in \`row'"' _n
	file write `script' `"        local row = \`row' + 1"' _n
	file write `script' `"        local j = \`j' + 1"' _n
	file write `script' `"    }"' _n
	file write `script' `"    local i = \`i' + 1"' _n
	file write `script' `"}"' _n
	file write `script' `"export delimited using "`corr_file'", replace"' _n

	file close `script'

	* Step 4: Execute the script
	di as txt _n "Executing correlation adjustment script..."
	qui do "`scriptfile'"

	di as result _n "✓ Correlation matrix adjusted for checkpoint constraints"
	di as txt "  Copula will now sample from coefficient-aware distribution"
end

* -----------------------------------------------------------------------------
program define _dm_apply_checkpoint_constraints
	args indir

	di as txt _n "{hline 60}"
	di as txt "LAYER 4: APPLYING CHECKPOINT CONSTRAINTS"
	di as txt "{hline 60}"

	* Save current data to tempfile
	tempfile synth_data
	qui save `synth_data', replace

	* Read checkpoint metadata - Phase 1: Store checkpoint info
	import delimited "`indir'/checkpoints.csv", varnames(1) clear stringcols(_all)
	local n_ckpts = _N

	* Backward compatibility: older checkpoints.csv files had no `alpha`
	* column (nbreg dispersion lived in a session global). Detect the
	* column's presence once so the per-checkpoint loop can skip it
	* cleanly on legacy files.
	cap confirm variable alpha
	local has_alpha_col = (_rc == 0)

	forval cp = 1/`n_ckpts' {
		local tag_`cp' = tag[`cp']
		local cmd_`cp' = cmd[`cp']
		local cmdline_`cp' = cmdline[`cp']
		local depvar_`cp' = depvar[`cp']
		if `has_alpha_col' {
			local alpha_`cp' = alpha[`cp']
		}
		else {
			local alpha_`cp' = ""
		}
	}

	* Phase 2: Store target coefficients and SEs.
	*
	* The on-disk format is a single long-format file (checkpoints_coef.csv)
	* with columns cp_num, varname, coef, se. We load it once, then per-
	* checkpoint filter by cp_num to build the target matrix. Replaces the
	* older per-checkpoint checkpoint_<N>_coef.csv files.
	tempfile all_coef_file
	import delimited "`indir'/checkpoints_coef.csv", varnames(1) clear
	qui save `all_coef_file', replace

	forval cp = 1/`n_ckpts' {
		use `all_coef_file', clear
		qui keep if cp_num == `cp'
		local ncoefs_`cp' = _N

		* Store targets as matrix (numeric data)
		tempname targets_`cp'
		mkmat coef, matrix(`targets_`cp'')

		* Store SEs as matrix if available
		tempname ses_`cp'
		cap confirm variable se
		if _rc == 0 {
			mkmat se, matrix(`ses_`cp'')
		}
		else {
			* Fallback: create matrix of 1s if no SEs (old format)
			matrix `ses_`cp'' = J(`ncoefs_`cp'', 1, 1)
		}

		* Store varnames as space-separated list (string data)
		local varnames_`cp' = ""
		forval i = 1/`=_N' {
			local varnames_`cp' = "`varnames_`cp'' " + varname[`i']
		}
		local varnames_`cp' = trim("`varnames_`cp''")
	}

	* Load synthetic data back
	use `synth_data', clear

	di as txt "Found " as result "`n_ckpts'" as txt " checkpoints to enforce"

	* -------------------------------------------------------------------------
	* Pre-pass: identify groups of IV checkpoints sharing the same depvar.
	* These are processed jointly (single Newton step over the stacked
	* constraint system) instead of cyclically; see docs/IV_JOINT_ADJUSTER_
	* DECISION.md for why cyclic projection of exact Newton steps is slow when
	* instrument manifolds are near-parallel (Friedrichs angle argument).
	* -------------------------------------------------------------------------
	local iv_cps ""
	forval cp = 1/`n_ckpts' {
		if "`cmd_`cp''" == "ivregress" {
			local iv_cps "`iv_cps' `cp'"
		}
	}

	local unique_iv_depvars ""
	foreach cp of local iv_cps {
		local dv "`depvar_`cp''"
		local already : list dv in unique_iv_depvars
		if !`already' {
			local unique_iv_depvars "`unique_iv_depvars' `dv'"
		}
	}

	* Index-based group storage (Stata local-name length limit is 31 chars,
	* so depvar-suffixed locals break on long names like d_sh_empl_mfg_age1839m).
	local n_iv_groups = 0
	local jointly_handled_cps ""
	foreach dv of local unique_iv_depvars {
		local this_cps ""
		foreach cp of local iv_cps {
			if "`depvar_`cp''" == "`dv'" {
				local this_cps "`this_cps' `cp'"
			}
		}
		local n_in_group : word count `this_cps'
		if `n_in_group' >= 2 {
			local n_iv_groups = `n_iv_groups' + 1
			local iv_group_dv_`n_iv_groups' "`dv'"
			local iv_group_cps_`n_iv_groups' "`this_cps'"
			local jointly_handled_cps "`jointly_handled_cps' `this_cps'"
		}
	}

	if `n_iv_groups' > 0 {
		di as txt _n "Detected " as result "`n_iv_groups'" as txt " shared-outcome IV groups; will apply joint Newton step"
	}

	* Apply constraints iteratively with multiple global passes
	* Multiple passes help when checkpoints share Y variables or correlated instruments
	local max_iter = 50        // Fewer iterations per checkpoint
	local tolerance = 0.005
	local learning_rate = 0.1
	local n_global_passes = 3  // Do multiple passes through all checkpoints

	forval global_pass = 1/`n_global_passes' {
		di as txt _n "{hline 60}"
		di as txt "GLOBAL PASS `global_pass' of `n_global_passes'"
		di as txt "{hline 60}"

		* -----------------------------------------------------------------
		* Joint-IV sub-pass: for each shared-y IV group, run the stacked
		* Newton step. Done first so that single-y adjusters that follow do
		* not have to re-fit IV estimators on an already-balanced y.
		* -----------------------------------------------------------------
		forval gi = 1/`n_iv_groups' {
			local dv "`iv_group_dv_`gi''"
			local group_cps "`iv_group_cps_`gi''"
			local n_group_cps : word count `group_cps'

			di as txt _n "{hline 60}"
			di as txt "Joint IV group on `dv' (`n_group_cps' checkpoints; pass `global_pass')"
			di as txt "{hline 60}"

			* Build specfile.
			tempfile ivj_spec
			preserve
			qui clear
			qui set obs `n_group_cps'
			qui gen str244 cmdline = ""
			qui gen str244 varnames = ""
			qui gen str32  targets_matname = ""
			qui gen str32  ses_matname = ""
			local row = 0
			foreach cp of local group_cps {
				local row = `row' + 1
				qui replace cmdline = "`cmdline_`cp''"            in `row'
				qui replace varnames = "`varnames_`cp''"          in `row'
				qui replace targets_matname = "`targets_`cp''"    in `row'
				qui replace ses_matname = "`ses_`cp''"            in `row'
			}
			qui save "`ivj_spec'", replace
			restore

			_dm_constrain_iv_joint "`dv'" "`ivj_spec'" 1.0 `tolerance'

			if r(fallback) == 1 {
				di as txt "  Joint step fell back; running cyclic single-checkpoint on each member of this group."
				foreach cp of local group_cps {
					_dm_constrain_iv "`cmdline_`cp''" `targets_`cp'' `ses_`cp'' "`varnames_`cp''" "`depvar_`cp''" ///
					              `max_iter' `tolerance' `learning_rate'
				}
			}
		}


		forval cp = 1/`n_ckpts' {
			* Skip IV checkpoints that belong to a joint group.
			local skip_cp : list cp in jointly_handled_cps
			if `skip_cp' {
				continue
			}

			di as txt _n "{hline 60}"
			di as txt "Checkpoint `cp': `tag_`cp'' (pass `global_pass')"
			di as txt "{hline 60}"

			* Check if we can run this model
			local cmdline "`cmdline_`cp''"
			local cmd "`cmd_`cp''"

			* Dispatch to appropriate model-specific adjuster
			if "`cmd'" == "regress" | "`cmd'" == "reg" {
				_dm_constrain_ols "`cmdline'" `targets_`cp'' "`varnames_`cp''" "`depvar_`cp''"
			}
			else if "`cmd'" == "reghdfe" {
				_dm_constrain_fe "`cmdline'" `targets_`cp'' "`varnames_`cp''" "`depvar_`cp''"
			}
			else if "`cmd'" == "ivregress" {
				_dm_constrain_iv "`cmdline'" `targets_`cp'' `ses_`cp'' "`varnames_`cp''" "`depvar_`cp''" ///
				              `max_iter' `tolerance' `learning_rate'
			}
			else if "`cmd'" == "logit" | "`cmd'" == "logistic" {
				_dm_constrain_logit "`cmdline'" `targets_`cp'' "`varnames_`cp''" "`depvar_`cp''"
			}
			else if "`cmd'" == "probit" {
				_dm_constrain_probit "`cmdline'" `targets_`cp'' "`varnames_`cp''" "`depvar_`cp''"
			}
			else if "`cmd'" == "poisson" {
				_dm_constrain_poisson "`cmdline'" `targets_`cp'' "`varnames_`cp''" "`depvar_`cp''"
			}
			else if "`cmd'" == "nbreg" {
				* nbreg needs alpha from the on-disk checkpoints.csv (falls
				* back to the legacy session global only on older extracts).
				local alpha_orig "`alpha_`cp''"
				if "`alpha_orig'" == "" {
					local alpha_orig = ${dm_cp`cp'_alpha}
				}
				_dm_constrain_nbreg "`cmdline'" `targets_`cp'' "`varnames_`cp''" "`depvar_`cp''" `alpha_orig'
			}
			else {
				di as txt "  Skipping: `cmd' not yet supported for constraint enforcement"
			}
		}
	}

	di as txt _n "{hline 60}"
	di as result "CHECKPOINT CONSTRAINTS APPLIED"
	di as txt "{hline 60}"
end

* -----------------------------------------------------------------------------
* OLS adjuster: closed-form Newton step on the synthetic outcome.
*
* For y = X β̂ + e, Stata's regress yields β̂ = (X' X)^(-1) X' y. Shifting y by
* the linear combination X (β* - β̂) updates the fitted coefficient vector
* exactly by Δβ = β* - β̂:
*     β̂_new = (X' X)^(-1) X' (y + X Δβ) = β̂ + Δβ
* implemented one-shot via Stata's `matrix score`, which walks the design
* matrix encoded in e(b) colnames (handling factor-variable expansion and
* interactions internally). No iteration, no learning rate, no tolerance.
*
* -----------------------------------------------------------------------------
program define _dm_constrain_ols
	args cmdline targets varnames depvar

	di as txt "  Model: `cmdline'"

	cap qui `cmdline'
	if _rc != 0 {
		di as error "  Error running OLS model (rc=`=_rc')"
		exit _rc
	}

	matrix b_cur = e(b)
	local colnames_cur : colnames b_cur
	local ncols = colsof(b_cur)
	local ncoefs = rowsof(`targets')

	* Build b_delta = b_target - b_current, preserving the e(b) column order
	* so matrix score resolves factor-variable terms correctly.
	matrix b_delta = J(1, `ncols', 0)
	scalar max_delta = 0
	forval j = 1/`ncols' {
		local cn : word `j' of `colnames_cur'
		forval i = 1/`ncoefs' {
			local vn : word `i' of `varnames'
			if "`vn'" == "`cn'" {
				local tgt = `targets'[`i', 1]
				local cur = b_cur[1, `j']
				local d   = `tgt' - `cur'
				matrix b_delta[1, `j'] = `d'
				if abs(`d') > max_delta scalar max_delta = abs(`d')
				continue, break
			}
		}
	}
	matrix colnames b_delta = `colnames_cur'

	tempvar touse dy
	qui gen byte `touse' = e(sample)
	qui matrix score double `dy' = b_delta if `touse'
	qui replace `depvar' = `depvar' + `dy' if `touse'

	di as txt "  Pre-adjust max |Δβ|: " %8.6f max_delta as txt " (closed-form one-shot; post-adjust = 0 up to precision)"
end
* -----------------------------------------------------------------------------
* Fixed-effects adjuster: closed-form Newton step on the synthetic outcome.
*
* reghdfe β̂ satisfies β̂ = (X̃' X̃)^(-1) X̃' ỹ where tilde denotes residualization
* against absorbed effects. Shifting y by X (β* - β̂) on the non-absorbed
* design updates β̂ by exactly β* - β̂:
*     β̂_new = (X̃' X̃)^(-1) X̃' M_FE (y + X Δβ) = β̂ + (X̃' X̃)^(-1) X̃' X̃ Δβ = β̂ + Δβ
* because M_FE X = X̃. One-shot via matrix score on reghdfe's e(b) colnames
* (absorbed fixed effects are excluded from e(b), which is what we want).
*
* Singleton-dropped observations are preserved unchanged in the output.
* -----------------------------------------------------------------------------
program define _dm_constrain_fe
	args cmdline targets varnames depvar

	di as txt "  Model: `cmdline'"
	di as txt "  Type: Fixed effects (reghdfe)"

	cap qui `cmdline'
	if _rc != 0 {
		di as error "  Error running FE model (rc=`=_rc'); skipping"
		exit
	}

	matrix b_cur = e(b)
	local colnames_cur : colnames b_cur
	local ncols = colsof(b_cur)
	local ncoefs = rowsof(`targets')

	matrix b_delta = J(1, `ncols', 0)
	scalar max_delta = 0
	forval j = 1/`ncols' {
		local cn : word `j' of `colnames_cur'
		forval i = 1/`ncoefs' {
			local vn : word `i' of `varnames'
			if "`vn'" == "`cn'" {
				local tgt = `targets'[`i', 1]
				local cur = b_cur[1, `j']
				local d   = `tgt' - `cur'
				matrix b_delta[1, `j'] = `d'
				if abs(`d') > max_delta scalar max_delta = abs(`d')
				continue, break
			}
		}
	}

	* Report variables that were absorbed (not in e(b)) for transparency.
	forval i = 1/`ncoefs' {
		local vn : word `i' of `varnames'
		local present = 0
		foreach cn in `colnames_cur' {
			if "`cn'" == "`vn'" {
				local present = 1
				continue, break
			}
		}
		if !`present' & "`vn'" != "" {
			di as txt "    (absorbed by fixed effects: `vn')"
		}
	}

	matrix colnames b_delta = `colnames_cur'

	tempvar touse dy
	qui gen byte `touse' = e(sample)
	qui matrix score double `dy' = b_delta if `touse'
	qui replace `depvar' = `depvar' + `dy' if `touse'

	di as txt "  Pre-adjust max |Δβ|: " %8.6f max_delta as txt " (closed-form one-shot; post-adjust = 0 up to precision)"
end
* -----------------------------------------------------------------------------
program define _dm_constrain_iv
	args cmdline targets ses varnames depvar max_iter tolerance learning_rate

	di as txt _n "Adjusting IV model (Newton step)..."

	* Newton-step 2SLS coefficient pinning. See docs/IV_CONSTRAINT_DECISION.md
	* for the derivation. For just-identified k x k 2SLS with controls W and
	* (optionally) analytic weights w_i, the minimum-weighted-norm y update
	* that moves the endogenous coefficient vector by Delta_beta is
	*   delta_y_i = sum_j [ (pi_hat * Delta_beta)_j * Z_tilde_{i,j} ]
	* where Z_tilde = M_W Z is the weighted residual of the instrument on
	* the controls, pi_hat = (Z_tilde' Omega Z_tilde)^-1 (Z_tilde' Omega X_tilde),
	* and X_tilde = M_W X1. The update pins beta_hat onto the target up to
	* floating-point precision in one step (iteration retained only to
	* absorb O(1/N) re-estimation drift and weak-instrument ill-conditioning).

	* Run the model once to populate e() so we can read the estimation
	* structure directly instead of re-parsing cmdline.
	cap qui `cmdline'
	if _rc != 0 {
		di as error "  Error running IV model (rc=`=_rc')"
		di as error "  Command: `cmdline'"
		exit _rc
	}

	local endog_vars    "`e(instd)'"
	local all_insts     "`e(insts)'"
	local control_vars  "`e(exogr)'"
	local wtype         "`e(wtype)'"
	local wexp          "`e(wexp)'"
	local endog_vars    : list retokenize endog_vars
	local all_insts     : list retokenize all_insts
	local control_vars  : list retokenize control_vars

	* ivregress stores e(insts) as excluded instruments ∪ exogenous controls.
	* Subtract the controls to get just the excluded instruments (our Z).
	local inst_vars : list all_insts - control_vars
	local inst_vars : list retokenize inst_vars

	local k : word count `endog_vars'
	local m : word count `inst_vars'

	di as txt "  Endogenous (k=`k'): `endog_vars'"
	di as txt "  Instruments (m=`m'): `inst_vars'"
	if "`control_vars'" != "" {
		di as txt "  Controls: `control_vars'"
	}
	if "`wtype'" != "" {
		di as txt "  Weights: [`wtype'`wexp']"
	}

	if `k' != `m' {
		di as txt "  Over-identified case (m != k) uses full GMM Newton step"
	}

	* Build weight clauses. Stata's matrix accum uses iweights which do not
	* renormalize; for our Gram/cross-moment ratios the absolute scale is
	* irrelevant (both numerator and denominator scale by the same factor),
	* so iw gives the correct coefficient ratio even when the user passed aw.
	local reg_weight ""
	local accum_weight ""
	if "`wtype'" != "" {
		local reg_weight "[`wtype'`wexp']"
		local raw_wvar = substr("`wexp'", 2, .)
		local accum_weight "[iw=`raw_wvar']"
	}

	* Estimation sample indicator
	tempvar touse
	qui gen byte `touse' = e(sample)

	* Build residualized instrument and endogenous columns (FWL under weights).
	* Residualize each Z_j and X1_j against control_vars; if there are no
	* controls the residual equals the centered variable (residual against
	* the constant).
	local ztilde_vars ""
	local xtilde_vars ""
	foreach v in `inst_vars' {
		tempvar zt
		if "`control_vars'" == "" {
			qui sum `v' `reg_weight' if `touse', meanonly
			qui gen double `zt' = `v' - r(mean) if `touse'
		}
		else {
			cap qui regress `v' `control_vars' `reg_weight' if `touse'
			if _rc != 0 {
				di as error "  Failed to residualize instrument `v' against controls"
				exit _rc
			}
			qui predict double `zt' if `touse', resid
		}
		local ztilde_vars "`ztilde_vars' `zt'"
	}
	foreach v in `endog_vars' {
		tempvar xt
		if "`control_vars'" == "" {
			qui sum `v' `reg_weight' if `touse', meanonly
			qui gen double `xt' = `v' - r(mean) if `touse'
		}
		else {
			cap qui regress `v' `control_vars' `reg_weight' if `touse'
			if _rc != 0 {
				di as error "  Failed to residualize endogenous `v' against controls"
				exit _rc
			}
			qui predict double `xt' if `touse', resid
		}
		local xtilde_vars "`xtilde_vars' `xt'"
	}

	* Compute Omega-weighted Gram and cross-moments via matrix accum.
	* matrix accum A = varlist [iw=w]  computes  X' W X  as a symmetric matrix.
	* matrix glsaccum A = varlist (y) [iw=w]  computes  y' W X  as a row.
	qui matrix accum ZZ = `ztilde_vars' `accum_weight' if `touse', noconstant
	qui matrix accum XX = `xtilde_vars' `accum_weight' if `touse', noconstant

	* Z'OmegaX via block of joint accum
	qui matrix accum ZX_block = `ztilde_vars' `xtilde_vars' `accum_weight' if `touse', noconstant
	* ZX_block is (m+k) x (m+k). Extract the top-right m x k block: Z' Omega X
	matrix ZX = ZX_block[1..`m', `=`m'+1'..`=`m'+`k'']

	* Find endogenous coefficient indices in varnames for the target vector.
	local endog_indices ""
	foreach ev of local endog_vars {
		local ev_found = 0
		forval i = 1/`=rowsof(`targets')' {
			local vn : word `i' of `varnames'
			if "`vn'" == "`ev'" {
				local endog_indices "`endog_indices' `i'"
				local ev_found = 1
				continue, break
			}
		}
		if !`ev_found' {
			di as error "  Endogenous variable `ev' not found in targets vector"
			exit 459
		}
	}

	* Newton-step Jacobian inverse.
	*   Just-identified (m = k): pi = invsym(ZZ) * ZX is k x k, invertible when
	*     instruments are strong; H^-1 for the y -> beta map is ZX so the
	*     update coefficient on Z_tilde is pi.
	*   Over-identified  (m > k): use full GMM form
	*     W_gmm = (ZX' invsym(ZZ) ZX)^-1 ZX' invsym(ZZ)    (k x m)
	*     update direction on Z_tilde: pi_gmm' where pi_gmm = ZZ^-1 ZX is m x k.
	*     The minimum-norm update stays: delta_y = sum_j (pi_gmm Delta_beta)_j Z_tilde_j,
	*     but Delta_beta is first mapped through (ZX' invsym(ZZ) ZX)^-1 ZX' invsym(ZZ) ZX = I
	*     so effectively delta_y = pi_gmm * Delta_beta (same form as just-identified).

	matrix ZZ_inv = invsym(ZZ)
	matrix pi_hat = ZZ_inv * ZX

	* Diagnostic: condition number of ZX'ZZ^-1 ZX (first-stage strength proxy)
	matrix FS_core = ZX' * ZZ_inv * ZX
	local pi_cond = .
	cap {
		matrix FS_svd_U = .
		matrix FS_svd_S = .
		matrix FS_svd_V = .
		matrix svd FS_svd_U FS_svd_S FS_svd_V = FS_core
		local n_sv = colsof(FS_svd_S)
		local sv_max = FS_svd_S[1, 1]
		local sv_min = FS_svd_S[1, `n_sv']
		if `sv_min' > 0 {
			local pi_cond = `sv_max' / `sv_min'
		}
	}
	if `pi_cond' != . {
		di as txt "  First-stage conditioning: max/min singular value = " %8.2e `pi_cond'
		if `pi_cond' > 1e8 {
			di as error "  WARNING: ill-conditioned first stage. Weak-instrument regime; fidelity not guaranteed."
		}
	}

	local converged = 0
	scalar max_delta_se = 0

	forval iter = 1/`max_iter' {
		* Re-fit to get current beta_hat on current synthetic y.
		cap qui `cmdline'
		if _rc != 0 {
			di as error "  Error re-fitting IV at iteration `iter' (rc=`=_rc')"
			continue, break
		}

		matrix b = e(b)
		local colnames : colnames b

		* Build Delta_beta for endogenous block (k x 1).
		matrix Delta_beta = J(`k', 1, 0)
		local ec = 0
		scalar max_delta_se = 0
		foreach idx of local endog_indices {
			local ec = `ec' + 1
			local target = `targets'[`idx', 1]
			local se = `ses'[`idx', 1]
			local vn : word `idx' of `varnames'

			local ncols = colsof(b)
			forval j = 1/`ncols' {
				local cn : word `j' of `colnames'
				if "`cn'" == "`vn'" {
					local synth = b[1, `j']
					local err = `target' - `synth'
					matrix Delta_beta[`ec', 1] = `err'
					local dse = abs(`err') / `se'
					if `dse' > max_delta_se {
						scalar max_delta_se = `dse'
					}
					continue, break
				}
			}
		}

		if max_delta_se < `tolerance' {
			local converged = 1
			di as txt "  Iteration `iter': Max Δ/SE = " %6.4f max_delta_se as result " ✓ Converged"
			continue, break
		}

		* Compute v = pi_hat * Delta_beta   (m x 1)
		matrix v = pi_hat * Delta_beta

		* Apply the Newton update on y.
		tempvar dy
		qui gen double `dy' = 0 if `touse'
		local zc = 0
		foreach zt of local ztilde_vars {
			local zc = `zc' + 1
			local vj = v[`zc', 1]
			qui replace `dy' = `dy' + (`vj') * `zt' if `touse'
		}
		qui replace `depvar' = `depvar' + `learning_rate' * `dy' if `touse'

		if mod(`iter', 10) == 0 | `iter' == 1 {
			di as txt "  Iteration `iter': Max Δ/SE = " %6.4f max_delta_se
		}
	}

	if !`converged' {
		di as txt "  Final: Max Δ/SE = " %6.4f max_delta_se as txt " (reached max iterations)"
	}

	* Verify first-stage strength for reporting (does not alter update).
	cap qui `cmdline'
	cap estat firststage
	if _rc == 0 {
		cap matrix fs = r(singleresults)
		if _rc == 0 {
			local fstat = fs[1,1]
			di as txt "  First-stage F-statistic: " %6.2f `fstat'
			if `fstat' > 10 {
				di as result "  ✓ Instruments remain strong (F > 10)"
			}
			else if `fstat' > 4 {
				di as txt "  Instruments in weak regime (4 < F <= 10)"
			}
			else {
				di as error "  ⚠ Very weak instruments (F <= 4); pinning fidelity not guaranteed"
			}
		}
	}
end
* =============================================================================
* Joint IV adjuster (multi-checkpoint shared-y Newton step).
* See docs/IV_JOINT_CONSTRAINT_DECISION.md for derivation.
*
* Given a list of K IV checkpoints sharing the same outcome y, computes the
* minimum-Omega-weighted-norm delta_y that satisfies all K coefficient
* constraints simultaneously:
*   delta_y = Omega^-1 * A_stack' * (A_stack Omega^-1 A_stack')^-1 * Delta_stack
* where A_k = (Z_tilde_k' Omega X_tilde_k)^-1 Z_tilde_k' Omega is the k-th
* checkpoint's Jacobian of beta_hat wrt y_tilde. The block structure of the
* joint Gram is A_k Omega^-1 A_l' = B_k G_{kl} B_l' with B_k =
* (Z_tilde_k' Omega X_tilde_k)^-1 and G_{kl} = Z_tilde_k' Omega Z_tilde_l.
*
* Usage (called from _dm_apply_checkpoint_constraints for each shared-y group):
*   _dm_constrain_iv_joint <depvar> "<specfile>" <learning_rate> <tolerance>
*
* The specfile is a Stata .dta tempfile written by the dispatcher with one
* row per grouped checkpoint and columns:
*   cmdline          (str) - the estimation command to refit and adjust
*   varnames         (str) - space-separated list of coefficient names
*   targets_matname  (str) - tempname of the K x 1 target-coefficient matrix
*   ses_matname      (str) - tempname of the K x 1 standard-error matrix
*
* Matrices are referenced by name (tempnames are globally accessible); no
* user-visible globals are touched. Diagnostic returns via r():
*   r(max_dse)    final max Δβ/SE across the group
*   r(converged)  1 if converged below tolerance, 0 otherwise
*   r(fallback)   1 if joint step aborted (over-identified, mismatched weights,
*                 or ill-conditioned Gram) so the dispatcher can run the
*                 cyclic single-checkpoint path instead
* =============================================================================
program define _dm_constrain_iv_joint, rclass
	args depvar specfile learning_rate tolerance

	* Load the per-checkpoint spec rows without disturbing the working data.
	preserve
	qui use "`specfile'", clear
	local n_cp = _N
	forval c = 1/`n_cp' {
		local cmdline_spec_`c'  = cmdline[`c']
		local varnames_spec_`c' = varnames[`c']
		local targetsmat_`c'    = targets_matname[`c']
		local sesmat_`c'        = ses_matname[`c']
	}
	restore

	return scalar fallback  = 0
	return scalar converged = 0
	return scalar max_dse   = .

	di as txt _n "Joint IV adjustment across `n_cp' checkpoints on `depvar'..."

	* -------------------------------------------------------------------------
	* Per-checkpoint setup: run each IV, extract structure, residualize.
	* -------------------------------------------------------------------------
	local k_total = 0
	tempvar touse_union
	qui gen byte `touse_union' = 0

	* Track per-checkpoint: endog list, inst list, ztilde names, xtilde names,
	* k_k (endog count), weight info, touse
	forval c = 1/`n_cp' {
		local cmdline_c  "`cmdline_spec_`c''"
		local varnames_c "`varnames_spec_`c''"

		cap qui `cmdline_c'
		if _rc != 0 {
			di as error "  Joint-IV: failed to fit checkpoint `c': `cmdline_c'"
			exit _rc
		}

		local endog_c   "`e(instd)'"
		local all_ins_c "`e(insts)'"
		local ctrls_c   "`e(exogr)'"
		local wtype_c   "`e(wtype)'"
		local wexp_c    "`e(wexp)'"
		local endog_c   : list retokenize endog_c
		local all_ins_c : list retokenize all_ins_c
		local ctrls_c   : list retokenize ctrls_c
		local inst_c    : list all_ins_c - ctrls_c
		local inst_c    : list retokenize inst_c

		local k_c : word count `endog_c'
		local m_c : word count `inst_c'
		if `k_c' != `m_c' {
			di as txt "  Joint-IV: checkpoint `c' is over-identified (m=`m_c' k=`k_c'); falling back to single-checkpoint"
			return scalar fallback = 1
			exit
		}

		local k_total = `k_total' + `k_c'
		local endog_`c'_list "`endog_c'"
		local inst_`c'_list  "`inst_c'"
		local ctrls_`c'_list "`ctrls_c'"
		local k_`c' = `k_c'

		local reg_weight_c ""
		local accum_weight_c ""
		if "`wtype_c'" != "" {
			local reg_weight_c "[`wtype_c'`wexp_c']"
			local raw_wvar_c = substr("`wexp_c'", 2, .)
			local accum_weight_c "[iw=`raw_wvar_c']"
		}
		local reg_weight_`c' "`reg_weight_c'"
		local accum_weight_`c' "`accum_weight_c'"

		tempvar touse_c
		qui gen byte `touse_c' = e(sample)
		qui replace `touse_union' = 1 if `touse_c' == 1
		local touse_`c' "`touse_c'"

		* Residualize Z_c and X_c against controls_c under weights.
		local ztilde_`c'_list ""
		foreach v in `inst_c' {
			tempvar zt
			if "`ctrls_c'" == "" {
				qui sum `v' `reg_weight_c' if `touse_c', meanonly
				qui gen double `zt' = `v' - r(mean) if `touse_c'
			}
			else {
				cap qui regress `v' `ctrls_c' `reg_weight_c' if `touse_c'
				if _rc != 0 {
					di as error "  Joint-IV: failed to residualize `v' for checkpoint `c'"
					exit _rc
				}
				qui predict double `zt' if `touse_c', resid
			}
			local ztilde_`c'_list "`ztilde_`c'_list' `zt'"
		}
		local xtilde_`c'_list ""
		foreach v in `endog_c' {
			tempvar xt
			if "`ctrls_c'" == "" {
				qui sum `v' `reg_weight_c' if `touse_c', meanonly
				qui gen double `xt' = `v' - r(mean) if `touse_c'
			}
			else {
				cap qui regress `v' `ctrls_c' `reg_weight_c' if `touse_c'
				if _rc != 0 {
					di as error "  Joint-IV: failed to residualize `v' for checkpoint `c'"
					exit _rc
				}
				qui predict double `xt' if `touse_c', resid
			}
			local xtilde_`c'_list "`xtilde_`c'_list' `xt'"
		}

		* Per-checkpoint cross-moments ZX_c (m x k) and Gram ZZ_c (m x m)
		qui matrix accum ZX_block_`c' = `ztilde_`c'_list' `xtilde_`c'_list' `accum_weight_c' if `touse_c', noconstant
		local col_start = `m_c' + 1
		local col_end   = `m_c' + `k_c'
		matrix ZX_`c' = ZX_block_`c'[1..`m_c', `col_start'..`col_end']
		qui matrix accum ZZ_`c' = `ztilde_`c'_list' `accum_weight_c' if `touse_c', noconstant

		* B_c = inv(ZX_c) (k x k for just-identified where m=k; ZX not symmetric)
		matrix B_`c' = inv(ZX_`c')
	}

	* -------------------------------------------------------------------------
	* Compute cross-checkpoint Grams G_{kl} = Z_tilde_k' Omega Z_tilde_l.
	* Use the checkpoint with the larger weight-vector as reference; assume
	* shared weight across checkpoints in a group (verified by comparing
	* accum_weight strings; mismatch triggers fallback).
	* -------------------------------------------------------------------------
	local ref_weight "`accum_weight_1'"
	forval c = 2/`n_cp' {
		if "`accum_weight_`c''" != "`ref_weight'" {
			di as txt "  Joint-IV: checkpoints use different weights; falling back to single-checkpoint"
			return scalar fallback = 1
			exit
		}
	}

	* -------------------------------------------------------------------------
	* Assemble the K_total x K_total joint Gram block-by-block.
	*   G_joint[k_block, l_block] = B_k * (Z_tilde_k' Omega Z_tilde_l) * B_l'
	* Off-diagonal blocks require cross-checkpoint accum.
	* -------------------------------------------------------------------------
	matrix G_joint = J(`k_total', `k_total', 0)

	local row_base = 0
	forval c = 1/`n_cp' {
		local col_base = 0
		forval d = 1/`n_cp' {
			if `c' == `d' {
				* Diagonal: B_c * ZZ_c * B_c'
				matrix M_cd = B_`c' * ZZ_`c' * B_`c''
			}
			else {
				* Off-diagonal: need Z_tilde_c' Omega Z_tilde_d
				qui matrix accum ZZ_block_`c'_`d' = `ztilde_`c'_list' `ztilde_`d'_list' `ref_weight' if `touse_union', noconstant
				local k_c_loc = `k_`c''
				local k_d_loc = `k_`d''
				local col_s = `k_c_loc' + 1
				local col_e = `k_c_loc' + `k_d_loc'
				matrix ZZ_cd = ZZ_block_`c'_`d'[1..`k_c_loc', `col_s'..`col_e']
				matrix M_cd = B_`c' * ZZ_cd * B_`d''
			}

			forval i = 1/`k_`c'' {
				forval j = 1/`k_`d'' {
					local gi = `row_base' + `i'
					local gj = `col_base' + `j'
					matrix G_joint[`gi', `gj'] = M_cd[`i', `j']
				}
			}
			local col_base = `col_base' + `k_`d''
		}
		local row_base = `row_base' + `k_`c''
	}

	* Condition number diagnostic
	cap {
		matrix svd_U = .
		matrix svd_S = .
		matrix svd_V = .
		matrix svd svd_U svd_S svd_V = G_joint
		local n_sv = colsof(svd_S)
		local sv_max = svd_S[1, 1]
		local sv_min = svd_S[1, `n_sv']
		if `sv_min' > 0 {
			local cond_j = `sv_max' / `sv_min'
			di as txt "  Joint Gram conditioning: max/min singular = " %8.2e `cond_j'
			if `cond_j' > 1e10 {
				di as error "  WARNING: joint Gram ill-conditioned (cond > 1e10). Falling back to cyclic."
				return scalar fallback = 1
				exit
			}
		}
	}

	* -------------------------------------------------------------------------
	* Find target coefficients for each checkpoint's endogenous block.
	* -------------------------------------------------------------------------
	forval c = 1/`n_cp' {
		local endog_c "`endog_`c'_list'"
		local vnames_c "`varnames_spec_`c''"
		local targetsmat_c "`targetsmat_`c''"
		local endog_idx_`c' ""
		foreach ev of local endog_c {
			local found = 0
			forval i = 1/`=rowsof(`targetsmat_c')' {
				local vn : word `i' of `vnames_c'
				if "`vn'" == "`ev'" {
					local endog_idx_`c' "`endog_idx_`c'' `i'"
					local found = 1
					continue, break
				}
			}
			if !`found' {
				di as error "  Joint-IV: endog `ev' not in varnames for cp `c'"
				exit 459
			}
		}
	}

	* -------------------------------------------------------------------------
	* Joint Newton iteration. Jacobian is y-independent so typically converges
	* in 1-2 iterations; loop exists for floating-point cleanup and any
	* dependence from prior cross-model adjustments.
	* -------------------------------------------------------------------------
	matrix G_joint_inv = invsym(G_joint)

	local max_iter = 5
	local converged = 0
	forval iter = 1/`max_iter' {
		* Build Delta_stack (K_total x 1) from current beta_hats
		matrix Delta_stack = J(`k_total', 1, 0)
		local base = 0
		scalar max_dse_joint = 0

		forval c = 1/`n_cp' {
			local cmdline_c "`cmdline_spec_`c''"
			local targetsmat_c "`targetsmat_`c''"
			local sesmat_c "`sesmat_`c''"
			local varnames_c "`varnames_spec_`c''"
			cap qui `cmdline_c'
			if _rc != 0 {
				di as error "  Joint-IV: re-fit failed at iter `iter', cp `c'"
				continue, break
			}
			matrix b_c = e(b)
			local colnames_c : colnames b_c
			local pos = 0
			foreach idx of local endog_idx_`c' {
				local pos = `pos' + 1
				local target = `targetsmat_c'[`idx', 1]
				local se = `sesmat_c'[`idx', 1]
				local vn : word `idx' of `varnames_c'
				local ncols = colsof(b_c)
				local stack_row = `base' + `pos'
				forval j = 1/`ncols' {
					local cn : word `j' of `colnames_c'
					if "`cn'" == "`vn'" {
						local synth = b_c[1, `j']
						local err = `target' - `synth'
						matrix Delta_stack[`stack_row', 1] = `err'
						local dse = abs(`err') / `se'
						if `dse' > max_dse_joint {
							scalar max_dse_joint = `dse'
						}
						continue, break
					}
				}
			}
			local base = `base' + `k_`c''
		}

		if max_dse_joint < `tolerance' {
			local converged = 1
			di as txt "  Iteration `iter': Max Δ/SE = " %6.4f max_dse_joint as result " ✓ Converged"
			return scalar converged = 1
			return scalar max_dse = max_dse_joint
			continue, break
		}

		* Solve u = G_joint^-1 * Delta_stack  (K_total x 1)
		matrix u_joint = G_joint_inv * Delta_stack

		* Compute r_c = B_c' * u_c (k_c x 1) for each checkpoint.
		* Then delta_y_i = sum_c sum_j Z_tilde_{c,j,i} * r_{c,j}
		tempvar dy_joint
		qui gen double `dy_joint' = 0 if `touse_union'

		local base = 0
		forval c = 1/`n_cp' {
			local k_c_loc = `k_`c''
			local slice_start = `base' + 1
			local slice_end   = `base' + `k_c_loc'
			matrix u_c = u_joint[`slice_start'..`slice_end', 1]
			matrix r_c = B_`c'' * u_c
			local j = 0
			foreach zt of local ztilde_`c'_list {
				local j = `j' + 1
				local rj = r_c[`j', 1]
				qui replace `dy_joint' = `dy_joint' + (`rj') * `zt' if `touse_`c''
			}
			local base = `base' + `k_`c''
		}

		qui replace `depvar' = `depvar' + `learning_rate' * `dy_joint' if `touse_union'

		di as txt "  Iteration `iter': Max Δ/SE = " %6.4f max_dse_joint
	}

	if !`converged' {
		di as txt "  Final: Max Δ/SE = " %6.4f max_dse_joint as txt " (reached max iterations)"
		return scalar max_dse = max_dse_joint
	}
end
* =============================================================================
* Binary-outcome adjusters: direct DGP sampling.
*
* Given target β* (in `targets'), build the linear predictor μ*_i = X_i · β*
* and sample y from the canonical binary DGP:
*     logit:   p*_i = invlogit(μ*_i)
*     probit:  p*_i = normal(μ*_i)
*     y_i    ~ Bernoulli(p*_i)           (implemented as runiform() < p*)
*
* Fitting the matching model on this y recovers β* within O(1/√N) sampling
* noise. Factor-level coefficients are preserved by construction (the DGP
* is applied at the observation level, not the coefficient level).
*
* Why not iterative paired-swap: the swap engine only moved observations
* between adjacent factor levels under a marginal-count-preservation
* constraint, which is an integer-programming problem the heuristic
* solved only approximately. Factor Δβ/SE landed around 7, not 2. Direct
* DGP dissolves that limitation because the y distribution is chosen to
* match the target β* by the textbook binary GLM data-generating process.
* Full rationale and literature: docs/LOGIT_PROBIT_DGP_DECISION.md.
*
* Separation safeguard: clip p* to [ε, 1-ε] with ε = 1e-4 before sampling
* so that downstream logit/probit refits do not hit the MLE non-existence
* boundary (Albert and Anderson 1984) on rare-event strata.
*
* Direct DGP sampling is one-shot and has no learning rate / max iterations.
* =============================================================================

program define _dm_constrain_logit
	args cmdline targets varnames depvar
	_dm_constrain_binary_dgp "logit" "`cmdline'" `targets' "`varnames'" "`depvar'"
end

program define _dm_constrain_probit
	args cmdline targets varnames depvar
	_dm_constrain_binary_dgp "probit" "`cmdline'" `targets' "`varnames'" "`depvar'"
end

* -----------------------------------------------------------------------------
* _dm_constrain_binary_dgp: shared core for logit/probit direct DGP sampling.
* -----------------------------------------------------------------------------
program define _dm_constrain_binary_dgp
	args link cmdline targets varnames depvar

	di as txt _n "Adjusting `link' model (direct Bernoulli DGP sampling)..."

	local ncoefs = rowsof(`targets')

	* Build the target linear predictor μ* = X · β*.
	tempvar xb p_star
	qui gen double `xb' = 0

	forval i = 1/`ncoefs' {
		local target = `targets'[`i', 1]
		local varname : word `i' of `varnames'

		if "`varname'" == "_cons" {
			qui replace `xb' = `xb' + `target'
		}
		else if regexm("`varname'", "^([0-9]+)(b?)\.(.+)$") {
			local level = regexs(1)
			local is_base = regexs(2)
			local base_varname = regexs(3)
			if "`is_base'" != "b" {
				cap confirm variable `base_varname'
				if _rc == 0 {
					qui replace `xb' = `xb' + `target' * (`base_varname' == `level')
				}
			}
		}
		else {
			cap confirm variable `varname'
			if _rc == 0 {
				qui replace `xb' = `xb' + `target' * `varname'
			}
		}
	}

	* Inverse link + separation safeguard (clip to (ε, 1-ε)).
	if "`link'" == "logit" {
		qui gen double `p_star' = invlogit(`xb')
	}
	else {
		qui gen double `p_star' = normal(`xb')
	}
	qui replace `p_star' = 0.0001 if `p_star' < 0.0001
	qui replace `p_star' = 0.9999 if `p_star' > 0.9999

	* Bernoulli draw.
	qui replace `depvar' = (runiform() < `p_star')

	di as txt "  Sampled y from Bernoulli(`link'(X·β*)). Fidelity check lives in" ///
		" the caller's post-rebuild comparison (Δβ/SE < 2)."
end

* -----------------------------------------------------------------------------
* _dm_constrain_poisson: direct Poisson DGP sampling.
*
* Given target β* (in `targets'), generate y from the Poisson DGP:
*     μ*_i = exp(X_i · β*)
*     y_i  ~ Poisson(μ*_i)
* Fitting `poisson y on X` on this y recovers β* within O(1/√N) sampling
* noise. Same design as _dm_constrain_nbreg but simpler (no overdispersion
* parameter, no Gamma mixture); Poisson is the α→0 limit of NB2.
*
* Why DGP and not iterative: iterative y-shift + clip at 0 + intercept
* correction works but carries three compounding approximations (the
* clip distorts the distribution, the intercept correction compensates
* for the shift's mean drift, and the overall procedure is less legible
* than "sample from the model"). DGP is the textbook Poisson process
* and matches nbreg's treatment for consistency.
* See docs/NBREG_DGP_DECISION.md for the
* general argument; Poisson is the same logic at α = 0.
*
* Signature kept identical to the other wrappers; max_iter / tolerance /
* learning_rate arguments are ignored.
* -----------------------------------------------------------------------------
program define _dm_constrain_poisson
	args cmdline targets varnames depvar

	di as txt _n "Adjusting Poisson model (direct Poisson DGP sampling)..."

	local ncoefs = rowsof(`targets')

	* Build the target linear predictor μ* = exp(X β*).
	tempvar xb mu_star
	qui gen double `xb' = 0

	forval i = 1/`ncoefs' {
		local target = `targets'[`i', 1]
		local varname : word `i' of `varnames'

		if "`varname'" == "_cons" {
			qui replace `xb' = `xb' + `target'
		}
		else if regexm("`varname'", "^([0-9]+)(b?)\.(.+)$") {
			local level = regexs(1)
			local is_base = regexs(2)
			local base_varname = regexs(3)
			if "`is_base'" != "b" {
				cap confirm variable `base_varname'
				if _rc == 0 {
					qui replace `xb' = `xb' + `target' * (`base_varname' == `level')
				}
			}
		}
		else {
			cap confirm variable `varname'
			if _rc == 0 {
				qui replace `xb' = `xb' + `target' * `varname'
			}
		}
	}

	qui gen double `mu_star' = exp(`xb')
	qui replace `depvar' = rpoisson(`mu_star')

	di as txt "  Sampled y from Poisson(exp(X·β*)). Fidelity check lives in" ///
		" the caller's post-rebuild comparison (Δβ/SE < 2)."
end

* -----------------------------------------------------------------------------
* _dm_constrain_nbreg: direct Gamma-Poisson DGP sampling.
*
* Given target β* (in `targets') and α* (`alpha_orig'), generate y from the
* NB2 data-generating process:
*     μ*_i = exp(X_i · β*)
*     λ_i  ~ Gamma(1/α*, α* · μ*_i)
*     y_i  ~ Poisson(λ_i)
* Marginally y_i | X_i ~ NB2(μ*_i, α*). By construction, `nbreg y on X`
* recovers β* within sampling error of order O(1/√N).
*
* Why not iterative: the NB2 score is weighted by 1/(1+α·μ) and β̂/α̂ are
* not orthogonal in finite samples (Lawless 1987; Kenne Pagui et al. 2022).
* Pinning α forces β onto a non-optimal ridge; unpinning makes α absorb
* misspecification and β diverges; clipping y ≥ 0 hits the MLE boundary
* (Lloyd-Smith 2007) and returns r(430). Full literature review and
* alternatives considered: docs/NBREG_DGP_DECISION.md.
*
* Factor variables are decoded from e(b) colnames: "2.education" becomes
* `β_2 · (education == 2)` in the linear predictor. Omitted/base level
* coefficients ("2b.education") contribute nothing to μ* (by construction).
*
* Signature kept identical to the other `_dm_constrain_*` wrappers so the
* Signature is (cmdline targets varnames depvar alpha_orig); the dispersion
* alpha is fixed at the original value because nbreg's score equation is
* non-orthogonal in (beta, alpha) so freely refitting would drift. See
* docs/NBREG_DGP_DECISION.md.
* -----------------------------------------------------------------------------
program define _dm_constrain_nbreg
	args cmdline targets varnames depvar alpha_orig

	di as txt _n "Adjusting negative binomial model (direct NB2 DGP sampling)..."
	di as txt "  Target dispersion α = " %6.4f `alpha_orig'

	local ncoefs = rowsof(`targets')

	* Build the target linear predictor μ* = exp(X β*).
	tempvar xb mu_star lambda
	qui gen double `xb' = 0

	forval i = 1/`ncoefs' {
		local target = `targets'[`i', 1]
		local varname : word `i' of `varnames'

		if "`varname'" == "_cons" {
			qui replace `xb' = `xb' + `target'
		}
		else if regexm("`varname'", "^([0-9]+)(b?)\.(.+)$") {
			* Factor variable: "2.education" → level 2 of education.
			* Base levels ("2b.") have coefficient 0 and contribute nothing.
			local level = regexs(1)
			local is_base = regexs(2)
			local base_varname = regexs(3)
			if "`is_base'" != "b" {
				cap confirm variable `base_varname'
				if _rc == 0 {
					qui replace `xb' = `xb' + `target' * (`base_varname' == `level')
				}
			}
		}
		else {
			* Plain continuous predictor.
			cap confirm variable `varname'
			if _rc == 0 {
				qui replace `xb' = `xb' + `target' * `varname'
			}
		}
	}

	qui gen double `mu_star' = exp(`xb')

	* Gamma-Poisson mixture: λ has mean μ*, variance α·μ*².
	* Stata's rgamma(shape, scale): mean = shape·scale, var = shape·scale².
	* We want mean = μ*, var = α·μ*² → shape = 1/α, scale = α·μ*.
	qui gen double `lambda' = rgamma(1/`alpha_orig', `alpha_orig' * `mu_star')
	qui replace `depvar' = rpoisson(`lambda')

	* Diagnostics: refit nbreg on the new y and report achieved Δβ.
	di as txt "  Sampled y from NB2(X·β*, α*). Fidelity checks live in the" ///
		" caller's post-rebuild comparison (Δβ/SE < 2)."
end
