#!/usr/bin/env bash
# ui.sh — shared terminal UI for the *-status commands.
#
# Installed to /usr/local/lib/pi-server/ui.sh; sourced, never executed.
# Provides: row, sub, hr, section, bar, state_for, say  +  $FAILED accounting.
#
# Design rules:
#   ✔ green  — fine            ! yellow — worth a look         ✖ red — broken
#   Colors are emitted only for a real terminal, so pipes and logs stay clean.

export LC_ALL=${LC_ALL:-C.UTF-8}   # ${#str} must count characters, not bytes

QUIET=${QUIET:-0}
FAILED=0
LABEL_WIDTH=${LABEL_WIDTH:-16}

if [ -t 1 ] && [ "$QUIET" = 0 ]; then
    B=$'\033[1m'; DIM=$'\033[2m'; G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'
else
    B=''; DIM=''; G=''; R=''; Y=''; C=''; N=''
fi

say() { [ "$QUIET" = 0 ] && printf '%s\n' "$*"; return 0; }

# row <ok|fail|warn|info> <label> <value>   — one aligned line; 'fail' sets $FAILED
row() {
    local state=$1 label=$2 value=$3 icon color pad
    case $state in
        ok)   icon='✔'; color=$G ;;
        fail) icon='✖'; color=$R; FAILED=1 ;;
        warn) icon='!'; color=$Y ;;
        *)    icon=' '; color=$DIM ;;
    esac
    pad=$(( LABEL_WIDTH - ${#label} ))
    [ $pad -lt 1 ] && pad=1
    [ "$QUIET" = 1 ] && return 0
    printf '  %s%s%s %s%*s%s\n' "$color" "$icon" "$N" "$label" "$pad" '' "$value"
}

sub()     { [ "$QUIET" = 0 ] && printf '    %s· %s%s\n' "$DIM" "$1" "$N"; return 0; }
hr()      { say "${DIM}  ────────────────────────────────────────────────${N}"; }
section() { say; say "  ${B}${C}$1${N}"; }

title() {  # title <name> <subtitle>
    say
    say "  ${B}${C}$1${N}${DIM} · $2${N}"
    hr
}

# bar <percent> — 20-cell gauge: green, yellow from 75%, red from 90%
bar() {
    local pct=$1 filled i out='' color
    [ -z "$pct" ] && pct=0
    [ "$pct" -gt 100 ] && pct=100
    filled=$(( pct / 5 ))
    if   [ "$pct" -ge 90 ]; then color=$R
    elif [ "$pct" -ge 75 ]; then color=$Y
    else color=$G; fi
    for ((i = 0; i < 20; i++)); do [ $i -lt $filled ] && out+='█' || out+='·'; done
    printf '%s%s%s' "$color" "$out" "$N"
}

# state_for <percent> — keeps icon and bar color in agreement
state_for() {
    if   [ "$1" -ge 90 ]; then echo fail
    elif [ "$1" -ge 75 ]; then echo warn
    else echo ok; fi
}

# verdict <ok-text> <fail-text> — closing line, returns the exit code to use
verdict() {
    hr
    if [ "$FAILED" = 0 ]; then say "  ${G}${B}$1${N}"; else say "  ${R}${B}$2${N}"; fi
    say
    return "$FAILED"
}

# Passwordless sudo available? Status commands degrade gracefully without it.
SUDO=""
sudo -n true 2>/dev/null && SUDO="sudo -n"
