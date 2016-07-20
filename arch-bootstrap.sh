#!/bin/bash
#
# arch-bootstrap: Bootstrap a base Arch Linux system using any GNU distribution.
#
# Dependencies: bash >= 4, coreutils, wget, sed, gawk, tar, gzip, chroot, xz.
# Project: https://github.com/tokland/arch-bootstrap
#
# Install:
#
#   # install -m 755 arch-bootstrap.sh /usr/local/bin/arch-bootstrap
#
# Usage:
#
#   # arch-bootstrap destination
#   # arch-bootstrap -a x86_64 -r ftp://ftp.archlinux.org destination-64
#
# And then you can chroot to the destination directory (user: root, password: root):
#
#   # chroot destination

set -e -u -o pipefail

# Packages needed by pacman (see get-pacman-dependencies.sh)
PACMAN_PACKAGES=(
acl archlinux-keyring attr bzip2 curl e2fsprogs expat gcc-libs glibc gpgme keyutils krb5 libarchive libassuan libgpg-error libidn libssh2 lzo openssl pacman pacman-mirrorlist xz zlib lz4
)
BASIC_PACKAGES=(${PACMAN_PACKAGES[*]} filesystem)
EXTRA_PACKAGES=(coreutils bash grep gawk file tar systemd sed)
DEFAULT_REPO_URL="http://mirrors.kernel.org/archlinux"
DEFAULT_ARM_REPO_URL="http://mirror.archlinuxarm.org"

stderr() {
  echo "$@" >&2
}

debug() {
  stderr "--- $@"
}

extract_href() {
  sed -n '/<a / s/^.*<a [^>]*href="\([^\"]*\)".*$/\1/p'
}

fetch() {
  curl -L -s "$@"
}

uncompress() {
  local FILEPATH=$1 DEST=$2

  case "$FILEPATH" in
    *.gz) bsdtar xzf "$FILEPATH" -C "$DEST";;
    *.xz) bsdtar xJf "$FILEPATH" -C "$DEST";;
    *) debug "Error: unknown package format: $FILEPATH"
       return 1;;
  esac
}

###
get_default_repo() {
  local ARCH=$1
  case "$ARCH" in
    arm*) echo $DEFAULT_ARM_REPO_URL;;
    *) echo $DEFAULT_REPO_URL;;
  esac
}

get_core_repo_url() {
  local REPO_URL=$1 ARCH=$2
  case "$ARCH" in
    arm*) echo "${REPO_URL%/}/$ARCH/core";;
    *) echo "${REPO_URL%/}/core/os/$ARCH";;
  esac
}

get_template_repo_url() {
  local REPO_URL=$1 ARCH=$2
  case "$ARCH" in
    arm*) echo "${REPO_URL%/}/\$arch/\$repo";;
    *) echo "${REPO_URL%/}/\$repo/os/\$arch";;
  esac
}

configure_pacman() {
  local DEST=$1 ARCH=$2
  debug "configure resolv and mirrors"
  ln -sf /run/resolvconf/resolv.conf ${DEST}/etc/resolv.conf
  SERVER=$(get_template_repo_url "$REPO_URL" "$ARCH")
  echo "Server = $SERVER" > "$DEST/etc/pacman.d/mirrorlist"
}

fetch_packages_list() {
  local REPO=$1 

  debug "fetch packages list: $REPO/"
  fetch "$REPO/" | extract_href | awk -F"/" '{print $NF}' | sort -rn ||
    { debug "Error: cannot fetch packages list: $REPO"; return 1; }
}

install_pacman_packages() {
  local BASIC_PACKAGES=$1 DEST=$2 LIST=$3 DOWNLOAD_DIR=$4
  debug "pacman package and dependencies: $BASIC_PACKAGES"

  for PACKAGE in $BASIC_PACKAGES; do
    local FILE=$(echo "$LIST" | grep -m1 "^$PACKAGE-[[:digit:]].*\(\.gz\|\.xz\)$")
    test "$FILE" || { debug "Error: cannot find package: $PACKAGE"; return 1; }
    local FILEPATH="$DOWNLOAD_DIR/$FILE"

    test "$FILEPATH" || \
      debug "download package: $REPO/$FILE" && \
      fetch -o "$FILEPATH" "$REPO/$FILE"
    test "${FILEPATH}.sig" || \
      debug "download package signature: $REPO/${FILE}.sig" && \
      fetch -o "$FILEPATH.sig" "$REPO/${FILE}.sig"
    debug "uncompress package: $FILEPATH"
    uncompress "$FILEPATH" "$DEST"
  done
}

