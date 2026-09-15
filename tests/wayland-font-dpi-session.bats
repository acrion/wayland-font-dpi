#!/usr/bin/env bats
# Tests for wayland-font-dpi-session. Run from the root of the repository:
# bats tests

SCRIPT="$BATS_TEST_DIRNAME/../wayland-font-dpi-session"

setup() {
    CACHE="$BATS_TEST_TMPDIR/cache"
    STUBS="$BATS_TEST_TMPDIR/stubs"
    GSETTINGS_LOG="$BATS_TEST_TMPDIR/gsettings.log"
    SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    USER_ENVIRONMENT="$BATS_TEST_TMPDIR/user-environment"
    DAEMON_LOG="$BATS_TEST_TMPDIR/daemon.log"
    DAEMON_PID=
    mkdir -p "$CACHE" "$STUBS"

    # The environment of the person executing the tests must not decide the
    # result: a COSMIC session or a display-manager USER would cause main to
    # exit early. GSETTINGS_BACKEND=memory keeps the actual gsettings separated
    # from the desktop settings even if the stub below cannot be run, for
    # instance on a noexec TMPDIR.
    export USER=tester XDG_CURRENT_DESKTOP=niri GSETTINGS_BACKEND=memory

    # A stub records the gsettings calls instead of changing the desktop
    # settings of whoever runs the tests.
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$GSETTINGS_LOG" > "$STUBS/gsettings"
    # The systemctl stub serves the systemd user environment from a file, so
    # the tests never query or change the real user manager.
    printf '#!/bin/sh\necho "$*" >> "%s"\n[ "$*" = "--user show-environment" ] && cat "%s" 2>/dev/null\nexit 0\n' \
        "$SYSTEMCTL_LOG" "$USER_ENVIRONMENT" > "$STUBS/systemctl"
    chmod +x "$STUBS/gsettings" "$STUBS/systemctl"
    PATH="$STUBS:$PATH"
}

teardown() {
    # Signal only processes in the daemon's process group whose command line
    # names this test's cache, so that a reused PID can never take unrelated
    # processes with it.
    if [[ -n $DAEMON_PID ]]; then
        pkill -g "$DAEMON_PID" -f "$CACHE" 2>/dev/null || true
    fi
}

# Replaces display-info just as wayland-display-info does: write a
# temporary file, then rename it over the cache file.
publish() {
    printf '%s' "$1" > "$CACHE/display-info.tmp"
    mv "$CACHE/display-info.tmp" "$CACHE/display-info"
}

# Runs a command with the session script sourced and its cache diverted to
# the test directory. The timeout turns a main that keeps running, for
# instance after a broken early exit, into a failure rather than a hanging
# suite.
session() {
    # shellcheck disable=SC2016
    timeout 10 bash -c 'source "$1"; CACHE_DIR=$2; CACHE_FILE=$2/display-info; DESKTOP_WAIT_SECONDS=${TEST_DESKTOP_WAIT:-2}; "${@:3}"' \
        _ "$SCRIPT" "$CACHE" "$@"
}

# Starts the daemon within its own process group, ensuring that teardown
# also terminates the inotifywait it spawns. Arguments are a command prefix
# such as `env -u`.
start_daemon() {
    # shellcheck disable=SC2016
    "$@" setsid bash -c 'source "$1"; CACHE_DIR=$2; CACHE_FILE=$2/display-info; DESKTOP_WAIT_SECONDS=${TEST_DESKTOP_WAIT:-2}; main' \
        _ "$SCRIPT" "$CACHE" > "$DAEMON_LOG" 2>&1 3>&- &
    DAEMON_PID=$!
}

daemon_exited() {
    local state
    state=$(ps -o stat= -p "$DAEMON_PID" 2>/dev/null) || true
    [[ -z $state || $state == Z* ]]
}

wait_until() {
    local _
    for _ in {1..50}; do
        "$@" && return 0
        sleep 0.1
    done
    return 1
}

applied() {
    grep -qx "set org.gnome.desktop.interface text-scaling-factor $1" "$GSETTINGS_LOG" 2>/dev/null
}

