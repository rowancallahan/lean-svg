PYTHON ?= python3
LAKE ?= lake

.PHONY: all build test adversarial tiles full-check clean

all: test adversarial

build:
	$(LAKE) build

test: build
	$(PYTHON) tests/run_tests.py

adversarial: build
	$(PYTHON) tests/run_adversarial.py

tiles: build
	$(PYTHON) tests/run_tiles.py

full-check:
	bash scripts/full-check.sh

clean:
	rm -rf tests/out
