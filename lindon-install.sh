#!/bin/bash
#
# lindon-install.sh
#
# Setup wrapper around the lindon (trimmed Rivolution) .deb packages.
# Run as root, from the directory containing the built .deb files
# (rivolution_*.deb, rivolution-*.deb -- *.ddeb debug packages are not
# needed and are ignored).
#
# What this does, roughly following Fred Gleason's own
# install_rivendell.sh structure (standalone/server/client), but
# installing lindon's own locally-built .deb packages instead of
# pulling rivendell/rivendell-opsguide from a repo:
#
#   1) Create the 'rd' operator account if it doesn't exist yet, and
#      set its password interactively (BEFORE installing the package,
#      so postinst's own rd-aware provisioning -- group membership,
#      /home/rd/logs, /var/snd ownership, the systemd drop-in's UID
#      resolution -- all fire correctly on first install).
#   2) Configure desktop autologin for rd (gdm3 or sddm; anything else
#      is left for manual setup, with a note at the end).
#   3) Install the local .deb files.
#   4) Ask which role this machine plays (standalone / server / client)
#      and set up NFS export or mount + [mySQL] pointing accordingly.
#      Standalone needs nothing further here -- postinst already
#      creates and seeds a local database on fresh install.
#
# Idempotent-ish: safe to re-run, but NFS export/mount and the DB
# pointer changes for "client" are not un-done if you switch roles
# later -- that's a manual cleanup, not something this script tracks.

set -e

USAGE="Usage: sudo ./lindon-install.sh"

if test "$(id -u)" != "0" ; then
    echo "This must be run as root (sudo ./lindon-install.sh)."
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

function Continue {
    read -a RESP -p "Continue (y/N) "
    echo
    if [ -z "$RESP" ] || { [ "$RESP" != "y" ] && [ "$RESP" != "Y" ] ; } ; then
        exit 0
    fi
}

# ---------------------------------------------------------------------
# Step 1: rd account
# ---------------------------------------------------------------------
function EnsureRdUser {
    if getent passwd rd >/dev/null ; then
        echo "Operator account 'rd' already exists, leaving it as-is."
        return 0
    fi

    echo
    echo "Creating the 'rd' operator account (this is the fixed account"
    echo "name the whole lindon/Rivolution stack assumes -- rdairplay,"
    echo "caed, the PipeWire session, /var/snd ownership, all of it)."
    echo
    echo "You'll be asked to set rd's password now. (Old Rivendell habit"
    echo "was to default this to 'letmein' -- please don't actually do"
    echo "that here.)"
    echo

    adduser --gecos "Rivendell Operator" rd
}

# ---------------------------------------------------------------------
# Step 2: desktop autologin
# ---------------------------------------------------------------------
function ConfigureAutologin {
    if systemctl list-unit-files 2>/dev/null | grep -q '^gdm3\.service' ; then
        echo "Detected GDM3 (GNOME) -- configuring autologin for rd."
        mkdir -p /etc/gdm3
        if test -f /etc/gdm3/custom.conf && grep -q '^\[daemon\]' /etc/gdm3/custom.conf ; then
            sed -i '/^\[daemon\]/,/^\[/{
                /^AutomaticLoginEnable=/d
                /^AutomaticLogin=/d
            }' /etc/gdm3/custom.conf
            sed -i '/^\[daemon\]/a AutomaticLoginEnable=true\nAutomaticLogin=rd' /etc/gdm3/custom.conf
        else
            cat >> /etc/gdm3/custom.conf <<GDM
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=rd
GDM
        fi
        AUTOLOGIN_CONFIGURED=1

    elif systemctl list-unit-files 2>/dev/null | grep -q '^sddm\.service' ; then
        echo "Detected SDDM (KDE Plasma) -- configuring autologin for rd."
        mkdir -p /etc/sddm.conf.d
        session=$(find /usr/share/xsessions /usr/share/wayland-sessions \
            -iname '*plasma*' 2>/dev/null | head -1 | xargs -r basename -s .desktop)
        session=${session:-plasma}
        cat > /etc/sddm.conf.d/lindon-autologin.conf <<SDDM
[Autologin]
User=rd
Session=$session
SDDM
        AUTOLOGIN_CONFIGURED=1

    else
        echo
        echo "*** No supported display manager (gdm3/sddm) detected. ***"
        echo "*** Autologin for 'rd' was NOT configured -- set it up  ***"
        echo "*** manually in your desktop's user/login settings.    ***"
        echo
        AUTOLOGIN_CONFIGURED=0
    fi
}

# ---------------------------------------------------------------------
# Step 3: package install
# ---------------------------------------------------------------------
function InstallPackages {
    echo
    echo "Installing lindon packages from $SCRIPT_DIR ..."
    debs=("$SCRIPT_DIR"/rivolution*.deb)
    if [ ! -e "${debs[0]}" ] ; then
        echo "No rivolution*.deb files found in $SCRIPT_DIR, exiting."
        exit 1
    fi
    apt -y install "${debs[@]}"
}

