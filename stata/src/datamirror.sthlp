{smcl}
{* *! version {{VERSION}} {{STHLP_DATE}}}{...}

{vieweralsosee "" "--"}{...}
{vieweralsosee "registream" "help registream"}{...}
{vieweralsosee "autolabel" "help autolabel"}{...}
{viewerjumpto "Syntax" "datamirror##syntax"}{...}
{viewerjumpto "Description" "datamirror##description"}{...}
{viewerjumpto "Architecture: four layers" "datamirror##architecture"}{...}
{viewerjumpto "Subcommands" "datamirror##subcommands"}{...}
{viewerjumpto "Supported models" "datamirror##models"}{...}
{viewerjumpto "Fidelity metric" "datamirror##fidelity"}{...}
{viewerjumpto "Privacy" "datamirror##privacy"}{...}
{viewerjumpto "Reproducibility" "datamirror##reproducibility"}{...}
{viewerjumpto "Examples" "datamirror##examples"}{...}
{viewerjumpto "Stored results" "datamirror##results"}{...}
{viewerjumpto "Known limitations" "datamirror##limitations"}{...}
{viewerjumpto "See also" "datamirror##seealso"}{...}
{viewerjumpto "Author" "datamirror##author"}{...}
{viewerjumpto "Citing datamirror" "datamirror##citation"}{...}

{title:Title}

{p2colset 5 18 20 2}{...}
{p2col :{cmd:datamirror} {hline 2}}Synthetic microdata that preserves regression coefficients{p_end}
{p2colreset}{...}

{pstd}
Part of the {help registream:RegiStream} ecosystem for register data research.
{p_end}

{pstd}
Requires Stata 16 or later.
{p_end}


{marker syntax}{...}
{title:Syntax}

{pstd}
{ul:Session management}
{p_end}

{p 8 15 2}
{cmd:datamirror init}{cmd:,} {opth checkpoint_dir(string)}
[{opth strata(varname)} {opt replace} {opt clear} {opth min_cell_size(integer)} {opth quantile_trim(real)}]
{p_end}

{p 8 15 2}
{cmd:datamirror close}
{p_end}

{pstd}
{ul:During an analysis session}
{p_end}

{p 8 15 2}
{it:(run estimation command)}{break}
{cmd:datamirror checkpoint} [{cmd:,} {opth tag(string)} {opth notes(string)}]
{p_end}

{p 8 15 2}
{cmd:datamirror auto} {it:estimation_cmd}
{p_end}

{p 8 15 2}
{cmd:datamirror status}
{p_end}

{p 8 15 2}
{cmd:datamirror extract}
{p_end}

{pstd}
{ul:Reconstruction (from checkpoint directory, fresh session)}
{p_end}

{p 8 15 2}
{cmd:datamirror rebuild} [{cmd:using}] [{it:checkpoint_dir}]{cmd:,} [{opth seed(integer)} {opt clear} {opt verify}]
{p_end}

{p 8 15 2}
{cmd:datamirror check} [{cmd:using}] [{it:checkpoint_dir}]
{p_end}

{pstd}
{ul:Meta}
{p_end}

{p 8 15 2}
{cmd:datamirror version}
{p_end}

{p 8 15 2}
{cmd:datamirror cite}
{p_end}


{marker description}{...}
{title:Description}

{pstd}
{cmd:datamirror} generates synthetic microdata that preserves both
the univariate and bivariate distributional structure of a real
dataset and, additionally, the coefficient estimates of regressions
the researcher marks as important. This separates datamirror from
general-purpose synthetic-data tools, which preserve moments but
make no guarantees about downstream regression output.
{p_end}

{pstd}
The intended workflow has two parties. A data curator (or a
researcher with access to confidential microdata) runs the analysis
interactively, tagging selected regressions with {cmd:datamirror checkpoint},
then writes distributional metadata and checkpoint specifications to
a disclosure-safe output directory via {cmd:datamirror extract}. A
downstream user -- a coauthor, a replication reviewer, a developer
on a personal machine -- runs {cmd:datamirror rebuild} on that output
directory to reconstruct a synthetic dataset on which the original
regression specifications produce the published coefficient
estimates within sampling noise. No confidential data crosses the
boundary.
{p_end}

