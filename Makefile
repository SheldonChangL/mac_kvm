PYTHON ?= python3
REPORT ?= artifacts/ci/m1-008-report.json

.PHONY: verify backlog-check ci-gate-tests

verify:
	$(PYTHON) Tools/cigates/cigates.py --repository-root . --report "$(REPORT)"

backlog-check:
	$(PYTHON) Tools/Backlog/validate_package.py

ci-gate-tests:
	$(PYTHON) -m unittest discover -s Tools/cigates/tests -p 'test_*.py' -v
