#!/usr/bin/env bash
# Pin the upstream toolchain. Cloned shallow and recorded by commit so a later
# rebuild is reproducible; vendor/ is gitignored, this script is the source of truth.
. "$(dirname "$0")/lib.sh"

V="$ROOT/vendor"
mkdir -p "$V"

if [ -d "$V/OpenStick-Builder/.git" ]; then
  log "already present: $(git -C "$V/OpenStick-Builder" rev-parse HEAD)"
else
  need git
  log "cloning kinsamanka/OpenStick-Builder (debian branch)"
  git clone --depth 1 https://github.com/kinsamanka/OpenStick-Builder.git "$V/OpenStick-Builder"
fi

cd "$V/OpenStick-Builder" || die "no $V/OpenStick-Builder"
HEAD=$(git rev-parse HEAD)

log "writing $ROOT/vendor.lock"
{
  echo "repo=https://github.com/kinsamanka/OpenStick-Builder"
  echo "branch=$(git -c advice.detachedHead=false branch -r --contains HEAD 2>/dev/null | head -1 | tr -d ' ')"
  echo "commit=$HEAD"
  echo "captured=$(date -u +%FT%TZ)"
  echo "kernel=https://pkgs.postmarketos.org/package/v24.06/postmarketos/aarch64/linux-postmarketos-qcom-msm8916"
  echo "submodules:"
  git config --file .gitmodules --get-regexp path | awk '{print "  "$2}'
  echo "trixie_patch_required=scripts/setup.sh libconfig9 -> libconfig11"
  echo "default_board_target=yiming-uz801v3  # NOT this stick: override extlinux/devicetree"
} > "$ROOT/vendor.lock"
cat "$ROOT/vendor.lock"

log "known deltas against this stick (read before using the builder as-is)"
cat <<'TXT'
  * builder's extract_fw.sh REPARTITIONS the eMMC and flashes a custom lk2nd aboot +
    qhypstub hyp. That is not needed for a userland-only trixie change and it destroys
    the vendor partition table your rollback depends on.
  * builder's dtbs/ ships only msm8916-fy-mf800.dtb and msm8916-jz01-45-v33.dtb; the
    extlinux default is yiming-uz801v3. There is no handsome-openstick dtb here.
  * scripts/setup.sh installs libconfig9, which trixie renamed to libconfig11.
  * setup.sh also expects `gc`/gadget-tools built from src/gt - the stock adbd on the
    stick is a vendor binary owned by no package, so keep backup/usr-bin-adbd.
TXT
