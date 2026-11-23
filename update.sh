#!/usr/bin/env bash
# Upgrade digitalcollections.library.appstate.edu to Omeka S 4.2.1.
#
# Runs as a regular user who can write to the site folder. The only privileged
# command it uses is `sudo systemctl reload php-fpm`. Run each phase in order and
# read its output before the next one:
#
#   bash omeka-s-update.sh check      # 1.   read-only pre-flight
#   bash omeka-s-update.sh prepare    # 2-4. back up DB, stage 4.2.1, update modules (live site untouched)
#   bash omeka-s-update.sh swap       # 5.   put 4.2.1 live, then do the browser steps it prints
#   bash omeka-s-update.sh rollback   #      only if needed
#   bash omeka-s-update.sh cleanup    #      after a week or so
#
# Settings can also come from the environment, e.g. OMEKA=/var/www/omeka-s bash omeka-s-update.sh check
# For a later Omeka S release, change VERSION and ZIP_SHA256 (sha256sum of the release zip).
# Needs bash, php (CLI), curl, unzip, mysqldump/mysql; git to update modules.

[ -n "$BASH_VERSION" ] || { echo "Run this with bash: bash $0 check"; exit 1; }
umask 022                           # new code has to be readable by the web server

OMEKA=${OMEKA:-/var/www/html}       # the site's DocumentRoot (the folder that contains config/database.ini)
SITE_URL=${SITE_URL:-https://digitalcollections.library.appstate.edu}
SITE_URL=${SITE_URL%/}
VERSION=4.2.1
ZIP_SHA256=cc27d1c7aca0209523d19aa285f4a08e29e34950dcc446951a7c1311de348e82
MIN_PHP=8.1                         # Omeka S 4.2 needs PHP 8.1 or newer
MODULE_ORG=${MODULE_ORG:-https://github.com/omeka-s-modules}   # official modules, updated automatically
ALLOW_INCOMPATIBLE=${ALLOW_INCOMPATIBLE:-no}   # yes = go ahead even if an installed module won't load on $VERSION

# Work folder. It must be on the same filesystem as the site so the swap is only
# renames. By default it sits inside the web root, closed off with a deny-all
# .htaccess, and neither code copy in it ever holds a working database.ini.
WORK=${WORK:-$OMEKA/.upgrade}
NEW="$WORK/omeka-s-$VERSION"                # staging copy
STOCK="$WORK/stock-config"                  # the release's own config/ and .htaccess, set aside
OLD="$WORK/old"                             # the code it replaced, kept for rollback
FAILED="$WORK/failed"                       # the $VERSION code after a rollback
READY="$WORK/ready"                         # written only when 'prepare' finishes
DUMP="$HOME/omeka-s-db-pre-$VERSION.sql.gz" # database backup
KEEP=(files logs)                           # never move: uploads and logs, owned by the web server

export GIT_TERMINAL_PROMPT=0                # a missing repo must fail, not ask for a password


die()     { echo "STOP: $*" >&2; exit 1; }
heading() { printf '\n== %s\n' "$*"; }

version_of() { sed -n "s/.*const VERSION = '\([^']*\)'.*/\1/p" "$1/application/Module.php"; }

# The work folder's name if it sits directly in the web root (the swap leaves it alone)
work_name() { [ "$(dirname "$WORK")" = "$OMEKA" ] && basename "$WORK"; }

load_db_creds() {
  eval "$(php -r '
    $c = parse_ini_file($argv[1]);
    foreach (["host", "user", "password", "dbname", "port", "unix_socket"] as $k)
        echo "DB_$k=", escapeshellarg($c[$k] ?? ""), "\n";
  ' "$OMEKA/config/database.ini")"
  [ -n "$DB_dbname" ] || die "couldn't read the database settings in $OMEKA/config/database.ini"
  DB_OPTS=(-u "$DB_user")
  if [ -n "$DB_unix_socket" ]; then DB_OPTS+=(-S "$DB_unix_socket"); else
    DB_OPTS+=(-h "${DB_host:-localhost}" ${DB_port:+-P "$DB_port"}); fi
}

db_sql() { MYSQL_PWD="$DB_password" mysql -N "${DB_OPTS[@]}" "$DB_dbname" -e "$1"; }

reload_php() {   # clears PHP's opcache so it runs the code that's on disk now
  if sudo -n systemctl reload php-fpm 2>/dev/null; then
    echo "reloaded php-fpm"
  else
    echo "(couldn't run 'sudo systemctl reload php-fpm'; have the admin reload php-fpm now)"
  fi
}

# park FROM TO [NAME...]: rename everything in FROM except NAMEs into TO
park() {
  local from=$1 to=$2 skip=() n
  shift 2
  for n in "$@"; do skip+=(! -name "$n"); done
  mkdir -p "$to" && find "$from" -mindepth 1 -maxdepth 1 "${skip[@]}" -exec mv -t "$to" {} +
}

# Can this user make every rename the swap needs? (A folder that moves to another
# folder has to be writable itself; files only need their folder to be writable.)
can_swap() {
  local ok=0 e w
  w=$(work_name)
  for e in "$OMEKA" "$OMEKA/config" "$HOME"; do
    [ -w "$e" ] || { echo "not writable by $(id -un): $e"; ok=1; }
  done
  while IFS= read -r e; do
    [ -w "$e" ] || { echo "not writable by $(id -un) (the swap moves it): $e"; ok=1; }
  done < <(find "$OMEKA" -mindepth 1 -maxdepth 1 -type d ! -name files ! -name logs ${w:+! -name "$w"})
  return $ok
}

ini()    { php -r '$i = @parse_ini_file($argv[1], true); echo $i["info"][$argv[2]] ?? $i[$argv[2]] ?? "";' "$1" "$2"; }
newer()  { php -r 'exit(version_compare($argv[1], $argv[2], ">") ? 0 : 1);' "$1" "$2"; }
# fits RELEASE_DIR CONSTRAINT: does $VERSION satisfy it? (empty constraint = yes)
fits()   { [ -z "$2" ] || php -r 'require $argv[1] . "/vendor/autoload.php";
             exit(Composer\Semver\Semver::satisfies($argv[2], $argv[3]) ? 0 : 1);' "$1" "$VERSION" "$2" 2>/dev/null; }

# Release tags of an official module, newest first (empty if it isn't one, or there's no git)
module_tags() {
  command -v git >/dev/null || return 0
  timeout 30 git ls-remote --tags --refs "$MODULE_ORG/$1.git" 2>/dev/null |
    sed 's#.*refs/tags/##' | grep -E '^v?[0-9]+(\.[0-9]+)*$' | sort -rV
}

# find_update RELEASE_DIR MODULE_DIR TMP: download the newest official release of the
# module that is newer than the installed copy (or any release, if the installed copy
# won't run on $VERSION) and whose constraint allows $VERSION. Prints "version path".
find_update() {
  local rel=$1 d=$2 tmp=$3 have name broken=no t v n=0 got
  have=$(ini "$d/config/module.ini" version)
  name=$(ini "$d/config/module.ini" name)
  fits "$rel" "$(ini "$d/config/module.ini" omeka_version_constraint)" || broken=yes
  for t in $(module_tags "$(basename "$d")"); do
    v=${t#v}
    [ $broken = yes ] || newer "$v" "$have" || break
    n=$((n + 1)); [ $n -le 8 ] || break
    rm -rf "$tmp/x"; mkdir -p "$tmp/x"
    curl -fsSL --retry 2 "$MODULE_ORG/$(basename "$d")/releases/download/$t/$(basename "$d")-$v.zip" -o "$tmp/m.zip" &&
      unzip -q "$tmp/m.zip" -d "$tmp/x" || continue
    got="$tmp/x/$(basename "$d")"
    [ -f "$got/config/module.ini" ] && [ "$(ini "$got/config/module.ini" name)" = "$name" ] || continue
    fits "$rel" "$(ini "$got/config/module.ini" omeka_version_constraint)" || continue
    [ $broken = no ] || [ "$v" != "$have" ] || continue
    echo "$v $got"; return 0
  done
  return 1
}

# stage_release DIR: download, verify and unpack $VERSION into DIR/omeka-s
stage_release() {
  ( cd "$1" &&
    curl -fsSLO --retry 3 "https://github.com/omeka/omeka-s/releases/download/v$VERSION/omeka-s-$VERSION.zip" &&
    echo "$ZIP_SHA256  omeka-s-$VERSION.zip" | sha256sum -c --quiet &&
    unzip -q "omeka-s-$VERSION.zip" )
}


# -- 1. Pre-flight (read-only)
check() {
  local tmpd r
  tmpd=$(mktemp -d) || die "can't make a temporary folder"
  run_checks "$tmpd"; r=$?
  rm -rf "$tmpd"
  return $r
}

run_checks() {
  local tmpd=$1 problems=0 c d oldv probe out ver have need st upd installed used

  heading "Tools"
  for c in php curl unzip mysqldump mysql sha256sum; do
    command -v "$c" >/dev/null || { echo "missing: $c"; problems=1; }
  done
  command -v git >/dev/null || echo "no git: modules will be kept as they are (install git to get module updates)"
  echo "command-line $(php -v | head -1)"
  command -v getenforce >/dev/null && echo "SELinux: $(getenforce)"
  if sudo -n -l systemctl reload php-fpm >/dev/null 2>&1; then
    echo "sudo systemctl reload php-fpm: allowed"
  else
    echo "sudo systemctl reload php-fpm: not allowed without a password (you'd need the admin to reload it)"
  fi

  heading "PHP the web server runs ($VERSION needs $MIN_PHP+ with pdo_mysql, mbstring, xml, fileinfo)"
  # The site's PHP (php-fpm) can differ from the command line's, so ask the web server.
  # Omeka's .htaccess sends every .php request to index.php, so the probe gets a
  # throwaway folder with rewriting off; it's deleted straight after.
  probe="upgrade-probe-$RANDOM$RANDOM"
  if mkdir "$OMEKA/$probe" 2>/dev/null; then
    echo 'RewriteEngine Off' > "$OMEKA/$probe/.htaccess"
    printf '%s\n' '<?php header("Content-Type: text/plain");' \
      'echo PHP_VERSION, " "; foreach (["pdo_mysql","mbstring","xml","fileinfo"] as $e) if (!extension_loaded($e)) echo "missing-$e ";' \
      > "$OMEKA/$probe/v.php"
    chmod -R go+rX "$OMEKA/$probe"
    out=$(curl -fsS --max-time 15 "$SITE_URL/$probe/v.php" 2>/dev/null)
    rm -rf "${OMEKA:?}/$probe"
  fi
  ver=${out%% *}
  if [[ $ver =~ ^[0-9]+\.[0-9]+ ]]; then
    echo "web server: PHP $out"
    php -r 'exit(version_compare($argv[1], $argv[2], ">=") ? 0 : 1);' "$ver" "$MIN_PHP" ||
      { echo "PHP $ver is older than $MIN_PHP; the admin has to upgrade PHP first (RHEL: dnf module switch-to php:8.2)"; problems=1; }
    [[ $out == *missing-* ]] && { echo "the web server's PHP is missing extensions listed above"; problems=1; }
  else
    echo "couldn't ask the web server ($SITE_URL/$probe/v.php); check Admin -> System information instead"
    php -r 'exit(version_compare(PHP_VERSION, $argv[1], ">=") ? 0 : 1);' "$MIN_PHP" ||
      { echo "command-line PHP is older than $MIN_PHP"; problems=1; }
  fi

  heading "Write access"
  if can_swap; then echo "OK: $(id -un) can make every move the swap needs"; else problems=1; fi

  heading "Release $VERSION"
  oldv=$(version_of "$OMEKA")
  echo "Omeka S $oldv  ->  $VERSION"
  newer "$VERSION" "$oldv" || { echo "the site is already on $oldv"; problems=1; }
  stage_release "$tmpd" || { echo "couldn't download or verify omeka-s-$VERSION.zip"; return 1; }
  echo "downloaded and checksum OK"

  load_db_creds
  db_sql "SELECT 1" >/dev/null || { echo "can't connect to the database with config/database.ini"; problems=1; }
  installed=" $(db_sql "SELECT id FROM module" 2>/dev/null | tr '\n' ' ') "
  used=" $(db_sql "SELECT DISTINCT theme FROM site" 2>/dev/null | tr '\n' ' ') "

  heading "Modules  (official ones get the newest release that runs on $VERSION)"
  for d in "$OMEKA"/modules/*/; do
    d=${d%/}; c=$(basename "$d")
    [ -f "$d/config/module.ini" ] || { echo "skip    $c (no config/module.ini)"; continue; }
    have=$(ini "$d/config/module.ini" version)
    need=$(ini "$d/config/module.ini" omeka_version_constraint)
    st=ok; fits "$tmpd/omeka-s" "$need" || st=incompatible
    if upd=$(find_update "$tmpd/omeka-s" "$d" "$tmpd/m"); then
      echo "update  $c $have -> ${upd%% *}$([ $st = ok ] || echo "  ($have needs Omeka S $need)")"
    elif [ $st = ok ]; then
      echo "ok      $c $have"
    elif [[ $installed == *" $c "* ]]; then
      echo "BROKEN  $c $have needs Omeka S $need and no official release fixes it$(command -v git >/dev/null || echo " (no git to look)")"
      [ "$ALLOW_INCOMPATIBLE" = yes ] || problems=1
    else
      echo "unused  $c $have needs Omeka S $need (not installed, so it doesn't matter)"
    fi
  done
  [ -d "$tmpd/m" ] && rm -rf "$tmpd/m"

  heading "Themes"
  for d in "$OMEKA"/themes/*/; do
    d=${d%/}; c=$(basename "$d")
    [ -e "$tmpd/omeka-s/themes/$c" ] && { echo "bundled $c (comes from $VERSION)"; continue; }
    need=$(ini "$d/config/theme.ini" omeka_version_constraint)
    if fits "$tmpd/omeka-s" "$need"; then echo "ok      $c ${need:+($need)}"
    elif [[ $used == *" $c "* ]]; then echo "BROKEN  $c needs Omeka S $need and a site uses it"; problems=1
    else echo "unused  $c needs Omeka S $need (no site uses it)"; fi
  done

  heading "Core files that differ from stock $oldv"
  echo "(config/ and .htaccess move to the new version, robots.txt and other extra"
  echo " files are copied, files/ and logs/ stay put; anything else here is a local edit to re-apply)"
  mkdir -p "$tmpd/old" &&
    curl -fsSL --retry 3 "https://github.com/omeka/omeka-s/releases/download/v$oldv/omeka-s-$oldv.zip" -o "$tmpd/old/s.zip" &&
    unzip -q "$tmpd/old/s.zip" -d "$tmpd/old" &&
    diff -rq -x files -x logs -x modules -x themes -x config -x .htaccess "$tmpd/old/omeka-s" "$OMEKA" |
      grep -v "^Only in $OMEKA"
  [ -f "$tmpd/old/omeka-s/.htaccess" ] && ! cmp -s "$tmpd/old/omeka-s/.htaccess" "$OMEKA/.htaccess" &&
    echo "(.htaccess has local changes; they're kept, since the live .htaccess moves over)"
  for d in "$tmpd/old/omeka-s/themes"/*/; do
    c=$(basename "$d")
    diff -rq "$d" "$OMEKA/themes/$c" >/dev/null 2>&1 ||
      echo "bundled theme '$c' has local edits; $VERSION replaces it (copy it under a new name to keep them)"
  done

  echo
  if [ "$problems" = 0 ]; then echo "Pre-flight OK."; else echo "Fix the items above before 'prepare'."; fi
  return $problems
}


# -- 2-4. Back up, stage, update modules (live site untouched)
prepare() {
  local f d c w have upd last colstats= tmp
  w=$(work_name)

  check || die "pre-flight found problems"
  [ -e "$OLD" ] && die "$OLD already exists; has the swap already run?"

  mkdir -p "$WORK" || die "can't create $WORK"
  [ "$(stat -c %d "$WORK")" = "$(stat -c %d "$OMEKA")" ] ||
    die "$WORK has to be on the same filesystem as $OMEKA"
  if [ -n "$w" ]; then      # inside the web root: keep it off the web
    printf '%s\n' '# Created by omeka-s-update.sh: keeps the upgrade work folder off the web' \
      '<IfModule mod_authz_core.c>' '    Require all denied' '</IfModule>' \
      '<IfModule !mod_authz_core.c>' '    Order allow,deny' '    Deny from all' '</IfModule>' \
      > "$WORK/.htaccess" || die "can't write $WORK/.htaccess"
  fi
  rm -f "$READY"
  rm -rf "$NEW" "$FAILED" "$STOCK" "$WORK/omeka-s" "$WORK"/omeka-s-*.zip

  heading "2. Database backup -> $DUMP"
  load_db_creds
  # MySQL 8's mysqldump wants this off when the server is MariaDB; MariaDB's doesn't have it
  mysqldump --help 2>/dev/null | grep -q -- '--column-statistics' && colstats=--column-statistics=0
  ( umask 077                                   # the dump holds user emails and password hashes
    MYSQL_PWD="$DB_password" mysqldump --single-transaction --no-tablespaces --routines $colstats \
        "${DB_OPTS[@]}" "$DB_dbname" | gzip > "$DUMP" )
  last=$(zcat "$DUMP" | tail -1)
  [[ $last == *"Dump completed"* ]] || die "database backup is incomplete: $DUMP"
  echo "$last"

  heading "3. Stage $VERSION in $NEW"
  stage_release "$WORK" || die "download, checksum or unzip failed"
  mv "$WORK/omeka-s" "$NEW" || die "couldn't rename the staging folder"
  # The release's config files and .htaccess get replaced by yours at the swap
  mkdir -p "$STOCK" && park "$NEW/config" "$STOCK" && mv "$NEW/.htaccess" "$STOCK/htaccess" ||
    die "couldn't set the release's config aside"

  # Anything else in the docroot the release doesn't ship (robots.txt, verification files, ...)
  while IFS= read -r f; do
    [ "$f" = "$w" ] || [ "$f" = .htaccess ] && continue
    echo "carry over: $f"
    cp -a "$OMEKA/$f" "$NEW/" || die "couldn't copy $OMEKA/$f"
  done < <(comm -23 <(ls -A "$OMEKA" | sort) <(ls -A "$NEW" | sort))

  # Your modules and themes (the bundled default theme comes from the new release)
  for d in "$OMEKA"/modules/*/ "$OMEKA"/themes/*/; do
    c=${d#"$OMEKA"/}; c=${c%/}
    [ -e "$NEW/$c" ] || cp -a "$OMEKA/$c" "$NEW/$c" || die "couldn't copy $OMEKA/$c"
  done

  heading "4. Update official modules in the staging copy"
  for d in "$NEW"/modules/*/; do
    d=${d%/}; c=$(basename "$d")
    [ -f "$d/config/module.ini" ] || continue
    have=$(ini "$d/config/module.ini" version)
    tmp=$(mktemp -d -p "$WORK")
    if upd=$(find_update "$NEW" "$d" "$tmp"); then
      rm -rf "$d" && mv "${upd#* }" "$d" && echo "update  $c $have -> ${upd%% *}" ||
        die "couldn't replace $c in $NEW/modules"
    else
      echo "keep    $c $have"
    fi
    rm -rf "$tmp"
  done

  # Readable by the web server, whatever modes the copied modules/themes had
  chmod -R u+rwX,go+rX "$NEW" || die "couldn't set permissions in $NEW"
  # config/ itself replaces yours, so give it your folder's mode and group
  chmod --reference="$OMEKA/config" "$NEW/config" 2>/dev/null
  chgrp --reference="$OMEKA/config" "$NEW/config" 2>/dev/null ||
    echo "note: couldn't give $NEW/config the group of $OMEKA/config ($(stat -c %G "$OMEKA/config")); check config/ after the swap"
  # SELinux: files made here inherit the web root's label; fix them if they didn't
  if command -v selinuxenabled >/dev/null && selinuxenabled &&
     [ "$(stat -c %C "$NEW/index.php")" != "$(stat -c %C "$OMEKA/index.php")" ]; then
    chcon -R --reference="$OMEKA/index.php" "$NEW" ||
      die "SELinux labels in $NEW don't match the live site; ask the admin to run: chcon -R --reference=$OMEKA/index.php $NEW"
  fi

  touch "$READY"
  echo
  echo "Staged in $NEW. The live site hasn't changed."
  echo "Next: bash $0 swap   (then the browser steps it prints)"
}


# -- 5. Swap the staged copy in (public site shows "maintenance" until the DB update)
swap() {
  local w
  w=$(work_name)
  [ -f "$READY" ] || die "'prepare' hasn't finished successfully; run it (again) first"
  [ -e "$OLD" ] && die "$OLD already exists; has the swap already run?"
  [ -f "$DUMP" ] || die "no database backup at $DUMP; run 'prepare' first"
  [ -f "$OMEKA/config/database.ini" ] || die "$OMEKA/config/database.ini is missing"
  [ -f "$OMEKA/.htaccess" ] || die "$OMEKA/.htaccess is missing"
  can_swap || die "fix the write access above first"

  # Your config files move into the new copy as is (owner, mode and SELinux label kept).
  # Then old code out, new code in. files/ and logs/ never move.
  park "$OMEKA/config" "$NEW/config" &&
    mv "$OMEKA/.htaccess" "$NEW/.htaccess" &&
    park "$OMEKA" "$OLD" "${KEEP[@]}" ${w:+"$w"} &&
    park "$NEW" "$OMEKA" "${KEEP[@]}" ||
    die "swap failed part-way; old code is in $OLD, new code in $NEW"
  rm -f "$READY"
  reload_php

  cat <<EOF

$OMEKA is now Omeka S $(version_of "$OMEKA"). Do these in the browser right away
(the public site shows a maintenance page until step 6):
  6. $SITE_URL/admin  ->  log in  ->  "Update database"
  7. Admin -> Modules -> click "Upgrade" on every module that shows it
  8. Spot-check: a site's home page, an item with an image, a search,
     Admin -> System information (should say $VERSION)
If something's wrong: bash $0 rollback
EOF
}


# -- Rollback: old code + pre-upgrade database
rollback() {
  local w want fixed extra
  w=$(work_name)
  [ -d "$OLD" ] && [ -n "$(ls -A "$OLD")" ] || die "no previous version in $OLD"
  [ -f "$DUMP" ] || die "no database backup at $DUMP"
  [ -e "$FAILED" ] && die "$FAILED already exists; move it out of the way first"
  [ -f "$OMEKA/config/database.ini" ] || die "$OMEKA/config/database.ini is missing"
  [ -f "$OMEKA/.htaccess" ] || die "$OMEKA/.htaccess is missing"

  park "$OMEKA/config" "$OLD/config" &&
    mv "$OMEKA/.htaccess" "$OLD/.htaccess" &&
    park "$OMEKA" "$FAILED" "${KEEP[@]}" ${w:+"$w"} &&
    park "$OLD" "$OMEKA" "${KEEP[@]}" ||
    die "rollback failed part-way; see $FAILED and $OLD"
  rm -rf "$OLD"
  reload_php          # before the restore, so no request runs cached $VERSION code against the old DB

  load_db_creds
  # Tables a module upgrade added aren't in the backup; drop them so a retry starts clean
  extra=$(comm -23 <(db_sql "SHOW TABLES" | sort) <(zcat "$DUMP" | sed -n 's/^CREATE TABLE `\([^`]*\)`.*/\1/p' | sort))
  if [ -n "$extra" ]; then
    echo "dropping tables added since the backup: $(echo $extra)"
    db_sql "SET FOREIGN_KEY_CHECKS=0; $(printf 'DROP TABLE `%s`; ' $extra)" || die "couldn't drop the new tables"
  fi
  zcat "$DUMP" | MYSQL_PWD="$DB_password" mysql "${DB_OPTS[@]}" "$DB_dbname" || die "database restore failed"
  reload_php

  # A request that ran cached new code against the restored database could stamp it
  # with the new version. A retry would then skip the migrations, so put the real one back.
  sleep 3
  want=$(version_of "$OMEKA")
  fixed=$(db_sql "UPDATE setting SET value='\"$want\"' WHERE id='version' AND value<>'\"$want\"'; SELECT ROW_COUNT();")
  [ "$fixed" = 0 ] || echo "(reset the database's stored version back to $want)"

  echo "Rolled back to Omeka S $want and the pre-upgrade database. $VERSION is in $FAILED."
}


# -- Cleanup (after a week or so)
cleanup() {
  local answer
  read -rp "Delete $WORK (old code, staging copy, downloads)? You can't roll back after this. [y/N] " answer
  [[ $answer == [yY]* ]] || die "nothing deleted"
  find "$WORK" -mindepth 1 -delete || die "couldn't delete everything in $WORK"
  rmdir "$WORK" 2>/dev/null
  echo "Removed $WORK. The database backup is still at $DUMP."
}


[ -f "$OMEKA/config/database.ini" ] && [ -f "$OMEKA/application/Module.php" ] ||
  die "OMEKA=$OMEKA doesn't look like the Omeka S folder; edit the OMEKA= line at the top"

case "$1" in
  check|prepare|swap|rollback|cleanup) "$1" ;;
  *) sed -n '2,17p' "$0"; exit 1 ;;
esac
