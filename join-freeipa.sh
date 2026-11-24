#!/usr/bin/env bash
# ==============================================================================
#  join-freeipa.sh — Join an Ubuntu workstation to FreeIPA (ipa.dic.evollabs.ae)
#
#  Usage :  sudo bash join-freeipa.sh
#  Log   :  /var/log/freeipa-join.log
#
#  What it does (6 steps):
#    1. Pre-flight checks   – root, Ubuntu, DNS + ports to the IPA server
#    2. Install packages    – freeipa-client (with Kerberos settings pre-filled)
#    3. Set hostname        – asks you for a name, sets <name>.dic.next-ai.me
#    4. Update /etc/hosts   – adds "127.0.1.1 <fqdn> <name>"
#    5. Join FreeIPA        – runs ipa-client-install
#    6. Verify              – config, SSSD, Kerberos login, host & user lookup
#
#  ⚠  This file contains an IPA password. Keep it private:
#       chmod 700 join-freeipa.sh   — do not commit, email or leave it on laptops.
# ==============================================================================

# If any command in a pipeline (a | b | c) fails, the whole pipeline counts as failed
set -o pipefail
# Enable extended pattern matching, e.g. *([0-9;]) — used to strip color codes in the summary box
shopt -s extglob
# Force a UTF-8 locale so ✔/✖ and box characters count as 1 character each (keeps the summary box aligned)
export LC_ALL=C.UTF-8

# ─── Configuration ────────────────────────────────────────────────────────────
# Change these values here if the domain / server / user ever changes.
IPA_DOMAIN="next-ai.me"                 # DNS domain passed to --domain
IPA_SERVER="ipa.dic.evollabs.ae"        # FreeIPA server to enroll against
IPA_REALM="DIC.EVOLLABS.AE"             # Kerberos realm (always UPPERCASE)
IPA_PRINCIPAL="asid"                    # Admin/enrollment account used ONLY to join the workstation
                                        # to the domain (not the person who will use the laptop)
IPA_PASSWORD='Megatron@12234'           # Password of that user (single quotes = taken literally)
HOST_SUFFIX="dic.next-ai.me"            # Appended to the hostname you type -> <name>.dic.next-ai.me
LOG_FILE="/var/log/freeipa-join.log"    # Every command's full output is written here
TOTAL_STEPS=6                           # Shown in the "STEP x/6" headers

# ─── Colors ───────────────────────────────────────────────────────────────────
# Only use colors when output goes to a real terminal (-t 1) that supports 8+ colors.
# Otherwise (e.g. output piped to a file) set every color to empty so no junk codes appear.
if [[ -t 1 ]] && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    R=$'\e[0m'; B=$'\e[1m'; DIM=$'\e[2m'                                   # reset, bold, dim
    RED=$'\e[38;5;196m'; GRN=$'\e[38;5;46m'; YEL=$'\e[38;5;220m'           # 256-color palette
    BLU=$'\e[38;5;39m';  CYN=$'\e[38;5;51m'; MAG=$'\e[38;5;171m'; GRY=$'\e[38;5;245m'
    # One color per banner line: cyan -> blue -> purple gradient
    GRAD=($'\e[38;5;51m' $'\e[38;5;45m' $'\e[38;5;39m' $'\e[38;5;33m' $'\e[38;5;99m' $'\e[38;5;135m')
else
    R=""; B=""; DIM=""; RED=""; GRN=""; YEL=""; BLU=""; CYN=""; MAG=""; GRY=""
    GRAD=("" "" "" "" "" "")
fi

# Counters for the verification results shown in the final summary box
PASS=0; FAIL=0; WARN=0
# Process ID of the command currently running under the spinner (so Ctrl+C can stop it)
SPIN_PID=""
# Remember what we changed, so a failed join can put the laptop back the way it was
OLD_HOSTNAME=""        # hostname before step 3 (set only once we actually change it)
BACKUP=""              # /etc/hosts backup path (set only once we actually change /etc/hosts)
JOINED=0               # becomes 1 after ipa-client-install succeeds — then we no longer roll back

# ─── UI helpers ───────────────────────────────────────────────────────────────

