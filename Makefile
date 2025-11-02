KVERSION := $(shell uname -r)
KDIR := /lib/modules/${KVERSION}/build
MAKEFLAGS+="-j $(shell nproc)"

SIGN_KEY ?= fedora
SIGN_CERT ?= fedora
SIGN_HASH ?= sha256
SIGN_FILE ?= $(KDIR)/scripts/sign-file

SIGN_ENABLED := 0
ifneq ($(strip $(SIGN_KEY)),)
ifneq ($(strip $(SIGN_CERT)),)
SIGN_ENABLED := 1
endif
endif

default: clean
	$(MAKE) -C $(KDIR) M=$$PWD
	@if [ "$(SIGN_ENABLED)" = "1" ]; then \
		./scripts/sign-modules.sh "$$PWD" "$(SIGN_FILE)" "$(SIGN_HASH)" "$(SIGN_KEY)" "$(SIGN_CERT)"; \
	fi

debug: clean
	$(MAKE) -C $(KDIR) M=$$PWD ccflags-y="-Og -g3 -DDEBUG"
	@if [ "$(SIGN_ENABLED)" = "1" ]; then \
		./scripts/sign-modules.sh "$$PWD" "$(SIGN_FILE)" "$(SIGN_HASH)" "$(SIGN_KEY)" "$(SIGN_CERT)"; \
	fi

clean:
	$(MAKE) -C $(KDIR) M=$$PWD clean

unload:
	./modules_load.sh unload

load: unload
	./modules_load.sh

test:
	$(MAKE) debug &&\
		$(MAKE) load
	$(MAKE) clean

sign:
	@if [ "$(SIGN_ENABLED)" != "1" ]; then \
		echo "SIGN_KEY and SIGN_CERT must be provided (e.g. make sign SIGN_KEY=/path/key SIGN_CERT=/path/cert)" >&2; \
		exit 1; \
	fi
	./scripts/sign-modules.sh "$$PWD" "$(SIGN_FILE)" "$(SIGN_HASH)" "$(SIGN_KEY)" "$(SIGN_CERT)"

remove: clean
	./uninstall.sh

install: clean
	./install.sh
	./install/firmware.sh --skip-disclaimer

install-debug: clean
	./install.sh --debug
	./install/firmware.sh --skip-disclaimer
