PYTHON ?= python3
LAKE ?= lake

.PHONY: all build test adversarial tiles clean

all: test adversarial

build:
	$(LAKE) build

test: build
	$(PYTHON) tests/run_tests.py

adversarial: build
	$(PYTHON) tests/run_adversarial.py

tiles: build
	$(PYTHON) tests/run_tiles.py

clean:
	rm -rf tests/out
