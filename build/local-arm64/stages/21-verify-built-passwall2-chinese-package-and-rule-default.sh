#!/usr/bin/env bash
# Original workflow step: Verify built PassWall2 Chinese package and rule defaults
# REVIEW REQUIRED: not yet adapted for local execution.

set -euo pipefail
# R76S_V12_CANDIDATE_LOCAL_BUILD_GUARD_20261010
cd openwrt
echo "===== Stage tree diagnostics (not final-image evidence) ====="
mkdir -p "$GITHUB_WORKSPACE/r76s-build-diagnostics"
python3 ../scripts/r76s-v111-final-audit.py --phase stage --openwrt . \
  | tee "$GITHUB_WORKSPACE/r76s-build-diagnostics/staging-tree-audit.log"
echo "STAGING_ONLY_CHECK=PASS_FINAL_IMAGE_GATE_PENDING"

echo "===== Verify PassWall / PassWall2 package defaults after build ====="
PW1_DEFAULT="package/passwall-luci/luci-app-passwall/root/usr/share/passwall/0_default_config"
PW2_DEFAULT="package/passwall2-luci/luci-app-passwall2/root/usr/share/passwall2/0_default_config"
PW1_COUNT="$(grep -c '^config shunt_rules ' "$PW1_DEFAULT")"
PW2_COUNT="$(grep -c '^config shunt_rules ' "$PW2_DEFAULT")"
test "$PW1_COUNT" -eq 43
test "$PW2_COUNT" -eq 43
grep -qF "config nodes 'myshunt'" "$PW1_DEFAULT"
grep -qF "config nodes 'myshunt'" "$PW2_DEFAULT"

PW2_LANG_IPK="$(find bin -type f -name 'luci-i18n-passwall2-zh-cn*.ipk' | head -n1)"
test -n "$PW2_LANG_IPK"
test -s "$PW2_LANG_IPK"
echo "PassWall2 zh-cn package: $PW2_LANG_IPK"

PW2_LMO="$(find build_dir/target-* -type f \( \
  -path '*/root-*/usr/lib/lua/luci/i18n/passwall2.zh-cn.lmo' -o \
  -path '*/root-*/usr/share/luci/i18n/passwall2.zh-cn.lmo' \
\) -print -quit)"
if [ -n "$PW2_LMO" ] && [ -s "$PW2_LMO" ]; then
  echo "PASSWALL2_STAGING_LMO=$PW2_LMO"
else
  echo 'PASSWALL2_STAGING_LMO=NOT_FOUND; actual image will be checked'
fi
