PYTHON ?= python3
REPORT ?= artifacts/ci/m1-008-report.json

.PHONY: verify backlog-check ci-gate-tests code-quality-check architecture-check docs-check e2e

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

# ISSUE is passed unexpanded as one single-quoted argv value; run_e2e.py validates it.
unexport ISSUE
e2e:
	$(PYTHON) Tools/Evidence/run_e2e.py --issue '$(subst ','\'',$(value ISSUE))'
