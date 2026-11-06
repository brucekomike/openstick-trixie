SHELL := /bin/bash
SC := scripts

.PHONY: help check vendor fixup snapshot backup backup-full net plan upgrade-check rootfs alpine alpine-minimal alpine-full alpine-cross alpine-cross-minimal alpine-cross-full alpine-patch adbd-payload flashpack flashpack-build flashpack-tar bootimg-info extlinux mainline-boot enter-fastboot bootchain-status edl bootchain bootchain-restore restore-verify test

test:
	python3 -m unittest discover -s tests -v
	@for f in scripts/*.sh scripts/device/*.sh config/usb-adb-gadget.sh config/alpine-gadget/*.sh config/flashpack/*.sh; do bash -n "$$f" || exit 1; done
	@echo "all scripts parse"

help:
	@echo "make test           boot.img round-trip tests + shell syntax check"
	@echo "make check          host prerequisites (read-only)"
	@echo "make vendor         clone + pin kinsamanka/OpenStick-Builder into vendor/"
	@echo "make fixup          apply trixie/board deltas to the vendored builder"
	@echo "make snapshot       read-only dump of the stick into notes/"
	@echo "make backup         boot + firmware + calibration + modules + adbd  (device read-only)"
	@echo "make backup-full    the above plus the raw 3.3 GiB rootfs image (COMMIT=1)"
	@echo "make net            give the stick internet over the gadget link"
	@echo "make upgrade-check  route A preflight only"
	@echo "make rootfs         route B: build trixie rootfs image (needs arm64 binfmt, COMMIT=1)"
	@echo "make alpine         route D: build Alpine on the stick, pull boot+rootfs images (COMMIT=1)"
	@echo "make alpine-minimal route D on the stick, minimal toolset (editor + ssh client)"
	@echo "make alpine-full    route D on the stick, full toolset (+ network tools)"
	@echo "make alpine-cross   route D on the HOST: cross-build this board's rootfs in a container"
	@echo "make alpine-cross-minimal / -full  the same cross build, by toolset (COMMIT=1)"
	@echo "                   (offline stick; COMMIT=1 to actually run the build)"
	@echo "make alpine-patch   patch a built Alpine image (gadget + ACM console + adb) before flashing"
	@echo "make adbd-payload   assemble+verify the adbd payload alpine-patch injects (read-only)"
	@echo "make flashpack      assemble a self-contained install pack from out/ (writes no board)"
	@echo "make flashpack-build same, but rebuild the images on the stick first (needs it online)"
	@echo "make flashpack-tar  flashpack-build + a .tar.zst for moving to the flashing host"
	@echo "make mainline-boot  build the ext2+extlinux boot image for a mainline kernel"
	@echo "make enter-fastboot get into fastboot from a running system, no hands (reboot RESTART2)"
	@echo "make edl            EDL door: programmer + this board's GPT, read-only (78-)"
	@echo "make bootchain-status  what bootloader files exist, and what the stick is doing"
	@echo "make bootchain      flash community aboot+hyp, then the mainline boot image (COMMIT=1)"
	@echo "make bootchain-restore every boot-chain partition back to backup/ (COMMIT=1)"
	@echo "make bootimg-info   decode backup/boot-stock.bin"
	@echo "make restore-verify check backup integrity"
	@echo ""
	@echo "Two boards are supported: BOARD-ufi103s.md and BOARD-ufi001c.md are the board files."
	@echo "BOARD_ENV=config/board-<board>.env selects the target (default: ufi103s); each board"
	@echo "also has its own backup tree, so pass BACKUP= with it - see the board files."
	@echo "The factory aboot cannot boot a mainline kernel, so 'make extlinux' alone is not"
	@echo "enough - see 'make bootchain', or 'make edl' when nothing boots."

check:        ; $(SC)/00-host-check.sh
vendor:       ; $(SC)/05-fetch-vendor.sh
fixup:        ; $(SC)/06-vendor-fixup.sh
snapshot:     ; $(SC)/10-snapshot.sh
backup:       ; $(SC)/20-backup.sh
backup-full:  ; COMMIT=1 $(SC)/20-backup.sh --rootfs
net:          ; $(SC)/30-net-up.sh
upgrade-check:; $(SC)/40-inplace-upgrade.sh
rootfs:       ; $(SC)/50-build-rootfs.sh
alpine:       ; COMMIT=1 $(SC)/54-build-alpine-onstick.sh
# Two toolsets on the same base: minimal = editor + ssh client (the default), full = the same
# image plus the network tools. 55 and 80 gate the built image against the same TOOLSET word,
# so a pack cannot ship a toolset that contradicts the README table. The repo's own version is
# in VERSION and goes into every pack name; it is not the toolset name.
alpine-minimal:   ; COMMIT=1 TOOLSET=minimal $(SC)/54-build-alpine-onstick.sh
alpine-full:  ; COMMIT=1 TOOLSET=full $(SC)/54-build-alpine-onstick.sh
alpine-cross: ; $(SC)/53-build-alpine-cross.sh
alpine-cross-minimal:  ; COMMIT=1 TOOLSET=minimal $(SC)/53-build-alpine-cross.sh
alpine-cross-full: ; COMMIT=1 TOOLSET=full $(SC)/53-build-alpine-cross.sh
alpine-patch: ; $(SC)/55-patch-alpine-image.sh
edl:          ; $(SC)/78-flash-over-edl.sh status
adbd-payload: ; $(SC)/76-fetch-adbd-payload.sh
flashpack:    ; $(SC)/80-build-flashpack.sh
flashpack-build:; $(SC)/80-build-flashpack.sh --build
flashpack-tar:; $(SC)/80-build-flashpack.sh --build --tar
bootimg-info: ; $(SC)/60-build-bootimg.sh info
extlinux:     ; $(SC)/66-make-extlinux-boot.sh
mainline-boot:; $(SC)/68-make-mainline-boot.sh
enter-fastboot:; $(SC)/72-enter-fastboot.sh
bootchain-status:; $(SC)/74-flash-mainline-bootchain.sh status
bootchain:    ; COMMIT=1 $(SC)/74-flash-mainline-bootchain.sh all
bootchain-restore:; COMMIT=1 $(SC)/74-flash-mainline-bootchain.sh restore
restore-verify:; $(SC)/90-restore.sh verify
