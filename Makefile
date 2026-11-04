SHELL := /bin/bash
SC := scripts

.PHONY: help check vendor fixup snapshot backup backup-full net plan upgrade-check rootfs bootimg-info flash-boot restore-verify

help:
	@echo "make check          host prerequisites (read-only)"
	@echo "make vendor         clone + pin kinsamanka/OpenStick-Builder into vendor/"
	@echo "make fixup          apply trixie/board deltas to the vendored builder"
	@echo "make snapshot       read-only dump of the stick into notes/"
	@echo "make backup         boot + firmware + calibration + modules + adbd  (device read-only)"
	@echo "make backup-full    the above plus the raw 3.3 GiB rootfs image (COMMIT=1)"
	@echo "make net            give the stick internet over the gadget link"
	@echo "make upgrade-check  route A preflight only"
	@echo "make rootfs         route B: build trixie rootfs image (needs arm64 binfmt, COMMIT=1)"
	@echo "make bootimg-info   decode backup/boot-stock.bin"
	@echo "make restore-verify check backup integrity"

check:        ; $(SC)/00-host-check.sh
vendor:       ; $(SC)/05-fetch-vendor.sh
fixup:        ; $(SC)/06-vendor-fixup.sh
snapshot:     ; $(SC)/10-snapshot.sh
backup:       ; $(SC)/20-backup.sh
backup-full:  ; COMMIT=1 $(SC)/20-backup.sh --rootfs
net:          ; $(SC)/30-net-up.sh
upgrade-check:; $(SC)/40-inplace-upgrade.sh
rootfs:       ; $(SC)/50-build-rootfs.sh
bootimg-info: ; $(SC)/60-build-bootimg.sh info
restore-verify:; $(SC)/90-restore.sh verify
