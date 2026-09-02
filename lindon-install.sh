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
#
# Follows Rivolution's own (proven) pattern: real directories are
# bind-mounted under /srv/nfs4/... and exported *from there*, not
# exported directly. /var/snd itself is the one path lindon actually
# needs to be present the instant the service starts, so it's handled
# separately from the on-demand autofs-managed exchange folders below.
# ---------------------------------------------------------------------
function SetupNfsServer {
    echo
    echo "Setting up NFS exports (rw) for:"
    echo "  /var/snd            -> /srv/nfs4/var/snd"
    echo "  /home/rd/import     -> /srv/nfs4/home/rd/import"
    echo "  /home/rd/share      -> /srv/nfs4/home/rd/share"
    echo -n "Enter the client subnet/host allowed to mount these [*]: "
    read RD_NFS_CLIENTS
    RD_NFS_CLIENTS=${RD_NFS_CLIENTS:-*}

    apt -y install nfs-kernel-server

    mkdir -p /home/rd/import /home/rd/share
    chown rd:rd /home/rd/import /home/rd/share

    mkdir -p /srv/nfs4/var/snd /srv/nfs4/home/rd/import /srv/nfs4/home/rd/share

    # Bind mounts: real path -> pseudo-fs export point. Idempotent --
    # skip any pair already bind-mounted, and only append an /etc/fstab
    # line (for reboot persistence) if one isn't already there.
    declare -A binds=(
        [/var/snd]=/srv/nfs4/var/snd
        [/home/rd/import]=/srv/nfs4/home/rd/import
        [/home/rd/share]=/srv/nfs4/home/rd/share
    )
    for real in "${!binds[@]}" ; do
        pseudo=${binds[$real]}
        if ! findmnt "$pseudo" >/dev/null 2>&1 ; then
            mount --bind "$real" "$pseudo"
        fi
        line="$real $pseudo none bind 0 0"
        grep -qF "$pseudo " /etc/fstab 2>/dev/null || echo "$line" >> /etc/fstab
    done

    for d in /srv/nfs4/var/snd /srv/nfs4/home/rd/import /srv/nfs4/home/rd/share ; do
        line="$d $RD_NFS_CLIENTS(rw,sync,no_subtree_check,no_root_squash)"
        grep -qF "$d " /etc/exports 2>/dev/null || echo "$line" >> /etc/exports
    done

    exportfs -ra
    systemctl enable --now nfs-kernel-server
}

# ---------------------------------------------------------------------
# Step 4b: NFS mount + remote DB pointer (client role)
#
# /var/snd: mounted immediately (needed right away) plus a persistent
# fstab entry for reboot -- matches Rivolution's own approach, no
# autofs involved for this one path.
#
# import/share: autofs, on-demand -- these are occasional-use
# exchange folders, not something rivendell.service needs present
# the instant it starts, so lazy-mounting them is fine and avoids an
# unnecessary boot-time NFS dependency for something rarely touched.
# ---------------------------------------------------------------------
function SetupNfsClient {
    echo
    echo -n "Enter the IP address of the lindon server (NFS + database): "
    read RD_SERVER

    apt -y install nfs-common autofs

    # --- /var/snd: direct mount now + persistent fstab entry ---
    mkdir -p /var/snd
    src="$RD_SERVER:/srv/nfs4/var/snd"
    if [ "$(findmnt -no SOURCE /var/snd 2>/dev/null)" != "$src" ] ; then
        mountpoint -q /var/snd && umount /var/snd
        mount -t nfs4 "$src" /var/snd
    fi
    fstab_line="$src /var/snd nfs4 rw,x-systemd.after=network-online.target 0 0"
    grep -qF "$src " /etc/fstab 2>/dev/null || echo "$fstab_line" >> /etc/fstab

    # --- import/share: autofs, on-demand via /misc/, symlinked into
    #     /home/rd for convenience ---
    mkdir -p /home/rd
    {
        echo "import -fstype=nfs4,rw $RD_SERVER:/srv/nfs4/home/rd/import"
        echo "share  -fstype=nfs4,rw $RD_SERVER:/srv/nfs4/home/rd/share"
    } > /etc/auto.rd.audiostore

    master_line="/misc /etc/auto.rd.audiostore"
    grep -qF "$master_line" /etc/auto.master 2>/dev/null || echo "$master_line" >> /etc/auto.master

    mkdir -p /misc
    systemctl enable --now autofs
    systemctl restart autofs

    for d in import share ; do
        dest="/home/rd/$d"
        src_link="/misc/$d"
        if [ "$(readlink "$dest" 2>/dev/null)" != "$src_link" ] ; then
            rm -rf "$dest"
            ln -s "$src_link" "$dest"
        fi
    done
    chown -h rd:rd /home/rd/import /home/rd/share

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