configure_static_qemu() {
  local ARCH=$1
  case "$ARCH" in
    arm*) QEMU_STATIC_BIN=$(which qemu-arm-static || echo );;
  esac
  [[ -e "$QEMU_STATIC_BIN" ]] ||\
    { debug "no static qemu for $ARCH, ignoring"; return 0; }
}

install_pacman_base() {
  local ARCH=$1 DEST=$2
  debug "install pacman base group"
  SYSTEMD_BIND="--bind /run/resolvconf"
  [[ "$ARCH" =~ ^arm.* ]] && SYSTEMD_BIND="$SYSTEMD_BIND --bind $QEMU_STATIC_BIN"
  systemd-nspawn -q $SYSTEMD_BIND -D "$DEST" \
      /usr/bin/pacman --noconfirm -Syu --force base
  systemd-nspawn -q $SYSTEMD_BIND -D "$DEST" \
      /usr/bin/pacman-key --init
  systemd-nspawn -q $SYSTEMD_BIND -D "$DEST" \
      /usr/bin/pacman-key --populate archlinux
  [[ "$ARCH" =~ ^arm.* ]] && systemd-nspawn -q $SYSTEMD_BIND -D "$DEST" \
      /usr/bin/pacman-key --populate archlinuxarm
  systemd-nspawn -q $SYSTEMD_BIND -D "$DEST" \
      /usr/bin/pacman-key --refresh-keys
}

show_usage() {
  stderr "Usage: $(basename "$0") [-q] [-a i686|x86_64|arm|armv6h|armv7h|aarch64] [-r REPO_URL] [-d DOWNLOAD_DIR] DESTDIR"
}

main() {
  # Process arguments and options
  test $# -eq 0 && set -- "-h"
  local ARCH=
  local REPO_URL=
  local USE_QEMU=
  local DOWNLOAD_DIR=

  while getopts "qa:r:d:h" ARG; do
    case "$ARG" in
      a) ARCH=$OPTARG;;
      r) REPO_URL=$OPTARG;;
      q) USE_QEMU=true;;
      d) DOWNLOAD_DIR=$OPTARG;;
      *) show_usage; return 1;;
    esac
  done
  shift $(($OPTIND-1))
  test $# -eq 1 || { show_usage; return 1; }

  [[ -z "$ARCH" ]] && ARCH=$(uname -m)
  [[ -z "$REPO_URL" ]] && REPO_URL=$(get_default_repo "$ARCH")

  local DEST=$1
  local REPO=$(get_core_repo_url "$REPO_URL" "$ARCH")
  [[ -z "$DOWNLOAD_DIR" ]] && DOWNLOAD_DIR=$(mktemp -d)
  mkdir -p "$DOWNLOAD_DIR"
  [[ "$DOWNLOAD_DIR" ]] && trap "rm -rf '$DOWNLOAD_DIR'" KILL TERM EXIT
  debug "destination directory: $DEST"
  debug "core repository: $REPO"
  debug "temporary directory: $DOWNLOAD_DIR"

  # Fetch packages, install system and do a minimal configuration
  mkdir -p "$DEST"
  [[ "$ARCH" =~ ^arm.* ]] && BASIC_PACKAGES=(${BASIC_PACKAGES[*]} archlinuxarm-keyring)
  local LIST=$(fetch_packages_list $REPO)
  install_pacman_packages "${BASIC_PACKAGES[*]} ${EXTRA_PACKAGES[*]}" "$DEST" "$LIST" "$DOWNLOAD_DIR"
  configure_pacman "$DEST" "$ARCH"
  [[ -n "$USE_QEMU" ]] && configure_static_qemu "$ARCH"
  install_pacman_base "$ARCH" "$DEST"
  [[ "$DOWNLOAD_DIR" ]] && rm -rf "$DOWNLOAD_DIR"

  debug "done"
}

main "$@"
