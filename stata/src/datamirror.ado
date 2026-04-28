*! version {{VERSION}} {{DATE}}
* =============================================================================
* datamirror - Statistical Disclosure Control via Synthetic Data
* Main command dispatcher
* Usage: datamirror subcommand [options]
* =============================================================================

program define datamirror, rclass
	version 16.0

	* Core check: registream must be installed. Each package ships its own
	* files only; modules depend on core being present on adopath. See
	* registream-docs/architecture/version_coordination.md.
	cap findfile _rs_utils.ado
	if _rc != 0 {
		di as error ""
		di as error "registream core is not installed."
		di as error ""
		di as error "datamirror requires the registream core package. Install it first:"
		di as error `"  ssc install registream"'
		di as error "  (or from GitHub:)"
		di as error `"  net install registream, from("https://registream.org/install/stata/registream/latest") replace"'
		di as error ""
		exit 198
	}

	* Min-core version check (Phase 4 of version_coordination.md). MIN_CORE
	* is build-injected from packages.json; in source mode it stays as the
	* literal placeholder, which the regex guard treats as "skip".
	local DATAMIRROR_MIN_CORE "{{MIN_CORE}}"
	if (regexm("`DATAMIRROR_MIN_CORE'", "^[0-9]")) {
		_rs_check_core_version "datamirror" "`DATAMIRROR_MIN_CORE'"
	}

	* Get core version from registream core (must be installed)
	_rs_utils get_version
	local REGISTREAM_VERSION "`r(version)'"

	* Datamirror module version (stamped from packages.json by export_package.py)
	local DATAMIRROR_VERSION "{{VERSION}}"

	* ==========================================================================
	* MASTER WRAPPER (START): Usage tracking
	* Runs for ALL datamirror commands
	* ==========================================================================
	_datamirror_wrapper_start "`REGISTREAM_VERSION'" "`DATAMIRROR_VERSION'" `"`0'"'
	local registream_dir "`r(registream_dir)'"

	* Parse first argument to determine subcommand
	gettoken subcmd 0 : 0, parse(" ,")
	local subcmd = subinstr("`subcmd'", ",", "", .)

	* ==========================================================================
	* META SUBCOMMANDS (version, cite) — handled locally
	* ==========================================================================
	if ("`subcmd'" == "version") {
		di as text "datamirror version " as result "`DATAMIRROR_VERSION'"
		di as text "registream core version " as result "`REGISTREAM_VERSION'"
		_datamirror_wrapper_end "`REGISTREAM_VERSION'" "`DATAMIRROR_VERSION'" "`registream_dir'" `"`0'"'
		exit 0
	}
	else if ("`subcmd'" == "cite") {
		_datamirror_cite "`DATAMIRROR_VERSION'"
		_datamirror_wrapper_end "`REGISTREAM_VERSION'" "`DATAMIRROR_VERSION'" "`registream_dir'" `"`0'"'
		exit 0
	}

	* ==========================================================================
	* CORE SUBCOMMANDS (init, checkpoint, extract, rebuild, check, close)
	* ==========================================================================
	if ("`subcmd'" == "init") {
		_dm_utils init `0'
		return add
	}
	else if ("`subcmd'" == "checkpoint") {
		_dm_utils checkpoint `0'
		return add
	}
	else if ("`subcmd'" == "extract") {
		_dm_utils extract `0'
		return add
	}
	else if ("`subcmd'" == "rebuild") {
		_dm_utils rebuild `0'
		return add
	}
	else if ("`subcmd'" == "check") {
		_dm_utils check `0'
		return add
	}
	else if ("`subcmd'" == "close") {
		_dm_utils close `0'
		return add
	}
	else if ("`subcmd'" == "status") {
		_dm_utils status `0'
		return add
	}
	else if ("`subcmd'" == "auto") {
		_dm_utils auto `0'
		return add
	}
	else {
		_datamirror_wrapper_end "`REGISTREAM_VERSION'" "`DATAMIRROR_VERSION'" "`registream_dir'" `"`0'"'
		di as error "Unknown datamirror subcommand: `subcmd'"
		di as error "Valid subcommands: init, checkpoint, auto, extract, rebuild, check, close, status, version, cite"
		exit 198
	}

	* ==========================================================================
	* MASTER WRAPPER (END): Heartbeat (telemetry + update check)
	* ==========================================================================
	_datamirror_wrapper_end "`REGISTREAM_VERSION'" "`DATAMIRROR_VERSION'" "`registream_dir'" `"`0'"'
