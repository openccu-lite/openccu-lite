# openccu-lite (D-44, D-88): a lite product's version is LITE-VERSION's, not upstream's build date.
# The Makefile includes this after its own PRODUCT_VERSION line; it sets PRODUCT_VERSION from
# LITE_VERSION and exports LITE_BASE/LITE_VERSION for board/lite/version-file.sh. A prerelease is
# built as LITE_VERSION=<VERSION>.<N>, a release with LITE-VERSION's VERSION as it is:
#   make PRODUCT=... LITE_VERSION=2.0.0 release
# LITE_PRODUCTS decides which products are lite ones: add a new lite product here when it is added
# to configs/, or it silently gets upstream's date-based version.
LITE_BASE:=$(shell sed -n 's/^BASE=//p' LITE-VERSION)
LITE_VERSION?=$(shell sed -n 's/^VERSION=//p' LITE-VERSION)
LITE_PRODUCTS:=x86_64-ova aarch64-rpi3 aarch64-rpi4 aarch64-rpi5 lxc-lite_amd64 lxc-lite_arm64
ifneq ($(findstring -lite,$(PRODUCT))$(filter $(PRODUCT),$(LITE_PRODUCTS)),)
ifneq ($(LITE_VERSION),)
PRODUCT_VERSION:=$(LITE_VERSION)
export LITE_BASE LITE_VERSION
endif
endif