# banner: clears the screen and prints the big "FREEIPA" logo with a color gradient
banner() {
    clear
    local art=(
"  ███████╗██████╗ ███████╗███████╗██╗██████╗  █████╗ "
"  ██╔════╝██╔══██╗██╔════╝██╔════╝██║██╔══██╗██╔══██╗"
"  █████╗  ██████╔╝█████╗  █████╗  ██║██████╔╝███████║"
"  ██╔══╝  ██╔══██╗██╔══╝  ██╔══╝  ██║██╔═══╝ ██╔══██║"
"  ██║     ██║  ██║███████╗███████╗██║██║     ██║  ██║"
"  ╚═╝     ╚═╝  ╚═╝╚══════╝╚══════╝╚═╝╚═╝     ╚═╝  ╚═╝"
    )
    echo
    # Print each line of the logo in its own gradient color
    for i in "${!art[@]}"; do
        printf '%s%s%s\n' "${GRAD[$i]}${B}" "${art[$i]}" "$R"
    done
    echo
    printf '  %s%s Ubuntu Workstation  ➜  Identity Domain Join %s\n' "$MAG" "$B" "$R"
    printf '  %sServer:%s %s   %sRealm:%s %s\n' "$GRY" "$R" "$IPA_SERVER" "$GRY" "$R" "$IPA_REALM"
    printf '  %s%s%s\n\n' "$GRY" "──────────────────────────────────────────────────────" "$R"
}

# step N "title": prints a boxed step header on screen and a matching marker in the log file
step() {
    local n="$1"; shift
    echo
    printf '%s%s ┌─[ STEP %s/%s ]%s %s%s%s\n' "$BLU" "$B" "$n" "$TOTAL_STEPS" "$R" "$B$CYN" "$*" "$R"
    printf '%s └──────────────────────────────────────────────%s\n' "$BLU" "$R"
    echo "===== STEP $n/$TOTAL_STEPS: $* ($(date '+%F %T')) =====" >>"$LOG_FILE"
}

# Status line printers: green tick, yellow warning, red cross, cyan arrow
ok()   { printf '   %s✔%s  %s\n' "$GRN$B" "$R" "$*"; }
warn() { printf '   %s⚠%s  %s\n' "$YEL$B" "$R" "$*"; }
err()  { printf '   %s✖%s  %s\n' "$RED$B" "$R" "$*"; }
info() { printf '   %s➜%s  %s\n' "$CYN" "$R" "$*"; }

# check "label" command...
#   Runs the command silently (output goes to the log), then prints ✔ or ✖
#   next to the label and adds 1 to the PASS or FAIL counter.
check() {
    local label="$1"; shift
    if "$@" >>"$LOG_FILE" 2>&1; then ok "$label"; ((PASS++)); return 0
    else err "$label"; ((FAIL++)); return 1; fi
}

# rollback: undo the hostname and /etc/hosts changes if the join did not complete.
# Does nothing if nothing was changed yet, or if the laptop is already joined.
rollback() {
    [[ $JOINED -eq 1 ]] && return
    if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
        # Put the original /etc/hosts back from the backup made in step 4
        if cp -p "$BACKUP" /etc/hosts; then ok "Rolled back /etc/hosts from $BACKUP"
        else err "Could not restore /etc/hosts — copy it back manually from $BACKUP"; fi
    fi
    if [[ -n "$OLD_HOSTNAME" ]]; then
        # Put the original hostname back
        if hostnamectl set-hostname "$OLD_HOSTNAME" >>"$LOG_FILE" 2>&1; then
            ok "Rolled back hostname to $OLD_HOSTNAME"
        else
            err "Could not restore hostname — run: sudo hostnamectl set-hostname $OLD_HOSTNAME"
        fi
    fi
}

# die "message": prints the error, shows the last 20 lines of the log in red,
# undoes the hostname / hosts changes (if any) and exits
die() {
    echo
    err "${B}$*${R}"
    printf '\n   %sLast lines of %s:%s\n' "$GRY" "$LOG_FILE" "$R"
    tail -n 20 "$LOG_FILE" 2>/dev/null | sed "s/^/      ${RED}│${R} /"
    echo
    rollback
    echo
    exit 1
}

