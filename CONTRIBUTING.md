# Contributing

Thank you for your help with the DATALYR iOS SDK.

## Run the checks

CI runs these checks on every pull request. You need macOS and Xcode.

1. Run the build check:

   ```bash
   ./scripts/validate.sh
   ```

2. Run the unit tests on an iOS Simulator:

   ```bash
   xcodebuild test -scheme DatalyrSDK -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation
   ```

   Replace `iPhone 16` with a simulator that is installed on your Mac.

## Pull requests

- Open an issue first for a large change.
- Keep each pull request to one change.
- Add or update tests for the change.
- Add an entry to CHANGELOG.md if users can see the change.
- Do not include secrets, API keys or personal data.
