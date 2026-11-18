#!/bin/bash
# Upgrade test on MariaDB: the official Kunena 5.2.14 package (pkg_kunena_v5.2.14_2022-12-14.zip, give its path in
# LEGACY_ZIP) is installed and used, then this repository's package is installed over it.
cd "$(dirname "$0")"; . ./env.sh
[ -f "$LEGACY_ZIP" ] || { echo "Set LEGACY_ZIP to the Kunena 5.2.14 package ZIP"; exit 1; }
./mkzip.sh >/dev/null; ./mksite.sh mariadb >/dev/null 2>&1 || { echo "site build failed"; exit 1; }
rm -f "$OUT/mariadb-state.json"
echo "-- legacy 5.2.14"; KUNENA_ZIP=$LEGACY_ZIP KUNENA_ALLOW_PHP_MESSAGES=1 KUNENA_EXPECT_TEMPLATE=crypsis php run.php mariadb install,wizard,site,post 2>&1 | grep -E "FAIL|passed"
# Optional: LEGACY_EXTRAS = folder with the separately distributed 5.2 extensions (unpacked, kunena.org names), to check
# that the upgrade respects their state: Kunena Discuss installed and disabled, Latest module installed, search plugin not.
if [ -n "$LEGACY_EXTRAS" ]; then
  (cd "$SITES/mariadb" && for x in plg_content_kunenadiscuss mod_kunenalatest; do
     php cli/joomla.php extension:install --path="$(ls -d "$LEGACY_EXTRAS"/${x}_* | head -1)" -n -q 2>/dev/null; done
   php cli/joomla.php extension:disable plg_content_kunenadiscuss -n -q)
  echo "-- legacy extras: Kunena Discuss (disabled) and Latest module installed"
fi
# Optional: LEGACY_LANGPACK = Kunena's language pack ZIP (pkg_kunena_languages_v5.2.14_2022-12-14.zip): it installs the
# site's languages (en-GB on a test site) into Joomla's language folders, where they would hide Meela's own strings
if [ -n "$LEGACY_LANGPACK" ]; then
  # Through the administrator, like a site owner: the pack's installer needs Kunena's classes loaded
  KUNENA_ZIP=$LEGACY_LANGPACK KUNENA_ALLOW_PHP_MESSAGES=1 php run.php mariadb install >/dev/null 2>&1
  LN=$(ls "$SITES"/mariadb/language/en-GB/en-GB.com_kunena*.ini 2>/dev/null | wc -l)
  echo "-- legacy language pack installed: $LN site files"
  [ "$LN" -gt 0 ] || { echo "legacy language pack NOT installed"; LPRC=1; }
fi
: > "$SITES/mariadb/php_errors.log"
echo "-- upgrade to this repository (keeps Crypsis: 5.2 never saved its configuration)"; KUNENA_EXPECT_TEMPLATE=crypsis php run.php mariadb install,wizard,admin,site,post,recent,profile,search,moderate 2>&1 | grep -E "FAIL|passed|messages from Kunena|^PHP|failed"; rc=${PIPESTATUS[0]}
P=$(grep -o "dbprefix = '[^']*'" "$SITES/mariadb/configuration.php" | cut -d"'" -f2)
docker exec $MARIADB_CONTAINER mariadb -ukunena -pkunena kunena -N -e "SELECT CONCAT(type,':',element,':',folder,' package_id=',package_id,' version=',JSON_VALUE(manifest_cache,'$.version')) FROM ${P}extensions WHERE element LIKE '%kunena%' ORDER BY extension_id; SELECT CONCAT('kunena_version=',version) FROM ${P}kunena_version ORDER BY id DESC LIMIT 1; SELECT CONCAT('messages=',COUNT(*)) FROM ${P}kunena_messages" 2>/dev/null
if [ -n "$LEGACY_EXTRAS" ]; then
  STATES=$(docker exec $MARIADB_CONTAINER mariadb -ukunena -pkunena kunena -N -e "SELECT CONCAT(folder,'/',element,'=',enabled) FROM ${P}extensions WHERE type='plugin' AND ((folder='content' AND element='kunenadiscuss') OR (folder='search' AND element='kunena')) ORDER BY folder" 2>/dev/null | tr '\n' ' ')
  echo "extras after upgrade: $STATES"
  case "$STATES" in *"content/kunenadiscuss=0"*"search/kunena=1"*) echo "extras state: respected";; *) echo "extras state: WRONG"; rc=1;; esac
fi
# Baldrick AI is new in 5.3.0: installed and enabled by the upgrade, its tables created by the wizard
B=$(docker exec $MARIADB_CONTAINER mariadb -ukunena -pkunena kunena -N -e "SELECT CONCAT('baldrick=',enabled) FROM ${P}extensions WHERE type='plugin' AND folder='kunena' AND element='baldrick'; SELECT CONCAT('tables=',COUNT(*)) FROM information_schema.tables WHERE table_schema='kunena' AND table_name LIKE '${P}kunena_baldrick_%'" 2>/dev/null | tr '\n' ' ')
case "$B" in "baldrick=1 tables=3 ") echo "baldrick after upgrade: $B";; *) echo "baldrick after upgrade WRONG: $B"; rc=1;; esac
# A 5.2 site that never saved Kunena's configuration ran on Crypsis: the upgrade saves it, Blackadder is for new sites
T=$(docker exec $MARIADB_CONTAINER mariadb -ukunena -pkunena kunena -N -e "SELECT JSON_VALUE(params,'$.template') FROM ${P}kunena_configuration WHERE id=1" 2>/dev/null)
[ "$T" = "crypsis" ] && echo "template after upgrade: crypsis (kept)" || { echo "template after upgrade WRONG: $T"; rc=1; }
# The third-party integration plugins of 5.2 are uninstalled by the wizard (Community Builder's too, since 5.5.0)
I=$(docker exec $MARIADB_CONTAINER mariadb -ukunena -pkunena kunena -N -e "SELECT element FROM ${P}extensions WHERE type='plugin' AND folder='kunena' AND element IN ('altauserpoints','community','easyprofile','easysocial','easyblog','uddeim','comprofiler') ORDER BY element" 2>/dev/null | tr '\n' ' ')
[ -z "$(echo $I)" ] && echo "integration plugins after upgrade: none" || { echo "integration plugins after upgrade WRONG: $I"; rc=1; }
L=$(ls -d "$SITES"/mariadb/administrator/manifests/packages/*kunena* "$SITES"/mariadb/administrator/manifests/files/*kunena* 2>/dev/null)
[ -z "$L" ] && echo "legacy package records/manifests: removed" || { echo "legacy manifests LEFT: $L"; rc=1; }
if [ -n "$LEGACY_LANGPACK" ]; then
  LP=$(ls "$SITES"/mariadb/language/*/*.com_kunena*.ini "$SITES"/mariadb/administrator/language/*/*.com_kunena*.ini 2>/dev/null)
  LR=$(docker exec $MARIADB_CONTAINER mariadb -ukunena -pkunena kunena -N -e "SELECT COUNT(*) FROM ${P}extensions WHERE element='pkg_kunena_languages' OR element LIKE 'com_kunena_%'" 2>/dev/null)
  LM=$(ls "$SITES"/mariadb/language/en-GB/en-GB.mod_kunenalatest.ini 2>/dev/null)
  [ "${LPRC:-0}" = 0 ] && [ -z "$LP" ] && [ "$LR" = "0" ] && [ -n "$LM" ] && echo "legacy language pack: removed (module languages kept)" || { echo "legacy language pack LEFT: records=$LR files=$LP module=$LM"; rc=1; }
fi
exit $rc
