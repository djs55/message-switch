.PHONY: all clean install build
all: build doc

NAME=xenstore
J=4

export OCAMLRUNPARAM=b

TESTS ?= --enable-tests
ifneq "$(MIRAGE_OS)" ""
TESTS := --disable-tests
endif

clean:
	@rm -f setup.data setup.log setup.bin
	@rm -rf _build

distclean: clean
	@rm -f config.mk

-include config.mk

config.mk: configure
	./configure

configure: configure.ml
	ocamlfind ocamlc -linkpkg -package findlib,cmdliner -o configure configure.ml
	@rm -f configure.cm*

setup.bin: setup.ml
	@ocamlopt.opt -o $@ $< || ocamlopt -o $@ $< || ocamlc -o $@ $<
	@rm -f setup.cmx setup.cmi setup.o setup.cmo

setup.data: setup.bin
	@./setup.bin -configure $(TESTS)

build: setup.data setup.bin
	@./setup.bin -build -j $(J)

doc: setup.data setup.bin
	@./setup.bin -doc -j $(J)

OCAML := $(shell ocamlc -where)
PYTHON := $(OCAML)/../python

install: setup.bin
	@./setup.bin -install
	install -D _build/cli/main.native $(DESTDIR)/$(BINDIR)/ms
	install -D _build/switch/switch_main.native $(DESTDIR)/$(BINDIR)/message-switch

# oasis bug?
#test: setup.bin build
#	@./setup.bin -test
test:
	_build/core_test/xs_test.native
	_build/server_test/server_test.native


reinstall: setup.bin
	@ocamlfind remove $(NAME) || true
	@cp -f core/message_switch.py $(PYTHON)/
	@./setup.bin -reinstall

