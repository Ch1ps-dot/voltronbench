#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  cat <<'EOF'
Usage: $0 <replacement>

Searches under "benchmark/subjects" for Dockerfile files and replaces every
occurrence of "github.com" with the provided replacement string.

Example:
  $0 github.example.com

EOF
  exit 1
fi

replacement="$1"

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
subjects_dir="$root_dir/benchmark/subjects"

if [[ ! -d "$subjects_dir" ]]; then
  echo "ERROR: subjects directory not found: $subjects_dir" >&2
  exit 2
fi

# Find Dockerfiles and perform in-place replacement.
# Use a temporary file to avoid sed incompatibilities across platforms.
changed=0
while IFS= read -r -d '' dockerfile; do
  if grep -q "github\.com" "$dockerfile"; then
    echo "Updating $dockerfile"
    # Use perl for in-place editing with no backup (portable and safe)
    perl -pi -e 's{github\.com}{'"$replacement"'}g' "$dockerfile"
    changed=1
  fi
done < <(find "$subjects_dir" -type f -name Dockerfile -print0)

if [[ $changed -eq 0 ]]; then
  echo "No occurrences of 'github.com' were found in Dockerfiles under $subjects_dir."
fi
