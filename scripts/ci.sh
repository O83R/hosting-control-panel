#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "=== HCP CI ==="
echo "root=$ROOT"

test -f go.mod
test -f main.go
test -f compose.yml
test -f Dockerfile

mapfile -d '' GO_FILES < <(find . -type f -name '*.go' -not -path './vendor/*' -print0)
if (("${#GO_FILES[@]}" == 0)); then
  echo "STOP: no Go files found" >&2
  exit 1
fi

echo
echo "=== GOFMT ==="
BAD_FMT="$(gofmt -l "${GO_FILES[@]}")"
if [[ -n "$BAD_FMT" ]]; then
  printf 'STOP: gofmt required:\n%s\n' "$BAD_FMT" >&2
  exit 1
fi
echo "GOFMT: PASS"

echo
echo "=== GO VET ==="
go vet ./...
echo "GO VET: PASS"

echo
echo "=== GO TEST ==="
go test ./...
echo "GO TEST: PASS"

echo
echo "=== GO BUILD ==="
rm -rf .ci-out
mkdir -p .ci-out
CGO_ENABLED=0 go build -trimpath -o .ci-out/panel .
test -s .ci-out/panel
echo "GO BUILD: PASS"

echo
echo "=== SOURCE SAFETY CONTRACT ==="
grep -Fq '127.0.0.1:18100:8080' compose.yml
grep -Fq 'read_only: true' compose.yml
grep -Fq 'no-new-privileges:true' compose.yml
grep -Fq 'cap_drop: [ALL]' compose.yml
if grep -Fq 'docker.sock' compose.yml; then
  echo "STOP: Docker socket mount/reference is forbidden in panel compose" >&2
  exit 1
fi
grep -Fq 'No production restore' web/index.html
echo "SOURCE SAFETY CONTRACT: PASS"

echo
echo "HCP CI: PASS"
