CC      ?= clang
CFLAGS  ?= -O2 -Wall
LDFLAGS := -framework IOKit -framework CoreFoundation

SRC      := src
RESEARCH := research

.PHONY: all daemon tools research install verify uninstall status clean test unit e2e app dist precheck

all: daemon tools

daemon: $(SRC)/fanpilotd
tools:  $(SRC)/fanctl

$(SRC)/fanpilotd: $(SRC)/fanpilotd.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

$(SRC)/fanctl: $(SRC)/fanctl.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

# 只读调研工具（不写任何 SMC 键）
research: $(RESEARCH)/smcprobe $(RESEARCH)/sensors $(RESEARCH)/sample $(RESEARCH)/bench
$(RESEARCH)/%: $(RESEARCH)/%.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

precheck: tools
	@bash install/precheck.sh

install: all precheck
	sudo bash install/install.sh

verify:
	sudo bash install/verify.sh

# ⭐ 全量测试：单元 → 验收 → E2E/回归。任一失败即整体失败。
test: unit verify e2e
	@echo ""
	@echo "═══ 全量测试通过 ═══"

unit: tests/unit_logic
	@./tests/unit_logic | tail -5

tests/unit_logic: tests/unit_logic.c src/fanlogic.h
	$(CC) -O0 -g -Wall -Wextra -o $@ $<

e2e:
	sudo bash tests/e2e.sh

app:
	cd app && swift build -c release && ./bundle.sh

# 发布包：布局与仓库一致，所以 install/*.sh 无需任何改动即可在解压目录里跑
VERSION := $(shell cat VERSION)
DIST    := dist/FanPilot-$(VERSION)
dist: all app
	rm -rf $(DIST) dist/FanPilot-$(VERSION).tar.gz
	mkdir -p $(DIST)/src $(DIST)/install $(DIST)/app
	cp src/fanpilotd src/fanctl            $(DIST)/src/
	cp install/*.sh install/*.plist        $(DIST)/install/
	cp -R app/FanPilot.app                 $(DIST)/app/
	cp README.md CHANGELOG.md LICENSE VERSION $(DIST)/
	cp dist/install.sh                     $(DIST)/install.sh
	chmod +x $(DIST)/install.sh $(DIST)/install/*.sh
	cd dist && tar --no-xattrs -czf FanPilot-$(VERSION).tar.gz FanPilot-$(VERSION)
	@rm -rf $(DIST)
	@echo ""
	@shasum -a 256 dist/FanPilot-$(VERSION).tar.gz
	@ls -lh dist/FanPilot-$(VERSION).tar.gz

uninstall:
	sudo bash install/uninstall.sh

status:
	@cat /var/run/fanpilot.status.json 2>/dev/null || echo "守护未运行"

clean:
	rm -f tests/unit_logic $(SRC)/fanpilotd $(SRC)/fanctl \
	      $(RESEARCH)/smcprobe $(RESEARCH)/sensors $(RESEARCH)/sample \
	      $(RESEARCH)/bench $(RESEARCH)/tf
