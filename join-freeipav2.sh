#!/usr/bin/env bash
# ==============================================================================
#  join-freeipa.sh — Join an Ubuntu workstation to FreeIPA (ipa.dic.evollabs.ae)
#  v2.0 · crafted by Ali
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
# Force a UTF-8 locale so ✔/✖ and box characters count as 1 character each (keeps boxes aligned)
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
AUTHOR="Ali"                            # Shown in the credits
VERSION="2.0"

# ─── Colors ───────────────────────────────────────────────────────────────────
# Colors and animations are only used on a real terminal (-t 1) with 256+ colors.
# Otherwise (output piped to a file, basic Linux console) everything is plain text.
COLOR=0
NCOLORS="$(tput colors 2>/dev/null)"
if [[ -t 1 ]] && [[ "$NCOLORS" =~ ^[0-9]+$ ]] && (( NCOLORS >= 256 )); then COLOR=1; fi
# Set NO_TRUECOLOR=1 before running if your terminal shows wrong colors (old terminals)
TRUECOLOR=$(( COLOR && ${NO_TRUECOLOR:-0} == 0 ))

if (( COLOR )); then
    R=$'\e[0m'; B=$'\e[1m'; DIM=$'\e[2m'; IT=$'\e[3m'                     # reset, bold, dim, italic
    RED=$'\e[38;5;196m'; GRN=$'\e[38;5;48m'; YEL=$'\e[38;5;220m'
    BLU=$'\e[38;5;39m';  CYN=$'\e[38;5;51m'; MAG=$'\e[38;5;171m'; GRY=$'\e[38;5;244m'; PNK=$'\e[38;5;205m'
    # "Pill" badges: colored background + contrasting text
    B_OK=$'\e[1;38;5;16;48;5;48m'     # black on green
    B_WARN=$'\e[1;38;5;16;48;5;220m'  # black on yellow
    B_ERR=$'\e[1;38;5;231;48;5;196m'  # white on red
    B_INFO=$'\e[1;38;5;16;48;5;45m'   # black on cyan
    B_STEP=$'\e[1;38;5;231;48;5;99m'  # white on violet
else
    R=""; B=""; DIM=""; IT=""; RED=""; GRN=""; YEL=""; BLU=""; CYN=""; MAG=""; GRY=""; PNK=""
    B_OK=""; B_WARN=""; B_ERR=""; B_INFO=""; B_STEP=""
fi

# Gradient palettes: three RGB color stops (start, middle, end)
PAL_MAIN="0 229 255  138 92 246  255 64 160"     # cyan -> violet -> pink
PAL_OK="0 255 135  0 200 255  138 92 246"        # green -> cyan -> violet
PAL_ERR="255 60 60  255 140 0  255 210 0"        # red -> orange -> yellow

# Emoji icon for each step header
STEP_ICONS=("" "🔍" "📦" "💻" "📝" "🔐" "🧪")

# Counters for the verification results shown in the final summary box
PASS=0; FAIL=0; WARN=0
# Process ID of the command currently running under the spinner (so Ctrl+C can stop it)
SPIN_PID=""
# Remember what we changed, so a failed join can put the laptop back the way it was
OLD_HOSTNAME=""        # hostname before step 3 (set only once we actually change it)
BACKUP=""              # /etc/hosts backup path (set only once we actually change /etc/hosts)
JOINED=0               # becomes 1 after ipa-client-install succeeds — then we no longer roll back
START_TIME=$SECONDS    # used to show the total run time at the end

# ─── Color / drawing helpers ──────────────────────────────────────────────────

# fg R G B: puts the escape code for that foreground color in $REPLY
# (24-bit truecolor if available, otherwise the nearest of the 256 colors)
fg() {
    if (( ! COLOR )); then REPLY=""; return; fi
    if (( TRUECOLOR )); then printf -v REPLY '\e[38;2;%d;%d;%dm' "$1" "$2" "$3"
    else printf -v REPLY '\e[38;5;%dm' $(( 16 + 36*($1*5/255) + 6*($2*5/255) + $3*5/255 )); fi
}

