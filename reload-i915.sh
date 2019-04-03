#!/bin/bash
#
# reload_i915.sh -- Reload the i915 kernel module
#
# Copyright (C) 2019 Ahmed S. Darwish <darwish.07@gmail.com>
# SPDX-License-Identifier: Unlicense
#
# To properly do an i915 module reload, we need to kill all userspace
# daemons implicitly incrementing the module's reference count through
# open file descriptors.
#
# Typical offenders:
#
# - systemd-logind / Xwayland and gnome-shell (through logind FD passing)
# - Audio daemons (due to i915 HDMI audio connection)
# - VT consoles
#

if [[ "$UID" != "0" ]]; then
    __this_script=$(realpath $0)
    exec sudo $__this_script $USER
fi

USER=$1
LOG_FILE=/home/$USER/.i915_reload_log.txt

exec > $LOG_FILE
exec 2>&1

set -o xtrace

function unbind_vtcon()
{
    for vtcon in /sys/class/vtconsole/*; do
	echo 0 > ${vtcon}/bind
    done
}

function bind_vtcon()
{
    for vtcon in /sys/class/vtconsole/*; do
	echo 1 > ${vtcon}/bind
    done
}

function unbind_audio()
{
    #
    # Use systemd's `machinectl shell' instead of `sudo' so that
    # "systemctl --user" can access the user's session bus through
    # $XDG_RUNTIME_DIR.
    #
    # More details are in my PA mailing list message:
    #
    #   https://lists.freedesktop.org/archives/pulseaudio-discuss/2016-December/027295.html
    #
    machinectl shell $USER@ /usr/bin/systemctl --user stop pulseaudio.service
    machinectl shell $USER@ /usr/bin/systemctl --user stop pulseaudio.socket
    rmmod snd_hda_intel
}

function bind_audio()
{
    modprobe snd_hda_intel
    machinectl shell $USER@ /usr/bin/systemctl --user start pulseaudio.socket
    machinectl shell $USER@ /usr/bin/systemctl --user start pulseaudio.service
}

function unbind_gfx ()
{
    local retries=0

    systemctl stop gdm
    systemctl stop systemd-logind
    pkill gnome-shell
    pkill Xwayland
    unbind_vtcon

    # Wait for daemons to close their FDs and exit
    while lsof | grep /dev/dri; do
	sleep 0.5
	retries=$((retries + 1))
	[[ $retries -gt 3 ]] && break
    done

    if ! rmmod i915 ; then
	echo "ERROR: Failed to unload i915 module"
	echo "=> List of open FDs: $(lsof | grep /dev/dri/)"
	echo "=> i915 module refcount: $(cat /sys/module/i915/refcnt)"
    fi
}

function bind_gfx()
{
    bind_vtcon
    modprobe i915
    systemctl start systemd-logind
    systemctl start gdm
}

function reset_audio_video()
{
    unbind_audio
    unbind_gfx
    bind_gfx
    bind_audio
}

#
# If we're running under a graphical session, then unbinding
# graphics will indirectly stop __this__ very same script.
#
# So in that case, run everything in the background instead.
#
if [[ -n "$DISPLAY" ]]; then
    reset_audio_video &
else
    reset_audio_video
fi