# spin "message" command...
#   Runs a long command in the background (output goes to the log) and shows an
#   animated spinner with elapsed seconds until it finishes. Returns the command's exit code.
spin() {
    local msg="$1"; shift
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')     # spinner animation frames
    # Start the command in the background in its own process group (setsid),
    # so Ctrl+C can stop it together with any child processes it starts (e.g. apt -> dpkg)
    setsid "$@" >>"$LOG_FILE" 2>&1 &
    local pid=$! i=0 start=$SECONDS                             # remember its process ID and start time
    SPIN_PID=$pid                                               # let the Ctrl+C handler know what to stop
    tput civis 2>/dev/null                                      # hide the cursor while spinning
    while kill -0 "$pid" 2>/dev/null; do                        # loop while the process is still alive
        printf '\r   %s%s%s  %s %s(%ss)%s ' "$MAG" "${frames[i++ % ${#frames[@]}]}" "$R" "$msg" "$GRY" "$((SECONDS - start))" "$R"
        sleep 0.1
    done
    wait "$pid"; local rc=$?                                    # collect the command's exit code
    SPIN_PID=""                                                 # nothing running in the background anymore
    tput cnorm 2>/dev/null                                      # show the cursor again
    printf '\r\e[K'                                             # clear the spinner line
    if [[ $rc -eq 0 ]]; then ok "$msg ${GRY}($((SECONDS - start))s)${R}"
    else err "$msg ${GRY}(exit $rc)${R}"; fi
    return $rc
}

# ask "prompt" varname: shows a yellow "?" prompt and stores what you type in <varname>
ask() {
    local __v
    printf '   %s?%s  %s' "$YEL$B" "$R" "$1"
    # If there is no input at all (Ctrl+D, or stdin is /dev/null) stop instead of looping forever
    read -r __v || { echo; err "No input received — aborting"; exit 1; }
    printf -v "$2" '%s' "$__v"
}

# on_interrupt: runs on Ctrl+C. Stops the background command (and its children) that
# the spinner is waiting on, so apt/dpkg or ipa-client-install are not left running.
on_interrupt() {
    echo
    if [[ -n "$SPIN_PID" ]] && kill -0 "$SPIN_PID" 2>/dev/null; then
        err "Interrupted — stopping running command (PID $SPIN_PID)…"
        kill -TERM -- "-$SPIN_PID" 2>/dev/null     # "-PID" = signal the whole process group
        wait "$SPIN_PID" 2>/dev/null
    else
        err "Interrupted."
    fi
    rollback          # undo hostname / hosts changes if the join didn't finish
    exit 130
}

# Always restore the cursor when the script ends; on Ctrl+C run on_interrupt
trap 'tput cnorm 2>/dev/null; echo' EXIT
trap on_interrupt INT

# ==============================================================================
#  MAIN
# ==============================================================================
banner

# ─── STEP 1: Pre-flight ───────────────────────────────────────────────────────
# Must be root (EUID 0) — installing packages, changing hostname and joining IPA all need it
[[ $EUID -eq 0 ]] || { err "Run as root:  ${B}sudo bash $0${R}"; exit 1; }
# Start a fresh, empty log file readable only by root (it may contain sensitive output)
: >"$LOG_FILE"; chmod 600 "$LOG_FILE"

step 1 "Pre-flight checks"

# Read /etc/os-release to confirm this is Ubuntu and show the version
if grep -qi '^ID=ubuntu' /etc/os-release 2>/dev/null; then
    ok "OS: $(. /etc/os-release; echo "$PRETTY_NAME")"
else
    warn "This does not look like Ubuntu — continuing anyway"
fi

# Make sure the IPA server name resolves to an IP address — no DNS, no join, so stop here
if getent hosts "$IPA_SERVER" >/dev/null; then
    ok "DNS: $IPA_SERVER → $(getent hosts "$IPA_SERVER" | awk '{print $1; exit}')"
else
    die "Cannot resolve $IPA_SERVER — check network / DNS settings"
fi

# Test TCP ports the client needs: 443 (HTTPS/IPA API), 88 (Kerberos), 389 (LDAP)
# Uses bash's built-in /dev/tcp with a 4-second timeout. Only warns, does not stop.
for port in 443 88 389; do
    if timeout 4 bash -c "</dev/tcp/$IPA_SERVER/$port" 2>/dev/null; then
        ok "Port $port reachable on $IPA_SERVER"
    else
        warn "Port $port not reachable on $IPA_SERVER"; ((WARN++))
    fi
done

# /etc/ipa/default.conf exists only on machines already joined to IPA.
# If found, ask whether to leave the domain first (uninstall) and rejoin, or quit.
# If unenrolling fails we stop here, BEFORE touching the hostname or /etc/hosts.
if [[ -f /etc/ipa/default.conf ]]; then
    warn "This machine is already enrolled in FreeIPA"
    ask "[r]einstall (unenroll + rejoin) or [q]uit? " choice
    case "${choice,,}" in                          # ${choice,,} = lowercase the answer
        r*) spin "Unenrolling existing FreeIPA client" ipa-client-install --uninstall --unattended \
                || die "Unenroll failed — nothing else was changed. Fix it and run the script again."
            # Double-check the old IPA config is really gone before continuing
            [[ -f /etc/ipa/default.conf ]] \
                && die "/etc/ipa/default.conf still exists after unenroll — nothing else was changed." ;;
        *)  info "Nothing changed. Bye!"; exit 0 ;;
    esac
