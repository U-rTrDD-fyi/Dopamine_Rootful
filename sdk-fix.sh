#!/usr/bin/env bash

ZIP="$THEOS/sdks/iPhoneOS15.2.sdk.zip"
SDK_DIR="$THEOS/sdks/"
SDK="$THEOS/sdks/iPhoneOS15.2.sdk"

curl -L -o "ZIP" "https://github.com/xybp888/iOS-SDKs/releases/download/iOS-SDKs/iPhoneOS15.2.sdk.zip"

unzip -q "$ZIP" -d "$SDK_DIR"

find "$SDK" -type f -name "*.tbd" -exec sed -i '' -E 's/platform:[[:space:]]+\(null\)/platform: ios/g' {} +
