PYTHON ?= python3
LAKE ?= lake

.PHONY: all build test adversarial clean

all: test adversarial

build:
	$(LAKE) build

test: build
	$(PYTHON) tests/run_tests.py

adversarial: build
	$(PYTHON) tests/run_adversarial.py

clean:
	rm -rf tests/out
