#!/bin/bash

# Generate Version.swift from git tags
# This script should be run when preparing releases or during CI/CD

set -e

# Get the latest git tag, defaulting to "0.0.0" if no tags exist
VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0")

# Remove 'v' prefix if present
VERSION=${VERSION#v}

# Path to the Version.swift file
VERSION_FILE="Sources/ElevenLabs/Internal/Version.swift"

# Generate the Version.swift file
cat > "$VERSION_FILE" << EOF
// This file is auto-generated from git tags
// Run Scripts/generate-version.sh to update
import Foundation

enum SDKVersion {
    static let version = "$VERSION"
}
EOF

echo "Generated Version.swift with version: $VERSION"
