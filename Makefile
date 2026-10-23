# Shortcuts for the scripts in scripts/.

.PHONY: version bump-version

# Print the current version.
version:
	@sed -nE 's/^CANOPY_VERSION[[:space:]]*=[[:space:]]*//p' Configs/Version.xcconfig

# Move the version on by one: 0.1.0 → 0.1.1, 0.2.13 → 0.2.14, 0.1.1-pre2 → 0.1.1-pre3.
bump-version:
	@scripts/bump-version.sh