end

* =============================================================================
* MASTER WRAPPER FUNCTIONS
* =============================================================================

* Wrapper start: initialize config + log local usage
program define _datamirror_wrapper_start, rclass
	* gettoken preserves inner quotes in command_line
	gettoken current_version 0 : 0
	gettoken datamirror_version 0 : 0
	gettoken command_line 0 : 0

	* Get registream directory from core
	_rs_utils get_dir
	local registream_dir "`r(dir)'"
	return local registream_dir "`registream_dir'"

	* Initialize config (first-run wizard handled by core)
	_rs_config init "`registream_dir'"

	* Log local usage if enabled
	_rs_config get "`registream_dir'" "usage_logging"
	if (r(value) == "true" | r(value) == "1") {
		_rs_usage init "`registream_dir'"
		_rs_usage log "`registream_dir'" `"datamirror `command_line'"' "datamirror" "`datamirror_version'" "`current_version'"
	}
end

* Wrapper end: consolidated heartbeat (telemetry + update check) + notification
program define _datamirror_wrapper_end
	gettoken current_version 0 : 0
	gettoken datamirror_version 0 : 0
	gettoken registream_dir 0 : 0
	gettoken command_line 0 : 0

	* Get registream directory if not provided
	if ("`registream_dir'" == "") {
		_rs_utils get_dir
		local registream_dir "`r(dir)'"
	}

	* Parse command for conditional logic.
	* Compound-quote the inclusion — command_line carries embedded double-quotes
	* (e.g. checkpoint_dir("..."), cluster("...")) and a plain "`command_line'"
	* test mistokenises the path after the first closing quote (r(111)).
	if (`"`command_line'"' != "") {
		gettoken first_word rest : command_line, parse(" ,")
	}

	* Check if we should send a heartbeat
	_rs_config get "`registream_dir'" "telemetry_enabled"
	local telemetry_enabled = r(value)
	_rs_config get "`registream_dir'" "internet_access"
	local internet_access = r(value)
	_rs_config get "`registream_dir'" "auto_update_check"
	local auto_update_enabled = r(value)

	if ("`auto_update_enabled'" == "") local auto_update_enabled "true"

	local should_heartbeat = 0
	if (("`telemetry_enabled'" == "true" | "`telemetry_enabled'" == "1" | "`auto_update_enabled'" == "true" | "`auto_update_enabled'" == "1") & ("`internet_access'" == "true" | "`internet_access'" == "1")) {
		local should_heartbeat = 1
	}

	local core_update 0
	local core_latest ""
	local dm_update 0
	local dm_latest ""

	if (`should_heartbeat' == 1) {
		* Positional args: dir ver cmd module module_version al_ver dm_ver
		cap qui _rs_updates send_heartbeat "`registream_dir'" "`current_version'" ///
			`"datamirror `command_line'"' "datamirror" "`datamirror_version'" "" ""
		local core_update = r(update_available)
		local core_latest "`r(latest_version)'"
		local dm_update = r(datamirror_update)
		local dm_latest "`r(datamirror_latest)'"
	}

	* Show update notification for core + datamirror only. Autolabel banners
	* belong to autolabel-triggered heartbeats and explicit `registream update`.
	cap _rs_updates show_notification , ///
		current_version("`current_version'") scope(datamirror) ///
		core_update(`core_update') core_latest("`core_latest'") ///
		datamirror_update(`dm_update') datamirror_latest("`dm_latest'")
end

* =============================================================================
* CITATION
* -----------------------------------------------------------------------------
* Separate sub-program so the build-time placeholder below is quarantined.
* Stata parses the body of this program only when `datamirror cite` is called,
* not when the main `datamirror` program is loaded. Same pattern as
* autolabel's _autolabel_cite.
* =============================================================================
program define _datamirror_cite
	version 16.0
	* Caller passes the stamped datamirror version as the first positional
	* arg so the citation block below can expand it via backtick-quoted
	* macro. See registream/tools/render_citations.py _VERSION_LOCALS.
	gettoken DATAMIRROR_VERSION 0 : 0
	di as text _n "To cite datamirror in a publication:"
	di as text ""
{{CITATION_DATAMIRROR_ADO_CITE_BLOCK}}
end
