SHELL := /bin/bash
SC := scripts

.PHONY: help check vendor fixup snapshot backup backup-full net plan upgrade-check rootfs alpine alpine-patch bootimg-info extlinux mainline-boot enter-fastboot bootchain-status bootchain bootchain-restore restore-verify test

test:
	python3 -m unittest discover -s tests -v
	@for f in scripts/*.sh config/usb-adb-gadget.sh; do bash -n "$$f" || exit 1; done
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
	@echo "make alpine-patch   patch a built Alpine image (gadget bring-up + ACM console) before flashing"
	@echo "make mainline-boot  build the ext2+extlinux boot image for a mainline kernel"
	@echo "make enter-fastboot get into fastboot from a running system, no hands (reboot RESTART2)"
	@echo "make bootchain-status  what bootloader files exist, and what the stick is doing"
	@echo "make bootchain      flash community aboot+hyp, then the mainline boot image (COMMIT=1)"
	@echo "make bootchain-restore every boot-chain partition back to backup/ (COMMIT=1)"
	@echo "make bootimg-info   decode backup/boot-stock.bin"
	@echo "make restore-verify check backup integrity"
	@echo ""
	@echo "BOARD-ufi001c.md is the board file; the factory aboot cannot boot a mainline kernel,"
	@echo "so 'make extlinux' alone is not enough - see 'make bootchain'."

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
alpine-patch: ; $(SC)/55-patch-alpine-image.sh
bootimg-info: ; $(SC)/60-build-bootimg.sh info
extlinux:     ; $(SC)/66-make-extlinux-boot.sh
mainline-boot:; $(SC)/68-make-mainline-boot.sh
enter-fastboot:; $(SC)/72-enter-fastboot.sh
bootchain-status:; $(SC)/74-flash-mainline-bootchain.sh status
bootchain:    ; COMMIT=1 $(SC)/74-flash-mainline-bootchain.sh all
bootchain-restore:; COMMIT=1 $(SC)/74-flash-mainline-bootchain.sh restore
restore-verify:; $(SC)/90-restore.sh verify
