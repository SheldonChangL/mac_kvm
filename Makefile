PYTHON ?= python3
REPORT ?= artifacts/ci/m1-008-report.json

.PHONY: verify backlog-check ci-gate-tests code-quality-check architecture-check docs-check

verify:
	$(PYTHON) Tools/cigates/cigates.py --repository-root . --report "$(REPORT)"

backlog-check:
	$(PYTHON) Tools/Backlog/validate_package.py

ci-gate-tests:
	$(PYTHON) -m unittest discover -s Tools/cigates/tests -p 'test_*.py' -v

code-quality-check:
	$(PYTHON) Tools/code-quality/code-quality.py --repository-root .

architecture-check:
	$(PYTHON) Tools/architecture-check/architecture-check.py --repository-root .

docs-check:
	$(PYTHON) Tools/docs-check/docs-check.py --repository-root .
