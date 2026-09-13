CC      ?= clang
CFLAGS  ?= -O2 -Wall
LDFLAGS := -framework IOKit -framework CoreFoundation

SRC      := src
RESEARCH := research

.PHONY: all daemon tools research install verify uninstall status clean test unit e2e

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

install: all
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

uninstall:
	sudo bash install/uninstall.sh

status:
	@cat /var/run/fanpilot.status.json 2>/dev/null || echo "守护未运行"

clean:
	rm -f tests/unit_logic $(SRC)/fanpilotd $(SRC)/fanctl \
	      $(RESEARCH)/smcprobe $(RESEARCH)/sensors $(RESEARCH)/sample \
	      $(RESEARCH)/bench $(RESEARCH)/tf
