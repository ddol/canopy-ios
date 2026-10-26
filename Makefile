# Shortcuts for the scripts in scripts/. `make` on its own lists them.

.PHONY: help version bump-version test lint bench serve testflight appstore
.DEFAULT_GOAL := help

# List the targets.
help:
	@awk '/^# /{c=substr($$0, 3); next} /^[a-z-]+:/{sub(/:.*/, ""); if (c) printf "  %-13s %s\n", $$0, c} {c=""}' Makefile

# Print the current version.
version:
	@sed -nE 's/^CANOPY_VERSION[[:space:]]*=[[:space:]]*//p' Configs/Version.xcconfig

# Move the version on by one: 0.1.0 → 0.1.1, 0.2.13 → 0.2.14, 0.1.1-pre2 → 0.1.1-pre3.
bump-version:
	@scripts/bump-version.sh

# Run every test (app, UI and packages) on the newest iPhone simulator.
test:
	@scripts/test.sh

# Check formatting as CI does.
lint:
	@swift format lint --strict --recursive --parallel App Packages Tests

# Measure loading real trees against the stand-in server; compare with BASE=report.json (docs/PERFORMANCE.md).
bench:
	@swift build -c release --package-path Packages/CanopyHarness --product canopy-harness
	@Packages/CanopyHarness/.build/release/canopy-harness bench --out bench.json $(if $(BASE),--compare $(BASE))

# Serve a synthetic park on port 50099 for the simulator (PROFILE=loopback|lan|cellular|poor).
serve:
	@swift build -c release --package-path Packages/CanopyHarness --product canopy-harness
	@Packages/CanopyHarness/.build/release/canopy-harness serve --port 50099 --profile $(or $(PROFILE),cellular)

# Upload a beta build, testing tools included, for TestFlight testers.
testflight:
	@scripts/testflight.sh

# Upload the build to submit for App Store review: no testing tools, from a clean commit on main.
appstore:
	@scripts/appstore.sh