# ---------------------------------------------------------------------
# Step 4a: NFS export (server role)
# ---------------------------------------------------------------------
function SetupNfsServer {
    echo
    echo "Setting up NFS exports (rw) for:"
    echo "  /var/snd"
    echo "  /home/rd/import"
    echo "  /home/rd/share"
    echo -n "Enter the client subnet/host allowed to mount these [*]: "
    read RD_NFS_CLIENTS
    RD_NFS_CLIENTS=${RD_NFS_CLIENTS:-*}

    apt -y install nfs-kernel-server
    mkdir -p /home/rd/import /home/rd/share
    chown rd:rd /home/rd/import /home/rd/share

    for d in /var/snd /home/rd/import /home/rd/share ; do
        line="$d $RD_NFS_CLIENTS(rw,sync,no_subtree_check,no_root_squash)"
        grep -qF "$d " /etc/exports 2>/dev/null || echo "$line" >> /etc/exports
    done

    exportfs -ra
    systemctl enable --now nfs-kernel-server
}

# ---------------------------------------------------------------------
# Step 4b: NFS mount + remote DB pointer (client role)
# ---------------------------------------------------------------------
function SetupNfsClient {
    echo
    echo -n "Enter the IP address of the lindon server (NFS + database): "
    read RD_SERVER

    echo "Mounting /var/snd, /home/rd/import, /home/rd/share from $RD_SERVER ..."
    apt -y install nfs-common
    mkdir -p /home/rd/import /home/rd/share
    chown rd:rd /home/rd/import /home/rd/share

    for d in /var/snd /home/rd/import /home/rd/share ; do
        line="$RD_SERVER:$d $d nfs rw,_netdev 0 0"
        grep -qF "$RD_SERVER:$d " /etc/fstab 2>/dev/null || echo "$line" >> /etc/fstab
    done
    mount -a

    echo
    echo "Now pointing this machine's database connection at $RD_SERVER."
    echo "(The local database postinst already created on this machine"
    echo "is left in place but unused -- harmless, just ignore it.)"
    echo -n "MySQL/MariaDB username [rduser]: "
    read RD_MYSQL_USER
    RD_MYSQL_USER=${RD_MYSQL_USER:-rduser}
    echo -n "MySQL/MariaDB password (see Password= in /etc/rivendell.d/rd-default.conf on $RD_SERVER): "
    read -s RD_MYSQL_PASS
    echo
    echo -n "Database name [Rivendell]: "
    read RD_MYSQL_DB
    RD_MYSQL_DB=${RD_MYSQL_DB:-Rivendell}

    rd_conf_real=/etc/rivendell.d/rd-default.conf
    sed -i "/^\[mySQL\]/,/^\[/{
        s/^Hostname=.*/Hostname=$RD_SERVER/
        s/^Loginname=.*/Loginname=$RD_MYSQL_USER/
        s/^Password=.*/Password=$RD_MYSQL_PASS/
        s/^Database=.*/Database=$RD_MYSQL_DB/
    }" "$rd_conf_real"

    systemctl restart rivendell
}

# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------
echo "lindon installer"
echo "================="
echo
echo "This installs the lindon .deb packages found in:"
echo "  $SCRIPT_DIR"
echo
echo "Three roles are available:"
echo
echo " 1) Standalone. Database and audio store stay local to this"
echo "    machine (postinst already creates and seeds them). Nothing"
echo "    further to configure here."
echo
echo " 2) Server. Same as Standalone, but /var/snd, ~/import and"
echo "    ~/share are additionally exported over NFS for other lindon"
echo "    hosts to use."
echo
echo " 3) Client. Mounts /var/snd, ~/import and ~/share from another"
echo "    lindon server over NFS, and points this machine's database"
echo "    connection at that same server."
echo
echo " 4) Do nothing, and exit."
echo
read -a RESP -p " Your choice [4]? "
echo

if [ -z "$RESP" ] || [ "$RESP" == "4" ] ; then
    exit 0
fi
if [ "$RESP" != "1" ] && [ "$RESP" != "2" ] && [ "$RESP" != "3" ] ; then
    echo "Unrecognized choice: $RESP"
    exit 1
fi

EnsureRdUser
ConfigureAutologin
InstallPackages

if [ "$RESP" == "2" ] ; then
    SetupNfsServer
fi
if [ "$RESP" == "3" ] ; then
    SetupNfsClient
fi

echo
echo "================================================================"
echo " Installation complete."
echo
echo " IMPORTANT: reboot this machine now, and make sure you log in"
echo " (or are auto-logged in) as the 'rd' user, not any other"
echo " account -- rdairplay and the whole PipeWire/caed chain are"
echo " tied to that specific session."
if [ "$AUTOLOGIN_CONFIGURED" != "1" ] ; then
    echo
    echo " Autologin was NOT configured automatically -- set it up"
    echo " manually for 'rd' before rebooting, or you'll need to log"
    echo " in by hand every time."
fi
echo "================================================================"
