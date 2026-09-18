#!/usr/bin/env bash
# t2-mac-dsp — switch from this workaround to the official DSP path
#
# ###########################################################################
# # DO NOT RUN THIS YET — as of 2026-09-18 the official path is still broken. #
# #                                                                         #
# # t2linux-audio 2.2.0-1.20260917git9527bff.fc44 fixed the three original  #
# # problems but introduced a new one: its udev rule computes the card id   #
# # "t2-15,4", and the kernel rejects any card id containing a comma        #
# # (EINVAL). The rename silently fails and the DSP never attaches:         #
# #                                                                         #
# #   ATTR{id}="t2-%c": Failed to write "t2-15,4" to sysfs attribute "id"   #
# #                                                                         #
# # The kernel only accepts [A-Za-z0-9_-] (verified by writing directly to  #
# # /sys/class/sound/card0/id). A working upstream fix would use e.g.       #
# # "t2-15_4" — the scheme upstream lemmyg uses (t2-<MODEL_DIR>) and the    #
# # same names this package already uses for /usr/share/t2linux-audio/<dir>.#
# #                                                                         #
# # Running this script now removes the workaround and leaves you with NO   #
# # DSP at all. Only run it once a fixed package is out, and check first:   #
# #                                                                         #
# #   rpm -q t2linux-audio                                                  #
# #   cat /sys/class/sound/card0/id      # must show t2-15_4, not "Audio"   #
# ###########################################################################
#
# Usage:
#   ./switch-to-official.sh          remove the workaround, update the package
#   ./switch-to-official.sh --check  verify the official path (run after reboot)
#
# Runs as your normal user; it calls sudo itself for the package update.
#
# Rollback: run ./install.sh to put the workaround back.

set -uo pipefail

CONF="$HOME/.config/pipewire/pipewire.conf.d/50-t2-dsp.conf"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The official udev rule derives the card id with:
#   sed 's/[^0-9]*//' /sys/class/dmi/id/product_name
# Mirror that here so we know what to expect. e.g. MacBookPro15,4 -> t2-15,4
EXPECT_ID="t2-$(/usr/bin/sed 's/[^0-9]*//' /sys/class/dmi/id/product_name 2>/dev/null)"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m ok \033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
info() { printf '       %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Post-reboot verification
# ---------------------------------------------------------------------------
check() {
    say "Verifying the official DSP path"
    local fails=0

    printf '  %-24s' "package"
    if rpm -q t2linux-audio >/dev/null 2>&1; then
        ok "$(rpm -q --qf '%{VERSION}-%{RELEASE}' t2linux-audio)"
    else
        bad "not installed"; fails=$((fails+1))
    fi

    printf '  %-24s' "udev rule location"
    if [ -f /usr/lib/udev/rules.d/99-t2-audio-rename.rules ]; then
        ok "/usr/lib/udev/rules.d/"
    else
        bad "missing - package is older than 2.2.0?"; fails=$((fails+1))
    fi

    printf '  %-24s' "ALSA card id"
    local cid; cid=$(cat /sys/class/sound/card0/id 2>/dev/null)
    if [ "$cid" = "$EXPECT_ID" ]; then
        ok "$cid"
    else
        bad "$cid (expected $EXPECT_ID)"
        info "did you reboot after the update?"
        fails=$((fails+1))
    fi

    printf '  %-24s' "workaround removed"
    if [ -f "$CONF" ]; then
        bad "$CONF is still active"
        fails=$((fails+1))
    else
        ok "yes"
    fi

    # NOTE: both the workaround and the official path build their node from the
    # same graph.json, so the node name is identical either way. This check only
    # answers "is there a DSP node live right now" - the card id and the
    # RawSpeakers rename above are what actually distinguish the two paths.
    #
    # Query pw-cli, not wpctl status: the latter also prints WirePlumber's
    # persisted "Default Configured Devices" list, which can name a DSP node
    # that no longer exists and produce a false pass.
    printf '  %-24s' "DSP node live"
    if pw-cli list-objects Node 2>/dev/null | grep -q 'audio_effect\.t2-'; then
        ok "yes"
    else
        bad "not found"; fails=$((fails+1))
    fi

    printf '  %-24s' "raw sink renamed"
    if pw-cli list-objects Node 2>/dev/null | grep -q 'platform-sound.RawSpeakers'; then
        ok "yes"
    else
        bad "RawSpeakers node not seen"; fails=$((fails+1))
    fi

    printf '  %-24s' "filter-chain errors"
    local graph_errs target_errs
    graph_errs=$(journalctl --user -b 2>/dev/null \
        | grep -cE "can't start graph|failed file")
    target_errs=$(journalctl --user -b 2>/dev/null \
        | grep -cE "defined target not found|target not found")
    if [ "$graph_errs" = "0" ] && [ "$target_errs" = "0" ]; then
        ok "none this boot"
    else
        [ "$graph_errs" != "0" ] && { bad "$graph_errs graph error(s)"; fails=$((fails+1)); }
        [ "$target_errs" != "0" ] && { bad "$target_errs target error(s)"; fails=$((fails+1)); }
        info "journalctl --user -b | grep -E \"can't start graph|target not found\""
    fi

    echo
    if [ "$fails" -eq 0 ]; then
        printf '\033[32mAll checks passed - the official path is running the DSP.\033[0m\n'
        echo "Please report back on the upstream issue."
    else
        printf '\033[33m%d check(s) failed.\033[0m\n' "$fails"
        echo "Rollback:  $REPO/install.sh"
    fi
    return "$fails"
}

if [ "${1:-}" = "--check" ]; then
    check
    exit $?
fi

# ---------------------------------------------------------------------------
# Switch
# ---------------------------------------------------------------------------
say "Switching to the official t2linux-audio DSP path"

say "1/3  Removing the user-level workaround"
if [ -f "$CONF" ]; then
    if [ -x "$REPO/uninstall.sh" ]; then
        "$REPO/uninstall.sh"
    else
        mv -v "$CONF" "${CONF}.backup"
        systemctl --user restart pipewire pipewire-pulse wireplumber
    fi
else
    info "not active, nothing to do"
fi

say "2/3  Updating t2linux-audio"
if ! sudo dnf --refresh upgrade -y t2linux-audio; then
    bad "dnf failed"
    info "Nothing was lost. Rollback with: $REPO/install.sh"
    exit 1
fi

say "3/3  Checking the updated package"
printf '  %-24s' "version"
ok "$(rpm -q --qf '%{VERSION}-%{RELEASE}' t2linux-audio)"

printf '  %-24s' "udev rule location"
if [ -f /usr/lib/udev/rules.d/99-t2-audio-rename.rules ]; then
    ok "/usr/lib/udev/rules.d/"
else
    bad "still not there - is this really 2.2.0 or newer?"
fi

printf '  %-24s' "FIR paths in graph.json"
if grep -q 't2-linux-audio' /usr/share/t2linux-audio/*/graph.json 2>/dev/null; then
    bad "the extra-hyphen path is still present"
else
    ok "correct"
fi

cat <<EOF

Next step: reboot.

Then verify:

    $REPO/switch-to-official.sh --check

If anything goes wrong, go back to the workaround with:

    $REPO/install.sh

EOF
