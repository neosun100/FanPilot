CC      ?= clang
CFLAGS  ?= -O2 -Wall
LDFLAGS := -framework IOKit -framework CoreFoundation

SRC      := src
RESEARCH := research

.PHONY: all daemon tools research install verify uninstall status clean

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

uninstall:
	sudo bash install/uninstall.sh

status:
	@cat /var/run/fanpilot.status.json 2>/dev/null || echo "守护未运行"

clean:
	rm -f $(SRC)/fanpilotd $(SRC)/fanctl \
	      $(RESEARCH)/smcprobe $(RESEARCH)/sensors $(RESEARCH)/sample \
	      $(RESEARCH)/bench $(RESEARCH)/tf
