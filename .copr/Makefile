.PHONY: srpm clean

outdir ?= $(CURDIR)
spec ?= szn.spec
VERSION ?= $(shell grep -m1 'version' build.zig.zon | sed -E 's/.*"([^"]+)".*/\1/')
NAME ?= szn

srpm:
	mkdir -p $(outdir)
	TMP_DIR=$$(mktemp -d /tmp/szn-srpm.XXXXXX); \
	tar --exclude='.git' \
	    --exclude='.hg' \
	    --exclude='.zig-cache' \
	    --exclude='zig-out' \
	    --exclude='dist' \
	    --transform 's,^\.,$(NAME)-$(VERSION),' \
	    -czf "$$TMP_DIR/$(NAME)-$(VERSION).tar.gz" . && \
	rpmbuild -bs \
	    --define "_sourcedir $$TMP_DIR" \
	    --define "_srcrpmdir $(outdir)" \
	    $(spec) && \
	rm -rf "$$TMP_DIR"

clean:
	rm -rf dist