fi

# ─── STEP 2: Install packages ─────────────────────────────────────────────────
step 2 "Installing FreeIPA client"

# Pre-answer the questions the krb5-config package normally asks in a blue dialog
# (default realm, Kerberos servers, admin server), so the install runs without pop-ups.
debconf-set-selections <<EOF
krb5-config krb5-config/default_realm string $IPA_REALM
krb5-config krb5-config/kerberos_servers string $IPA_SERVER
krb5-config krb5-config/admin_server string $IPA_SERVER
krb5-config krb5-config/add_servers boolean false
EOF
ok "Kerberos defaults pre-seeded (no pop-up dialogs)"

# Tell apt / dpkg never to stop and ask questions
export DEBIAN_FRONTEND=noninteractive
# Refresh the package lists from the Ubuntu mirrors
spin "Updating package lists" apt-get update -y || die "apt-get update failed"
# Install the FreeIPA client (pulls in sssd, krb5-user, certmonger, ipa CLI, etc.)
spin "Installing freeipa-client" apt-get install -y freeipa-client || die "freeipa-client install failed"

# ─── STEP 3: Hostname ─────────────────────────────────────────────────────────
step 3 "Set hostname"
info "Current hostname: ${B}$(hostname)${R}"

# Keep asking until a valid hostname is entered and confirmed
while true; do
    ask "Enter new short hostname (e.g. ${B}lap-ali-01${R}): " SHORT
    # Clean up the input: lowercase it, drop anything after a dot, remove spaces
    SHORT="${SHORT,,}"; SHORT="${SHORT%%.*}"; SHORT="${SHORT//[[:space:]]/}"
    # Valid hostname: 1–63 chars, letters/digits/hyphens, cannot start or end with "-"
    if [[ ! "$SHORT" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
        err "Invalid hostname — use letters, digits and '-' only"; continue
    fi
    # Build the full name, e.g. lap-ali-01.dic.next-ai.me, and ask for confirmation
    FQDN="${SHORT}.${HOST_SUFFIX}"
    ask "Full hostname will be ${GRN}${B}${FQDN}${R} — correct? [Y/n] " yn
    [[ -z "$yn" || "${yn,,}" == y* ]] && break     # Enter or "y" = yes
done

# Remember the current hostname so it can be restored if the join fails later
OLD_HOSTNAME="$(hostnamectl --static 2>/dev/null || hostname)"
# Set the permanent system hostname (writes /etc/hostname and applies it immediately)
hostnamectl set-hostname "$FQDN" >>"$LOG_FILE" 2>&1 || die "hostnamectl failed"
ok "Hostname set to ${B}$(hostname)${R}"

# ─── STEP 4: /etc/hosts ───────────────────────────────────────────────────────
step 4 "Update /etc/hosts"

# Save a timestamped copy of /etc/hosts first, e.g. /etc/hosts.bak.20261124-101500
# If the backup fails, stop — never edit /etc/hosts without a good copy
HOSTS_BAK="/etc/hosts.bak.$(date +%Y%m%d-%H%M%S)"
cp -p /etc/hosts "$HOSTS_BAK" || die "Could not back up /etc/hosts — /etc/hosts was not changed"
BACKUP="$HOSTS_BAK"      # from now on, rollback will restore /etc/hosts from this copy
ok "Backup saved: $BACKUP"

# The line we want:  127.0.1.1 <tab> lap-ali-01.dic.next-ai.me lap-ali-01
NEW_LINE="127.0.1.1	${FQDN} ${SHORT}"
# Rebuild /etc/hosts from the backup with awk:
#   - drop any existing 127.0.1.1 line (old hostname)
#   - copy every other line unchanged
#   - insert the new 127.0.1.1 line right after the 127.0.0.1 localhost line
#   - if there was no 127.0.0.1 line at all, add the new line at the end
# The result goes to a temp file first; /etc/hosts is only replaced if awk succeeded,
# so a failure can never leave you with an empty /etc/hosts.
HOSTS_TMP="$(mktemp /etc/hosts.tmp.XXXXXX)" || die "Could not create temp file in /etc"
if awk -v line="$NEW_LINE" '
    /^[[:space:]]*127\.0\.1\.1[[:space:]]/ { next }
    { print }
    /^[[:space:]]*127\.0\.0\.1[[:space:]]/ && !done { print line; done=1 }
    END { if (!done) print line }
' "$BACKUP" >"$HOSTS_TMP" && [[ -s "$HOSTS_TMP" ]]; then
    chmod 644 "$HOSTS_TMP"                         # same permissions as a normal /etc/hosts
    mv -f "$HOSTS_TMP" /etc/hosts || { rm -f "$HOSTS_TMP"; die "Failed to replace /etc/hosts"; }
else
    rm -f "$HOSTS_TMP"
    die "Failed to build new /etc/hosts — original left untouched"
fi

# Show the result: the inserted line plus the first 5 lines of the new /etc/hosts
ok "Inserted: ${GRN}${NEW_LINE}${R}"
printf '   %s┌─ /etc/hosts ─────────────────────────────────%s\n' "$GRY" "$R"
head -n 5 /etc/hosts | sed "s/^/   ${GRY}│${R} /"
printf '   %s└──────────────────────────────────────────────%s\n' "$GRY" "$R"

# ─── STEP 5: Join FreeIPA ─────────────────────────────────────────────────────
step 5 "Joining FreeIPA domain"
info "Enrolling with join account ${B}${IPA_PRINCIPAL}${R} → ${B}${IPA_SERVER}${R} (${IPA_REALM})"

# Enroll this machine in FreeIPA. Options used:
#   --domain              DNS domain of the IPA deployment
#   --server              which IPA server to talk to
#   --realm               Kerberos realm
#   --hostname            this machine's full name (the one set in step 3)
#   --principal           IPA user that is allowed to add hosts (asid)
#   --password            that user's password, so you are not prompted for it
#   --mkhomedir           create the user's home folder automatically on first login
#   --enable-dns-updates  let this machine register/update its own DNS record in IPA
#   --force-join          rejoin even if a host with this name already exists in IPA
#   --unattended          never stop to ask questions (accept defaults)
# Configures SSSD, Kerberos (/etc/krb5.conf), the host keytab, PAM/NSS and certificates.
spin "Running ipa-client-install (this can take a few minutes)" \
    ipa-client-install \
        --domain="$IPA_DOMAIN" \
        --server="$IPA_SERVER" \
        --realm="$IPA_REALM" \
        --hostname="$FQDN" \
        --principal="$IPA_PRINCIPAL" \
        --password="$IPA_PASSWORD" \
        --mkhomedir \
        --enable-dns-updates \
        --force-join \
        --unattended \
    || die "ipa-client-install failed — see $LOG_FILE and /var/log/ipaclient-install.log"
# Join succeeded — from here on, never roll back the hostname or /etc/hosts
JOINED=1

# ─── STEP 6: Verify ───────────────────────────────────────────────────────────
step 6 "Verifying enrollment"

# The IPA client config file was created by ipa-client-install
check "IPA config present (/etc/ipa/default.conf)"  test -f /etc/ipa/default.conf
# ...and its "server = ..." line is exactly our server (exact text match, not a regex)
config_server_ok() {
    awk -F'=' -v s="$IPA_SERVER" '
        $1 ~ /^[[:space:]]*server[[:space:]]*$/ { gsub(/[[:space:]]/, "", $2); if ($2 == s) found=1 }
        END { exit !found }' /etc/ipa/default.conf
}
check "Config points at $IPA_SERVER"               config_server_ok
# SSSD is the service that handles IPA logins and user lookups — it must be running
check "SSSD service is running"                     systemctl is-active --quiet sssd
# The host keytab holds this machine's Kerberos key — proof it is enrolled (-s = file not empty)
check "Host keytab exists (/etc/krb5.keytab)"       test -s /etc/krb5.keytab
# Use a private, temporary Kerberos ticket cache for these tests, so any ticket
# root already has is left alone. kinit / klist / ipa all use KRB5CCNAME.
TEST_CCACHE="$(mktemp /tmp/krb5cc_ipajoin.XXXXXX)"
export KRB5CCNAME="FILE:$TEST_CCACHE"

# Log in to Kerberos as asid by piping the password into kinit (gets a Kerberos ticket).
# printf is a bash built-in, so the password never shows up in the process list (ps).
kinit_test() { printf '%s\n' "$IPA_PASSWORD" | kinit "${IPA_PRINCIPAL}@${IPA_REALM}"; }
if check "Kerberos login as ${IPA_PRINCIPAL}@${IPA_REALM}" kinit_test; then
    # klist -s returns success only if a valid Kerberos ticket is now held
    check "Kerberos ticket issued (klist)"          klist -s
    # Ask the IPA server itself whether it knows this host (uses the ticket from kinit)
    if command -v ipa >/dev/null; then
        check "Host ${FQDN} registered on IPA server" ipa host-show "$FQDN"
    else
        warn "'ipa' CLI not found — skipped server-side host lookup"; ((WARN++))
    fi
else
    # Without a ticket these two checks can't run — skip them instead of counting 2 extra failures
    warn "Skipped ticket + server host checks (Kerberos login failed)"; ((WARN++))
fi
# Clear SSSD's cache so the next lookup goes to the IPA server fresh
sss_cache -E >/dev/null 2>&1
# Test that SSSD can look up IPA accounts, using the join account (asid) as a sample.
# Only SSSD is asked (-s sss), so a local account with the same name can't make this pass.
# If this works, any IPA user can be looked up — and therefore log in — on this laptop.
check "IPA account lookup via SSSD (test: ${IPA_PRINCIPAL})" getent -s sss passwd "$IPA_PRINCIPAL"
# Confirm PAM is set to create home folders on first login (from --mkhomedir)
check "mkhomedir enabled in PAM"                    grep -q pam_mkhomedir /etc/pam.d/common-session
# Throw away the test ticket and its temporary cache file, and go back to the default cache
kdestroy >/dev/null 2>&1
rm -f "$TEST_CCACHE"
unset KRB5CCNAME

# ─── Summary ──────────────────────────────────────────────────────────────────
# Green box if every check passed, red box if any failed
if [[ $FAIL -eq 0 ]]; then
    STATUS="${GRN}${B}✔ JOINED SUCCESSFULLY${R}"; BC="$GRN"
else
    STATUS="${RED}${B}✖ JOINED WITH ${FAIL} FAILED CHECK(S)${R}"; BC="$RED"
fi

# The values shown in the box
CHECKS_TXT="${PASS} passed, ${FAIL} failed, ${WARN} warnings"
# Strip color codes from STATUS to measure its visible length
PLAIN="${STATUS//$'\e'\[*([0-9;])m/}"

# Make the value column (W) wide enough for the longest value (minimum 40),
# so long hostnames never push past the right border
W=40
for v in "$FQDN" "$IPA_DOMAIN" "$IPA_REALM" "$IPA_SERVER" "$CHECKS_TXT" "$LOG_FILE"; do
    (( ${#v} > W )) && W=${#v}
done
(( ${#PLAIN} - 11 > W )) && W=$(( ${#PLAIN} - 11 ))
INNER=$(( W + 14 ))                                # inner box width: "  " + label(10) + " " + value(W) + " "
printf -v HL '%*s' "$INNER" ''; HL="${HL// /═}"    # horizontal border line of the right length

# row "Label" "Value": prints one aligned line inside the summary box
row() { printf "  ${BC}║${R}  %s%-10s%s %-*s ${BC}║${R}\n" "$GRY" "$1" "$R" "$W" "$2"; }
echo
printf "  ${BC}╔%s╗${R}\n" "$HL"
# Pad the status text so the right border lines up
printf "  ${BC}║${R}  %s%*s ${BC}║${R}\n" "$STATUS" $(( INNER - 3 - ${#PLAIN} )) ""
printf "  ${BC}╠%s╣${R}\n" "$HL"
row "Hostname" "$FQDN"
row "Domain"   "$IPA_DOMAIN"
row "Realm"    "$IPA_REALM"
row "Server"   "$IPA_SERVER"
row "Checks"   "$CHECKS_TXT"
row "Log"      "$LOG_FILE"
printf "  ${BC}╚%s╝${R}\n" "$HL"
echo

# On success offer a reboot (needed so the login screen picks up IPA users);
# on failure point to the log and exit with an error code
if [[ $FAIL -eq 0 ]]; then
    info "Reboot, then the laptop user logs in with ${B}their own IPA account${R}"
    info "(${IPA_PRINCIPAL} was only used to join the domain) — home dir is created on first login."
    # Ask directly (not via ask) so that no input simply means "no" instead of an error exit
    printf '   %s?%s  Reboot now? [y/N] ' "$YEL$B" "$R"
    read -r rb || { rb=n; echo; }
    [[ "${rb,,}" == y* ]] && { info "Rebooting…"; sleep 2; reboot; }
    exit 0
else
    warn "Review the failed checks above and $LOG_FILE"
    exit 1
fi
