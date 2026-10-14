EMACS ?= emacs
BATCH = $(EMACS) -Q --batch -L .

.PHONY: all compile checkdoc test clean

all: compile checkdoc test

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile mdr-preview.el

checkdoc:
	$(BATCH) --eval '(checkdoc-file "mdr-preview.el")'

test:
	$(BATCH) -L test -l test/mdr-preview-test.el -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc test/*.elc
