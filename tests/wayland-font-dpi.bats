#!/usr/bin/env bats
# Tests for wayland-font-dpi, the root service that writes /etc/environment.
# Run from the root of the repository: bats tests

SCRIPT="$BATS_TEST_DIRNAME/../wayland-font-dpi"

setup() {
    CACHE="$BATS_TEST_TMPDIR/cache"
    STUBS="$BATS_TEST_TMPDIR/stubs"
    CONFIG="$BATS_TEST_TMPDIR/environment"
    SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
    mkdir -p "$CACHE" "$STUBS"
    printf 'EDITOR=vim\n' > "$CONFIG"

    # Propagation into a running session proceeds via loginctl and sudo. The
    # stubs report a single session belonging to the invoking user and
    # record the sudo call without running it, so the tests never interact
    # with a real systemd user manager.
    printf '#!/bin/sh\necho "  1 %s %s seat0 tty2"\n' "$(id -u)" "$(id -un)" > "$STUBS/loginctl"
    printf '#!/bin/sh\necho "$*" >> "%s"\n' "$SUDO_LOG" > "$STUBS/sudo"
    chmod +x "$STUBS/loginctl" "$STUBS/sudo"
    PATH="$STUBS:$PATH"
}

# Replaces display-info just as wayland-display-info does: write a
# temporary file, then rename it over the cache file.
publish() {
    printf '%s' "$1" > "$CACHE/display-info.tmp"
    mv "$CACHE/display-info.tmp" "$CACHE/display-info"
}

# Runs a command with the service script sourced, redirecting its cache and
# environment file to the test directory.
root_service() {
    # shellcheck disable=SC2016
    timeout 10 bash -c 'source "$1"; CACHE_DIR=$2; CACHE_FILE=$2/display-info; CONFIG_FILE=$3; "${@:4}"' \
        _ "$SCRIPT" "$CACHE" "$CONFIG" "$@"
}

@test "writes the scaling of the display with the most pixels and propagates it" {
    printf 'EDITOR=vim\nQT_FONT_DPI=120\n' > "$CONFIG"
    publish $'DP-3 105.51 1920 1080\nDP-5 140.68 5120 2160\n'

    run root_service process_display_info

    [[ $status -eq 0 ]]
    grep -qx 'QT_SCALE_FACTOR=1.465' "$CONFIG"
    grep -qx 'EDITOR=vim' "$CONFIG"
    run ! grep -q '^QT_FONT_DPI=' "$CONFIG"
    [[ -s $SUDO_LOG ]]
}

# Every hotplug event rewrites display-info, including monitor standby cycles
# that repeat every few seconds, and the service rewrote /etc/environment and
# called sudo each time although nothing had changed.
@test "leaves an unchanged environment file alone and does not propagate again" {
    publish $'DP-5 140.68 5120 2160\n'
    root_service process_display_info
    local before
    before=$(stat -c '%i %y' "$CONFIG")
    rm -f "$SUDO_LOG"
    publish $'DP-5 140.68 5120 2160\n'

    run root_service process_display_info

    [[ $status -eq 0 ]]
    [[ $output == *"already up to date"* ]]
    [[ $(stat -c '%i %y' "$CONFIG") == "$before" ]]
    [[ ! -e $SUDO_LOG ]]
}

@test "rewrites the environment file when the selected display changes" {
    publish $'DP-5 140.68 5120 2160\n'
    root_service process_display_info

    publish $'DP-3 105.51 1920 1080\n'
    run root_service process_display_info

    [[ $status -eq 0 ]]
    grep -qx 'QT_SCALE_FACTOR=1.099' "$CONFIG"
    [[ $(grep -c '^QT_SCALE_FACTOR=' "$CONFIG") -eq 1 ]]
}

@test "an empty display-info leaves the environment file alone" {
    publish ''

    run root_service process_display_info

    [[ $status -eq 0 ]]
    [[ $(cat "$CONFIG") == 'EDITOR=vim' ]]
    [[ ! -e $SUDO_LOG ]]
}

# An output with a physical height of 0 mm made wayland-display-info up to
# 1.0.8 write a DPI of "inf". process_display_info returned 1 on it, so the
# service ended and systemd restarted it.
@test "a DPI of inf keeps the environment file and warns" {
    publish $'DP-5 140.68 5120 2160\n'
    root_service process_display_info
    local before
    before=$(cat "$CONFIG")
    rm -f "$SUDO_LOG"
    publish $'HDMI-A-1 inf 3840 2160\n'

    run root_service process_display_info

    [[ $status -eq 0 ]]
    [[ $output == *"<4>display-info has no usable DPI value"* ]]
    [[ $(cat "$CONFIG") == "$before" ]]
    [[ ! -e $SUDO_LOG ]]
}
