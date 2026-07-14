set -euo pipefail

should_scan=true
echo "::notice::build-tools scan remains enabled on trusted refs so publish coverage includes the sha-* source image, for both the amd64 and arm64 matrix rows."
echo "should-scan=$should_scan" >> "$GITHUB_OUTPUT"