reprocessed() {
    local n
    n=$(grep -c 'display-info changed' "$DAEMON_LOG" 2>/dev/null) || true
    echo "${n:-0}"
}

# The daemon only notices changes once its inotifywait has begun
# monitoring, which happens shortly after its first pass. Publish again
# until it reacts.
publish_until_reprocessed() {
    local before _
    before=$(reprocessed)
    for _ in {1..20}; do
        publish "$1"
        for _ in {1..5}; do
            (( $(reprocessed) > before )) && return 0
            sleep 0.1
        done
    done
    return 1
}

@test "applies the text-scaling factor of the display with the most pixels" {
    publish $'DP-3 105.51 1920 1080\nDP-5 140.68 5120 2160\n'

    run session apply_scale

    [[ $status -eq 0 ]]
    applied 1.465
}

# wayland-display-info writes an empty display-info when no output is enabled,
# e.g. after `niri msg output <name> off` for every output. apply_scale used to
# return 1 there, `set -e` ended the daemon, and systemd restarted it every
# three seconds as long as the outputs stayed off.
@test "an empty display-info succeeds without touching the scaling" {
    publish ''

    run session apply_scale

    [[ $status -eq 0 ]]
    [[ ! -e $GSETTINGS_LOG ]]
}

@test "the daemon keeps running across an empty display-info" {
    publish $'DP-5 140.68 5120 2160\n'
    start_daemon
    wait_until applied 1.465

    publish_until_reprocessed ''
    wait_until grep -q 'no enabled output' "$DAEMON_LOG"

    # Only a daemon that survived the empty file can apply the next one.
    publish_until_reprocessed $'DP-3 105.51 1920 1080\n'
    wait_until applied 1.099
}

@test "a DPI of inf keeps the scaling and warns" {
    publish $'HDMI-A-1 inf 3840 2160\n'

    run session apply_scale

    [[ $status -eq 0 ]]
    [[ $output == *"<4>display-info has no usable DPI value"* ]]
    [[ ! -e $GSETTINGS_LOG ]]
}

@test "a DPI of zero keeps the scaling and warns" {
    publish $'HDMI-A-1 0.00 3840 2160\n'

    run session apply_scale

    [[ $status -eq 0 ]]
    [[ $output == *"<4>display-info has no usable DPI value"* ]]
    [[ ! -e $GSETTINGS_LOG ]]
}

# The user service might start before the compositor has imported
# XDG_CURRENT_DESKTOP into the systemd user environment. Reading the variable
# with an empty default then let the daemon run and set gsettings under
# COSMIC.
@test "waits for XDG_CURRENT_DESKTOP to be imported and then honours COSMIC" {
    publish $'DP-5 140.68 5120 2160\n'
    start_daemon env -u XDG_CURRENT_DESKTOP TEST_DESKTOP_WAIT=10
    wait_until test -s "$SYSTEMCTL_LOG"

    echo XDG_CURRENT_DESKTOP=COSMIC > "$USER_ENVIRONMENT"

    wait_until daemon_exited
    [[ ! -e $GSETTINGS_LOG ]]
}

@test "applies the scaling when XDG_CURRENT_DESKTOP is not imported in time" {
    publish $'DP-5 140.68 5120 2160\n'

    start_daemon env -u XDG_CURRENT_DESKTOP TEST_DESKTOP_WAIT=1

    wait_until applied 1.465
}

# systemd exports USER to user services, but under `set -u` the script must
# not depend on it: without the default it stopped with "USER: unbound
# variable".
@test "starts when USER is not set" {
    publish $'DP-5 140.68 5120 2160\n'

    start_daemon env -u USER

    wait_until applied 1.465
}

@test "exits without touching the scaling under COSMIC" {
    publish $'DP-5 140.68 5120 2160\n'

    XDG_CURRENT_DESKTOP=COSMIC run session main

    [[ $status -eq 0 ]]
    [[ ! -e $GSETTINGS_LOG ]]
}
