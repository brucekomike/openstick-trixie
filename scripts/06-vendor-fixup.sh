#!/usr/bin/env bash
# Apply the deltas this board/release needs to the vendored builder, and print the
# parts of the builder you must NOT run. Idempotent; edits only the gitignored
# vendor/ copy so the pin stays verifiable with `git -C vendor/OpenStick-Builder diff`.
. "$(dirname "$0")/lib.sh"

V="$ROOT/vendor/OpenStick-Builder"
[ -d "$V" ] || die "run scripts/05-fetch-vendor.sh first"

log "trixie package rename: libconfig9 -> libconfig11"
if grep -q 'libconfig9' "$V/scripts/setup.sh"; then
  sed -i 's/libconfig9/libconfig11/' "$V/scripts/setup.sh"
  echo "  patched scripts/setup.sh"
else
  echo "  already patched (or upstream changed)"
fi

log "board target: builder defaults to yiming-uz801v3, this stick is handsome-openstick"
grep -n 'uz801\|devicetree\|extlinux' "$V/scripts/build_images.sh" "$V/configs/extlinux.conf" 2>/dev/null | sed 's/^/  /' || true
cat <<'EOF'
  No handsome-openstick dtb ships in the builder (dtbs/ holds only fy-mf800 and
  jz01-45-v33) and the community kernel's release branch only has thwc-uf896,
  thwc-ufi001c and yiming-uz801v3. Options, in risk order:
    a) keep the stock boot partition (route A) - no dtb problem at all
    b) build a boot.img around the *extracted stock dtb* - scripts/60-build-bootimg.sh
    c) borrow thwc-ufi001c.dtb - plausible but unverified: wrong GPIO/PA_EN/wifi power
       is a real possibility, and a wrong DTB can leave the stick unable to boot
EOF

log "steps of the builder that repartition the eMMC - do not run them for route A"
cat <<'EOF'
  vendor/OpenStick-Builder/scripts/extract_fw.sh   rewrites the GPT
  vendor/OpenStick-Builder/scripts/build_hyp_aboot.sh  builds lk2nd + qhypstub aboot
  + README's `fastboot flash partition gpt_both0.bin` / `flash aboot aboot.mbn`
  Those destroy the vendor layout that backup/part-*.bin and rollback depend on.
  Use the builder only for debootstrap.sh/build_gt.sh/build_images.sh ideas, or accept
  a full reflash with EDL recovery proven first.
EOF

log "builder's own dependency list (host, needs sudo - yours to run)"
sed -n '5,30p' "$V/scripts/install_deps.sh" | sed 's/^/  /'
