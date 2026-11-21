# Shared assertion helpers. Source this file; never run it.
#
# Every check writes one TSV row to $RESULTS:
#   job <TAB> check-id <TAB> PASS|FAIL|KNOWN|WARN|INFO <TAB> message
# A FAIL whose id is listed in $KNOWN_ISSUES (space separated) is recorded as
# KNOWN instead, so the nightly stays green for broken things we already know
# about and turns red only on a new regression.

: "${JOB_LABEL:=local}"
: "${RESULTS:=${RUNNER_TEMP:-/tmp}/results-${JOB_LABEL}.tsv}"
: "${KNOWN_ISSUES:=}"
export RESULTS

record() {
	local id=$1 status=$2 msg=$3
	if [ "$status" = FAIL ] && [[ " $KNOWN_ISSUES " == *" $id "* ]]; then
		status=KNOWN
	fi
	msg=${msg//$'\t'/ }
	msg=${msg//$'\n'/ }
	printf '%s\t%s\t%s\t%s\n' "$JOB_LABEL" "$id" "$status" "$msg" >>"$RESULTS"
	case $status in
	FAIL) echo "::error title=$id::$msg" ;;
	KNOWN | WARN) echo "::warning title=$id::$msg" ;;
	esac
	echo "[$status] $id: $msg"
}
pass() { record "$1" PASS "$2"; }
fail() { record "$1" FAIL "$2"; }
warn() { record "$1" WARN "$2"; }
info() { record "$1" INFO "$2"; }

# eq <id> <want> <got> <what>
eq() {
	if [ "$2" = "$3" ]; then pass "$1" "$4 = $3"; else fail "$1" "$4: want '$2', got '$3'"; fi
}

# check <id> <description> <command...>: PASS when the command succeeds.
check() {
	local id=$1 what=$2
	shift 2
	if "$@" >/dev/null 2>&1; then pass "$id" "$what"; else fail "$id" "$what"; fi
}

# tmo <seconds> <command...>: GNU timeout is missing on macOS runners.
tmo() {
	local t=$1
	shift
	if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"; else perl -e 'alarm shift; exec @ARGV' "$t" "$@"; fi
}

# http_status <url>: final status code after redirects.
http_status() { curl -sSL -o /dev/null -w '%{http_code}' --retry 2 "$1" 2>/dev/null || echo 000; }

# finish: print the job's table into the step summary and fail on any FAIL.
finish() {
	touch "$RESULTS"
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		{
			echo "### $JOB_LABEL"
			echo
			echo "| check | status | detail |"
			echo "|---|---|---|"
			awk -F'\t' '{ gsub(/\|/, "\\|", $4); printf "| %s | %s | %s |\n", $2, $3, $4 }' "$RESULTS"
			echo
		} >>"$GITHUB_STEP_SUMMARY"
	fi
	if awk -F'\t' '$3=="FAIL"{found=1} END{exit !found}' "$RESULTS"; then
		echo "Unexpected failures:" >&2
		awk -F'\t' '$3=="FAIL"' "$RESULTS" >&2
		return 1
	fi
	return 0
}