# color_at POS r1 g1 b1 r2 g2 b2 r3 g3 b3: color at position POS (0..1000) along a
# 3-stop gradient; result (escape code) in $REPLY
color_at() {
    local p=$1; shift
    local f r g b
    if (( p < 500 )); then
        f=$(( p * 2 ))
        r=$(( $1 + ($4 - $1) * f / 1000 )); g=$(( $2 + ($5 - $2) * f / 1000 )); b=$(( $3 + ($6 - $3) * f / 1000 ))
    else
        f=$(( (p - 500) * 2 ))
        r=$(( $4 + ($7 - $4) * f / 1000 )); g=$(( $5 + ($8 - $5) * f / 1000 )); b=$(( $6 + ($9 - $6) * f / 1000 ))
    fi
    fg "$r" "$g" "$b"
}

# gradient "text" <palette>: prints text with each character colored along the palette
gradient() {
    local t="$1"; shift
    if (( ! COLOR )); then printf '%s' "$t"; return; fi
    local n=${#t} i ch out=""
    for (( i = 0; i < n; i++ )); do
        ch="${t:i:1}"
        if [[ "$ch" == " " ]]; then out+=" "; continue; fi
        color_at $(( n > 1 ? i * 1000 / (n - 1) : 0 )) "$@"
        out+="$B$REPLY$ch"
    done
    printf '%s%s' "$out" "$R"
}

# bar PERCENT WIDTH: prints a progress bar; filled part uses the main gradient
bar() {
    local pct=$1 w=$2 i filled out=""
    filled=$(( pct * w / 100 ))
    for (( i = 0; i < w; i++ )); do
        if (( i < filled )); then
            if (( COLOR )); then color_at $(( i * 1000 / (w - 1) )) $PAL_MAIN; out+="$REPLY█"; else out+="#"; fi
        else
            if (( COLOR )); then out+=$'\e[38;5;238m'"░"; else out+="-"; fi
        fi
    done
    printf '%s%s' "$out" "$R"
}

# repeat CHAR N: prints CHAR N times (used to draw box borders)
repeat() { local s; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"; }

# fmt_time SECONDS: puts "mm:ss" in $REPLY
fmt_time() { printf -v REPLY '%02d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }

# pause SECONDS: small delay for animations — skipped when there are no colors (e.g. logging to file)
pause() { (( COLOR )) && sleep "$1"; }

# ─── UI helpers ───────────────────────────────────────────────────────────────

# banner: clears the screen, reveals the "FREEIPA" logo line by line in a gradient,
# shows an info card about this run and a short "initializing" progress animation
banner() {
    clear
    local art=(
"███████╗██████╗ ███████╗███████╗██╗██████╗  █████╗ "
"██╔════╝██╔══██╗██╔════╝██╔════╝██║██╔══██╗██╔══██╗"
"█████╗  ██████╔╝█████╗  █████╗  ██║██████╔╝███████║"
"██╔══╝  ██╔══██╗██╔══╝  ██╔══╝  ██║██╔═══╝ ██╔══██║"
"██║     ██║  ██║███████╗███████╗██║██║     ██║  ██║"
"╚═╝     ╚═╝  ╚═╝╚══════╝╚══════╝╚═╝╚═╝     ╚═╝  ╚═╝"
    )
    echo
    for line in "${art[@]}"; do
        printf '    %s\n' "$(gradient "$line" $PAL_MAIN)"
        pause 0.06                                   # line-by-line reveal
    done
    echo
    printf '    %s\n' "$(gradient "━━━━  U B U N T U   ·   D O M A I N   J O I N  ━━━━" $PAL_MAIN)"
    echo

    # Info card: what this run will connect to
    local who="${SUDO_USER:-root}"
    printf '  %s╭%s╮%s\n' "$GRY" "$(repeat ─ 52)" "$R"
    card_row "Server"   "$IPA_SERVER"
    card_row "Realm"    "$IPA_REALM"
    card_row "Domain"   "$IPA_DOMAIN"
    card_row "Machine"  "$(hostname)"
    card_row "Operator" "$who"
    card_row "Date"     "$(date '+%a %d %b %Y  %H:%M')"
    printf '  %s╰%s╯%s\n' "$GRY" "$(repeat ─ 52)" "$R"
    printf '  %s%s  v%s  ·  crafted with %s♥%s%s%s by %s%s\n' "$GRY" "$IT" "$VERSION" "$PNK" "$R" "$GRY" "$IT" "$AUTHOR" "$R"
    echo

    # Short "initializing" animation (purely visual, only on color terminals)
    if (( COLOR )); then
        tput civis 2>/dev/null
        for (( p = 0; p <= 100; p += 5 )); do
            printf '\r   %s  %sInitializing%s %3d%%' "$(bar "$p" 34)" "$GRY" "$R" "$p"
            sleep 0.03
        done
        printf '\r\e[K'
        tput cnorm 2>/dev/null
    fi
    ok "Ready — let's bring this machine into ${B}${IPA_REALM}${R}"
}

# card_row "Label" "Value": one line of the info card (value cut to 38 chars to fit)
card_row() {
    local v="${2:0:38}"
    printf '  %s│%s  %s◆%s %s%-8s%s %-38s %s│%s\n' "$GRY" "$R" "$CYN" "$R" "$GRY" "$1" "$R" "$v" "$GRY" "$R"
}

# step N "title": prints a step header with icon, badge, gradient title and an
# overall progress bar, plus a matching marker line in the log file
step() {
    local n="$1"; shift
    local pct=$(( n * 100 / TOTAL_STEPS ))
    echo
    printf '  %s╭──%s %s  %s STEP %d/%d %s  %s\n' "$GRY" "$R" "${STEP_ICONS[$n]}" "$B_STEP" "$n" "$TOTAL_STEPS" "$R" "$(gradient "$*" $PAL_MAIN)"
    printf '  %s│%s   %s %s%3d%%%s\n' "$GRY" "$R" "$(bar "$pct" 40)" "$B" "$pct" "$R"
    printf '  %s╰%s%s\n' "$GRY" "$(repeat ─ 52)" "$R"
    echo "===== STEP $n/$TOTAL_STEPS: $* ($(date '+%F %T')) =====" >>"$LOG_FILE"
}

# Status line printers: colored "pill" badge + message
# (plain-text fallback: [OK] [!!] [XX] [->])
if (( COLOR )); then
    ok()   { printf '   %s ✔ %s %s\n' "$B_OK"   "$R" "$*"; }
    warn() { printf '   %s ! %s %s\n' "$B_WARN" "$R" "$*"; }
    err()  { printf '   %s ✖ %s %s\n' "$B_ERR"  "$R" "$*"; }
    info() { printf '   %s ➜ %s %s\n' "$B_INFO" "$R" "$*"; }
else
    ok()   { printf '   [OK] %s\n' "$*"; }
    warn() { printf '   [!!] %s\n' "$*"; }
    err()  { printf '   [XX] %s\n' "$*"; }
    info() { printf '   [->] %s\n' "$*"; }
fi

# check "label" command...
#   Runs the command silently (output goes to the log), then prints ✔ or ✖
#   next to the label and adds 1 to the PASS or FAIL counter.
check() {
    local label="$1"; shift
    pause 0.12                                       # tiny delay so results "tick in" one by one
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
#   Runs a long command in the background (output goes to the log) and shows a
#   color-cycling spinner, a bouncing "scanner" bar and a mm:ss timer until it
#   finishes. Returns the command's exit code.
spin() {
    local msg="$1"; shift
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')     # spinner animation frames
    # Start the command in the background in its own process group (setsid),
    # so Ctrl+C can stop it together with any child processes it starts (e.g. apt -> dpkg)
    setsid "$@" >>"$LOG_FILE" 2>&1 &
    local pid=$! i=0 start=$SECONDS                             # remember its process ID and start time
    SPIN_PID=$pid                                               # let the Ctrl+C handler know what to stop
    local W=14 pos c d scan sc tm
    tput civis 2>/dev/null                                      # hide the cursor while spinning
    while kill -0 "$pid" 2>/dev/null; do                        # loop while the process is still alive
        fmt_time $(( SECONDS - start )); tm="$REPLY"            # elapsed time as mm:ss
        if (( COLOR )); then
            # Spinner character: color cycles along the gradient
            color_at $(( (i * 50) % 1000 )) $PAL_MAIN; sc="$REPLY"
            # Scanner bar: a bright 3-cell block bouncing left and right
            pos=$(( i % (2 * W - 2) )); (( pos >= W )) && pos=$(( 2 * W - 2 - pos ))
            scan=""
            for (( c = 0; c < W; c++ )); do
                d=$(( c > pos ? c - pos : pos - c ))
                if (( d <= 1 )); then color_at $(( c * 1000 / (W - 1) )) $PAL_MAIN; scan+="$REPLY━"
                else scan+=$'\e[38;5;238m'"─"; fi
            done
            printf '\r   %s%s%s%s  %s  %s%s  %s%s ' "$B" "$sc" "${frames[i % ${#frames[@]}]}" "$R" "$msg" "$scan" "$R" "$GRY$tm" "$R"
        else
            printf '\r   %s  %s (%s) ' "${frames[i % ${#frames[@]}]}" "$msg" "$tm"
        fi
        ((i++))
        sleep 0.08
    done
    wait "$pid"; local rc=$?                                    # collect the command's exit code
    SPIN_PID=""                                                 # nothing running in the background anymore
    tput cnorm 2>/dev/null                                      # show the cursor again
    printf '\r\e[K'                                             # clear the spinner line
    fmt_time $(( SECONDS - start ))
    if [[ $rc -eq 0 ]]; then ok "$msg ${GRY}${REPLY}${R}"
    else err "$msg ${GRY}(exit $rc)${R}"; fi
    return $rc
}

# ask "prompt" varname: shows a gradient "❯❯" prompt and stores what you type in <varname>
ask() {
    local __v
    printf '   %s %s' "$(gradient "❯❯" $PAL_MAIN)" "$1"
    # If there is no input at all (Ctrl+D, or stdin is /dev/null) stop instead of looping forever
    read -r __v || { echo; err "No input received — aborting"; exit 1; }
    printf -v "$2" '%s' "$__v"
}

# confetti: a short animation of colored sparkles (only on color terminals)
confetti() {
    (( COLOR )) || return
    local chars=('✦' '✧' '★' '•' '✶' '·' '✷' '+' '❋') cols=(196 208 220 48 51 45 99 171 205 231)
    local f r c line frames=18 rows=3
    tput civis 2>/dev/null
    for (( f = 0; f < frames; f++ )); do
        for (( r = 0; r < rows; r++ )); do
            line="  "
            for (( c = 0; c < 58; c++ )); do
                if (( RANDOM % 4 == 0 )); then
                    line+=$'\e[38;5;'"${cols[RANDOM % ${#cols[@]}]}m${chars[RANDOM % ${#chars[@]}]}"
                else
                    line+=" "
                fi
            done
            printf '%s%s\e[K\n' "$line" "$R"
        done
        sleep 0.07
        (( f < frames - 1 )) && printf '\e[%dA' "$rows"         # move back up and redraw
    done
    tput cnorm 2>/dev/null
}

# success_art: big "SUCCESS" logo revealed line by line in a green -> cyan -> violet gradient
success_art() {
    local S=("███████╗" "██╔════╝" "███████╗" "╚════██║" "███████║" "╚══════╝")
    local U=("██╗   ██╗" "██║   ██║" "██║   ██║" "██║   ██║" "╚██████╔╝" " ╚═════╝ ")
    local C=(" ██████╗" "██╔════╝" "██║     " "██║     " "╚██████╗" " ╚═════╝")
    local E=("███████╗" "██╔════╝" "█████╗  " "██╔══╝  " "███████╗" "╚══════╝")
    local i
    for i in 0 1 2 3 4 5; do
        printf '   %s\n' "$(gradient "${S[i]}${U[i]}${C[i]}${C[i]}${E[i]}${S[i]}${S[i]}" $PAL_OK)"
        pause 0.06
    done
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
# Must be root (EUID 0) — installing packages, changing hostname and joining IPA all need it
[[ $EUID -eq 0 ]] || { err "Run as root:  ${B}sudo bash $0${R}"; exit 1; }
# Start a fresh, empty log file readable only by root (it may contain sensitive output)
: >"$LOG_FILE"; chmod 600 "$LOG_FILE"

banner

# ─── STEP 1: Pre-flight ───────────────────────────────────────────────────────
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

# Show the result: the inserted line plus the first 5 lines of the new /etc/hosts,
# with the new line highlighted
ok "Inserted: ${GRN}${NEW_LINE}${R}"
printf '   %s╭─ /etc/hosts %s%s\n' "$GRY" "$(repeat ─ 38)" "$R"
head -n 5 /etc/hosts | while IFS= read -r l; do
    if [[ "$l" == 127.0.1.1* ]]; then printf '   %s│%s %s%s%s  %s◀ new%s\n' "$GRY" "$R" "$GRN$B" "$l" "$R" "$PNK" "$R"
    else printf '   %s│%s %s%s%s\n' "$GRY" "$R" "$GRY" "$l" "$R"; fi
done
printf '   %s╰%s%s\n' "$GRY" "$(repeat ─ 51)" "$R"

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
spin "Enrolling in FreeIPA (can take a few minutes)" \
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
# Success: confetti + big gradient "SUCCESS" + green box.  Failure: red box.
echo
if [[ $FAIL -eq 0 ]]; then
    confetti
    success_art
    STATUS="${GRN}${B}✔ JOINED SUCCESSFULLY${R}"; BC="$GRN"
else
    STATUS="${RED}${B}✖ JOINED WITH ${FAIL} FAILED CHECK(S)${R}"; BC="$RED"
fi

# The values shown in the box
CHECKS_TXT="${PASS} passed, ${FAIL} failed, ${WARN} warnings"
fmt_time $(( SECONDS - START_TIME )); DURATION="$REPLY"
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
HL="$(repeat ═ "$INNER")"                          # horizontal border line of the right length

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
row "Duration" "$DURATION"
row "Log"      "$LOG_FILE"
printf "  ${BC}╚%s╝${R}\n" "$HL"
echo

# On success offer a reboot (needed so the login screen picks up IPA users);
# on failure point to the log and exit with an error code
if [[ $FAIL -eq 0 ]]; then
    printf '   %s\n\n' "$(gradient "✨  Welcome to ${IPA_REALM} — this machine is now part of the domain  ✨" $PAL_OK)"
    info "Reboot, then the laptop user logs in with ${B}their own IPA account${R}"
    info "(${IPA_PRINCIPAL} was only used to join the domain) — home dir is created on first login."
    echo
    printf '   %s%s— crafted with %s♥%s%s%s by %s · v%s —%s\n\n' "$GRY" "$IT" "$PNK" "$R" "$GRY" "$IT" "$AUTHOR" "$VERSION" "$R"
    # Ask directly (not via ask) so that no input simply means "no" instead of an error exit
    printf '   %s Reboot now? [y/N] ' "$(gradient "❯❯" $PAL_MAIN)"
    read -r rb || { rb=n; echo; }
    if [[ "${rb,,}" == y* ]]; then
        # Countdown before reboot
        for s in 3 2 1; do printf '\r   %s Rebooting in %s…%s ' "$B_INFO ↻ $R" "$B$s" "$R"; sleep 1; done
        echo; reboot
    fi
    exit 0
else
    printf '   %s\n' "$(gradient "Some checks failed — review the ✖ lines above and $LOG_FILE" $PAL_ERR)"
    exit 1
fi
