#!/usr/bin/env bats
# Smoke tests for install.sh --configure-omp extension-directory resolution.

load 'test_helper'

setup() {
    setup_temp_dir
}

teardown() {
    teardown_temp_dir
}

# Run install.sh --configure-omp with an isolated HOME and a scrubbed omp/pi
# environment; extra arguments are forwarded to env(1) as VAR=value pairs.
install_omp() {
    run env \
        -u OMP_EXTENSION_PATH -u PI_EXTENSION_PATH -u OMP_PROFILE -u PI_PROFILE \
        -u PI_CODING_AGENT_DIR -u PI_CONFIG_DIR \
        HOME="$TEST_TEMP_DIR/home" \
        "$@" \
        "$PROJECT_ROOT/install.sh" \
        --prefix "$TEST_TEMP_DIR/prefix" --symlink --configure-omp
}

@test "configure-omp: default profile installs into ~/.omp/agent/extensions" {
    install_omp

    [ "$status" -eq 0 ]
    link="$TEST_TEMP_DIR/home/.omp/agent/extensions/tmux-notify-jump.ts"
    [ -L "$link" ]
    [ "$(readlink "$link")" = "$PROJECT_ROOT/omp-extension/tmux-notify-jump.ts" ]
}

@test "configure-omp: OMP_PROFILE targets the profile agent directory" {
    install_omp OMP_PROFILE=work

    [ "$status" -eq 0 ]
    link="$TEST_TEMP_DIR/home/.omp/profiles/work/agent/extensions/tmux-notify-jump.ts"
    [ -L "$link" ]
}

@test "configure-omp: PI_PROFILE is used when OMP_PROFILE is unset" {
    install_omp PI_PROFILE=team

    [ "$status" -eq 0 ]
    link="$TEST_TEMP_DIR/home/.omp/profiles/team/agent/extensions/tmux-notify-jump.ts"
    [ -L "$link" ]
}

@test "configure-omp: explicitly empty OMP_PROFILE ignores PI_PROFILE" {
    install_omp OMP_PROFILE= PI_PROFILE=team

    [ "$status" -eq 0 ]
    link="$TEST_TEMP_DIR/home/.omp/agent/extensions/tmux-notify-jump.ts"
    [ -L "$link" ]
}

@test "configure-omp: OMP_PROFILE=default selects the default profile" {
    install_omp OMP_PROFILE=default

    [ "$status" -eq 0 ]
    link="$TEST_TEMP_DIR/home/.omp/agent/extensions/tmux-notify-jump.ts"
    [ -L "$link" ]
}

@test "configure-omp: PI_CODING_AGENT_DIR overrides the default agent dir" {
    install_omp PI_CODING_AGENT_DIR="$TEST_TEMP_DIR/custom-agent"

    [ "$status" -eq 0 ]
    link="$TEST_TEMP_DIR/custom-agent/extensions/tmux-notify-jump.ts"
    [ -L "$link" ]
}

@test "configure-omp: PI_CODING_AGENT_DIR is ignored under a named profile" {
    install_omp OMP_PROFILE=work PI_CODING_AGENT_DIR="$TEST_TEMP_DIR/custom-agent"

    [ "$status" -eq 0 ]
    [ ! -e "$TEST_TEMP_DIR/custom-agent/extensions" ]
    link="$TEST_TEMP_DIR/home/.omp/profiles/work/agent/extensions/tmux-notify-jump.ts"
    [ -L "$link" ]
}

@test "configure-omp: --omp-extension-path wins over profile resolution" {
    run env \
        -u PI_EXTENSION_PATH -u PI_PROFILE -u PI_CODING_AGENT_DIR -u PI_CONFIG_DIR \
        HOME="$TEST_TEMP_DIR/home" OMP_PROFILE=work \
        "$PROJECT_ROOT/install.sh" \
        --prefix "$TEST_TEMP_DIR/prefix" --symlink --configure-omp \
        --omp-extension-path "$TEST_TEMP_DIR/explicit"

    [ "$status" -eq 0 ]
    link="$TEST_TEMP_DIR/explicit/tmux-notify-jump.ts"
    [ -L "$link" ]
    [ ! -e "$TEST_TEMP_DIR/home/.omp/profiles/work/agent/extensions" ]
}

@test "configure-omp: PI_CONFIG_DIR replaces the .omp directory name" {
    install_omp PI_CONFIG_DIR=.customomp

    [ "$status" -eq 0 ]
    link="$TEST_TEMP_DIR/home/.customomp/agent/extensions/tmux-notify-jump.ts"
    [ -L "$link" ]
}

@test "configure-omp: invalid profile name fails loudly" {
    install_omp 'OMP_PROFILE=Work!'

    [ "$status" -ne 0 ]
}

@test "configure-omp: interior whitespace makes the profile name invalid" {
    install_omp 'OMP_PROFILE=team name'

    [ "$status" -ne 0 ]
    [ ! -e "$TEST_TEMP_DIR/home/.omp/profiles" ]
}

@test "configure-omp: surrounding whitespace is trimmed from profile names" {
    install_omp 'OMP_PROFILE= work '

    [ "$status" -eq 0 ]
    link="$TEST_TEMP_DIR/home/.omp/profiles/work/agent/extensions/tmux-notify-jump.ts"
    [ -L "$link" ]
}

@test "configure-omp: whitespace-only OMP_PROFILE selects the default profile" {
    install_omp 'OMP_PROFILE=   '

    [ "$status" -eq 0 ]
    link="$TEST_TEMP_DIR/home/.omp/agent/extensions/tmux-notify-jump.ts"
    [ -L "$link" ]
}

@test "configure-omp: Windows-reserved device names are rejected" {
    install_omp 'OMP_PROFILE=con'
    [ "$status" -ne 0 ]

    install_omp 'OMP_PROFILE=nul'
    [ "$status" -ne 0 ]

    install_omp 'OMP_PROFILE=com1'
    [ "$status" -ne 0 ]

    install_omp 'OMP_PROFILE=con.dev'
    [ "$status" -ne 0 ]
}

@test "configure-omp: names merely containing reserved stems are accepted" {
    install_omp 'OMP_PROFILE=console'

    [ "$status" -eq 0 ]
    link="$TEST_TEMP_DIR/home/.omp/profiles/console/agent/extensions/tmux-notify-jump.ts"
    [ -L "$link" ]
}

@test "configure-omp: relative PI_CODING_AGENT_DIR is rejected" {
    install_omp 'PI_CODING_AGENT_DIR=relative-agent'

    [ "$status" -ne 0 ]
    [ ! -e "$TEST_TEMP_DIR/home/.omp" ]
}