{pstd}
The approach is thus a {it:statistical-disclosure-control} tool with
an auditable, parametric footprint: only summary statistics and
regression coefficients leave the original environment. It does not
offer a differential-privacy guarantee; the privacy mechanism is
cell-size suppression configurable via
{help datamirror##min_cell_size:{cmd:min_cell_size()}} and described
in {help datamirror##privacy:Privacy} below.
{p_end}


{marker architecture}{...}
{title:Architecture: four layers}

{pstd}
Every synthetic dataset is reconstructed from on-disk summaries
organized into four layers. The first three layers reproduce
distributional structure; the fourth pins regression coefficients.
{p_end}

{p2colset 5 24 26 2}{...}
{p2col :Layer 1, marginals} per-variable quantile vector for
continuous variables, category frequency table for discrete variables{p_end}
{p2col :Layer 2, correlations} Pearson correlation matrix computed on
normalized ranks (copula correlations), both overall and within
strata if {opt strata()} was specified{p_end}
{p2col :Layer 3, copula sampling} Gaussian copula draws
parameterised by Layer 1 marginals and Layer 2 correlations{p_end}
{p2col :Layer 4, checkpoint constraints} coefficient-preserving layer:
given the sampled X from Layer 3, y is shifted (for linear models)
or resampled (for generalized linear models) so that re-running each
checkpointed regression on the synthetic data returns the published
coefficient vector within sampling noise{p_end}
{p2colreset}{...}


{marker subcommands}{...}
{title:Subcommands}

{dlgtab:init}

{p 8 15 2}
{cmd:datamirror init}{cmd:,} {opth checkpoint_dir(string)}
[{opth strata(varname)} {opt replace} {opt clear} {opth min_cell_size(integer)} {opth quantile_trim(real)}]
{p_end}

{phang}
Start a new checkpoint session. The working dataset in memory is the
source data; it is not modified. {cmd:checkpoint_dir()} names the
directory where metadata and checkpoint specifications will be
written by {cmd:datamirror extract}.
{p_end}

{phang2}
{opth strata(varname)} stratify Layer 2 correlations by a
categorical variable (typically a panel wave or a treatment
indicator). Stratified correlations are preserved within stratum in
the rebuild.
{p_end}

{phang2}
{marker min_cell_size}{...}
{opth min_cell_size(integer)} privacy suppression threshold for
Layer 1 frequency cells. Categories with fewer than this many
observations are suppressed at extract time; under stratification,
strata with fewer than this many observations are also skipped from
the stratified continuous marginals and stratified correlations.
Defaults to 50 or to the package-level setting read from
{help registream:registream config}. See {help datamirror##privacy:Privacy}.
{p_end}

{phang2}
{marker quantile_trim}{...}
{opth quantile_trim(real)} continuous-variable SDC threshold, in
percent. The {cmd:q0} and {cmd:q100} columns of
{cmd:marginals_cont.csv} are top- and bottom-coded at this percentile.
The default of 1 plateaus {cmd:q0} at the 1st percentile and
{cmd:q100} at the 99th, retiring raw max/min as classified unsafe
by the Brandt-Franconi ESSnet guidelines. Must be a non-negative
real between 0 and 50. Three-tier resolution: this option, then
{help registream:registream config}, then the source-level default
of 1. Set to 0 only if the data were top- and bottom-coded upstream.
See {help datamirror##privacy:Privacy}.
{p_end}

{phang2}
{opt replace} overwrite an existing checkpoint directory.
{p_end}

{phang2}
{opt clear} clear any active checkpoint session before starting a
new one.
{p_end}

{dlgtab:checkpoint}

{p 8 15 2}
{cmd:datamirror checkpoint} [{cmd:,} {opth tag(string)} {opth notes(string)}]
{p_end}

{phang}
Record the most recently executed estimation command as a
checkpoint. Must follow {cmd:regress}, {cmd:reghdfe},
{cmd:ivregress 2sls}, {cmd:logit}, {cmd:probit}, {cmd:poisson}, or
{cmd:nbreg}. The command line, estimation sample, coefficient
vector, standard errors, and (for {cmd:nbreg}) dispersion alpha are
captured in memory. Multiple checkpoints may be recorded per session.
If called with no active session, prompts to initialize one in the
current directory. If the same regression (same {it:cmd}, {it:cmdline},
and {it:N}) is already captured, the call no-ops with a message
rather than storing a duplicate -- useful when scripts mix
{cmd:datamirror auto} and explicit {cmd:datamirror checkpoint}.
{p_end}

{phang2}
{opth tag(string)} a unique identifier for the checkpoint
(for example {cmd:"table2_col3"}). If omitted, a tag is auto-generated
as {it:<cmd>_<counter>} (for example {cmd:regress_1}).
{p_end}

{phang2}
{opth notes(string)} free-text notes attached to the checkpoint.
{p_end}

{dlgtab:auto}

{p 8 15 2}
{cmd:datamirror auto} {it:estimation_cmd}
{p_end}

{phang}
Prefix for an estimation command. Runs {it:estimation_cmd} as typed,
then calls {cmd:datamirror checkpoint} with an auto-generated tag.
The ergonomic counterpart to explicit {cmd:checkpoint}: one line per
regression instead of two. Example:
{p_end}

{p 12 15 2}
{cmd:datamirror auto regress wellbeing age i.education female}
{p_end}

{phang}
Equivalent to running the regression followed by
{cmd:datamirror checkpoint}. Mix with explicit
{cmd:datamirror checkpoint, tag("...")} freely when you want a
specific tag for a particular regression.
{p_end}

{dlgtab:extract}

{p 8 15 2}
{cmd:datamirror extract}
{p_end}

{phang}
Write Layer 1 marginals, Layer 2 correlations, schema, and per-
checkpoint coefficient files to the checkpoint directory. Applies
{cmd:min_cell_size} suppression to Layer 1 categorical counts. The
resulting directory is the disclosure-safe artifact: it contains no
individual-level data.
{p_end}

{dlgtab:rebuild}

{p 8 15 2}
{cmd:datamirror rebuild} [{cmd:using}] [{it:checkpoint_dir}]{cmd:,}
[{opth seed(integer)} {opt clear} {opt verify}]
{p_end}

{phang}
Reconstruct a synthetic dataset from an on-disk checkpoint
directory. Runs Layers 1-4: loads marginals, loads correlations,
draws a Gaussian copula sample, then applies the coefficient-
preserving constraint layer.
{p_end}

{phang2}
{opth seed(integer)} random seed for the copula draw. The same seed
with the same checkpoint directory produces bit-for-bit identical
synthetic data.
{p_end}

{phang2}
{opt clear} drop the current in-memory dataset before loading.
{p_end}

{phang2}
{opt verify} after rebuild, re-run every checkpointed regression on
the synthetic data and report {it:Delta beta over SE} for each
coefficient. Equivalent to calling {cmd:datamirror check} with the
same directory.
{p_end}

{dlgtab:check}

{p 8 15 2}
{cmd:datamirror check} [{cmd:using}] [{it:checkpoint_dir}]
{p_end}

{phang}
Re-run every checkpointed regression on the synthetic data and
compare the fitted coefficient to the published target. Reports
{it:Delta beta over SE} for each coefficient.
{p_end}

{dlgtab:close}

{p 8 15 2}
{cmd:datamirror close}
{p_end}

{phang}
End the current checkpoint session, freeing in-memory state.
{p_end}

{dlgtab:status}

{p 8 15 2}
{cmd:datamirror status}
{p_end}

{phang}
Report the current session at a glance: checkpoint directory,
stratification variable, min_cell_size, dataset dimensions at
{cmd:init}, and a one-row-per-checkpoint table of tag, command,
dependent variable, and estimation N. Intended for mid-script
debugging -- call it when the output of {cmd:checkpoint} scrolls
past and you need to see what has been captured so far.
{p_end}


{marker models}{...}
{title:Supported models}

{pstd}
Layer 4 uses one principled method per family.
{p_end}

{p2colset 5 24 26 2}{...}
{p2col :{cmd:regress}} closed-form Newton step via {cmd:matrix score}{p_end}
{p2col :{cmd:reghdfe}} closed-form Newton on the fixed-effects-absorbed design{p_end}
{p2col :{cmd:ivregress 2sls}} weighted-Frisch-Waugh-Lovell Newton step on the residualized design, with first-stage-F diagnostic{p_end}
{p2col :{cmd:ivregress 2sls} (shared-outcome groups)} joint stacked min-norm Newton across all coefficient constraints simultaneously{p_end}
{p2col :{cmd:logit}} direct Bernoulli data-generating process at the target linear predictor{p_end}
{p2col :{cmd:probit}} direct Bernoulli DGP with probit link{p_end}
{p2col :{cmd:poisson}} direct Poisson DGP at target exp(xb){p_end}
{p2col :{cmd:nbreg}} direct Gamma-Poisson DGP with alpha fixed at the original dispersion{p_end}
{p2colreset}{...}

{pstd}
Factor variables, interactions, and analytic weights are handled
natively by all estimators. Cluster-robust standard errors are
respected for the fidelity metric.
{p_end}


{marker fidelity}{...}
{title:Fidelity metric}

{pstd}
The fidelity of a synthetic dataset for a given checkpointed
regression is measured by {it:Delta beta over SE}, the absolute
distance between synthetic beta-hat and target beta* expressed in
units of the synthetic regression's own standard error.
{p_end}

{pstd}
A typical target is {it:Delta beta over SE} less than 3. This
corresponds to a joint 99% confidence interval over 3-5 coefficients
per checkpoint after Bonferroni adjustment, which is the regime
under which inference on the synthetic dataset matches inference on
the original within sampling noise.
{p_end}

{pstd}
Across four American Economic Association replication packages
(Duflo-Hanna-Ryan 2012, Dupas-Robinson 2013, Banerjee et al. 2015,
Autor-Dorn-Hanson 2019) the package reproduces 349 of 353
checkpointed regressions at {it:Delta beta over SE} less than 3.
{p_end}


{marker privacy}{...}
{title:Privacy}

{pstd}
The privacy mechanism is cell-size suppression. Layer 1
frequency cells with fewer than {cmd:min_cell_size} observations are
removed at extract time and do not appear in the output directory.
The threshold is recorded in {cmd:metadata.csv} and can be audited
alongside the suppression counts ({cmd:n_cat_suppressed},
stratified variants).
{p_end}

{pstd}
Layer 2 correlations are computed only within strata that clear the
threshold. Strata below the threshold are skipped; their skip count
is recorded in {cmd:metadata.csv} as {cmd:n_strata_skipped_corr}.
Stratified continuous marginals gate on the same threshold, with
small strata skipped from {cmd:marginals_cont_stratified.csv} and
counted as {cmd:n_strata_skipped_cont}.
{p_end}

{pstd}
Continuous marginals additionally apply {cmd:quantile_trim} (default
1). The {cmd:q0} and {cmd:q100} columns of {cmd:marginals_cont.csv}
are plateaued at the 1st and 99th percentiles by default, retiring
the raw max/min entries classified as unsafe by the Brandt-Franconi
ESSnet output-checking guidelines. The resolved trim is recorded in
{cmd:metadata.csv} as {cmd:dm_quantile_trim}.
{p_end}

{pstd}
Layer 4 checkpoint coefficients are the originally published
coefficient values; they carry no additional individual-level
information beyond what the researcher already reports in their
paper.
{p_end}

{pstd}
The package does not offer a differential-privacy guarantee. For DP
requirements, compose a DP mechanism on top of the extract-layer
summaries.
{p_end}


{marker reproducibility}{...}
{title:Reproducibility}

{pstd}
A checkpoint directory is an immutable artifact. {cmd:datamirror rebuild}
with the same seed and the same directory produces bit-for-bit
identical synthetic data. A do-file that rebuilds from a checkpoint
directory saved today produces the same synthetic dataset when re-run
in five years; the rebuild has no external dependencies beyond the
Stata version and the {cmd:datamirror} and {cmd:registream} packages.
{p_end}


{marker examples}{...}
{title:Examples}

{pstd}
{ul:End-to-end round trip}
{p_end}

{phang}{stata `"sysuse auto, clear"'}

{phang}{stata `"datamirror init, checkpoint_dir("mirror_out") replace"'}

{phang}{stata `"regress price mpg weight foreign"'}

{phang}{stata `"datamirror checkpoint, tag("price_model")"'}

{phang}{stata `"datamirror extract"'}

{phang}{stata `"datamirror rebuild using "mirror_out", clear seed(12345)"'}

{phang}{stata `"regress price mpg weight foreign"'} {it:(returns coefficients close to the original)}

{phang}{stata `"datamirror check using "mirror_out""'}

{pstd}
{ul:Panel data with stratification}
{p_end}

{phang}{stata `"use panel_data.dta, clear"'}

{phang}{stata `"datamirror init, checkpoint_dir("panel_out") strata(wave) replace"'}

{phang}{stata `"regress outcome treatment age i.education"'}

{phang}{stata `"datamirror checkpoint, tag("main_effect")"'}

{phang}{stata `"datamirror extract"'}

{phang}{stata `"datamirror rebuild using "panel_out", clear seed(42)"'}

{pstd}
{ul:Instrumental variables with shared-outcome specs}
{p_end}

{phang}{stata `"ivregress 2sls y (x1 = z1) w1 w2"'}

{phang}{stata `"datamirror checkpoint, tag("iv_main")"'}

{phang}{stata `"ivregress 2sls y (x2 x3 = z2 z3) w1 w2"'}

{phang}{stata `"datamirror checkpoint, tag("iv_gender")"'}

{pstd}
Both specs share the outcome {cmd:y}. {cmd:datamirror rebuild} applies a
joint Newton step across the group, pinning both coefficient vectors
simultaneously.
{p_end}


{marker results}{...}
{title:Stored results}

{pstd}
{cmd:datamirror init} stores:
{p_end}

{synoptset 20 tabbed}{...}
{synopt:{cmd:r(checkpoint_dir)}}checkpoint directory path{p_end}
{synopt:{cmd:r(min_cell_size)}}resolved suppression threshold{p_end}
{synopt:{cmd:r(strata)}}strata variable name, if any{p_end}

{pstd}
{cmd:datamirror checkpoint} stores:
{p_end}

{synopt:{cmd:r(tag)}}checkpoint tag{p_end}
{synopt:{cmd:r(cmd)}}estimation command name{p_end}
{synopt:{cmd:r(N)}}estimation sample size{p_end}
{synopt:{cmd:r(ncoefs)}}number of coefficients stored{p_end}

{pstd}
{cmd:datamirror check} stores:
{p_end}

{synopt:{cmd:r(max_dse)}}maximum {it:Delta beta over SE} observed across checkpoints{p_end}
{synopt:{cmd:r(n_passed)}}checkpoints passing the fidelity threshold{p_end}
{synopt:{cmd:r(n_failed)}}checkpoints failing the threshold{p_end}


{marker limitations}{...}
{title:Known limitations}

{pstd}
{ul:Not yet supported}: {cmd:ologit}, {cmd:oprobit}, {cmd:mlogit},
{cmd:stcox}, {cmd:tobit}, {cmd:ivpoisson}, {cmd:ivregress liml},
{cmd:ivregress gmm} with a non-default weight matrix. Attempting
{cmd:datamirror checkpoint} after these commands produces a clean
not-supported error.
{p_end}

{pstd}
{ul:Nested-regressor shared-outcome OLS}: when multiple
{cmd:regress} specifications share an outcome with nested regressor
sets, cyclic Newton converges but slowly. Joint OLS is a direction
for future work via an accelerated-projection approach.
{p_end}

{pstd}
{ul:Rare binaries}: Gaussian copula correlations are not well
preserved for binary variables with prevalence below roughly 0.1.
Coefficient estimates for regressions involving such variables may
have elevated {it:Delta beta over SE}. A warning is emitted at
extract time.
{p_end}

{pstd}
{ul:Outcome marginal distribution}: for generalized linear models,
y is resampled from the model's data-generating process; the sample
proportion or mean may differ from the observed y by O(1/sqrt(N)).
This is by design.
{p_end}


{marker seealso}{...}
{title:See also}

{pmore}
{help autolabel:autolabel}: automatic variable and value labeling from structured metadata
{p_end}

{pmore}
{help registream:registream}: RegiStream core, configuration, updates, and telemetry
{p_end}

{pmore2}
{hline 2} View configuration: {cmd:registream info}{break}
{hline 2} Change settings: {cmd:registream config, option(value)}{break}
{hline 2} Check package updates: {cmd:registream update}
{p_end}


{marker author}{...}
{title:Author}

{pstd}Jeffrey Clark{break}
{{AFFILIATION_JEFFREY}}{break}
Email: {browse "mailto:{{EMAIL_JEFFREY}}":{{EMAIL_JEFFREY}}}
{p_end}


{marker citation}{...}
{title:Citing datamirror}

{pstd}
{cmd:datamirror} is part of the {help registream:RegiStream} ecosystem.
Please cite the package as:
{p_end}

{pstd}
{{CITATION_DATAMIRROR_STHLP_APA_VERSIONED}}
{p_end}
