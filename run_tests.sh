#!/usr/bin/env bash

TOKEN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)
      TOKEN="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$TOKEN" ]]; then
  echo "Error: --token is required to run integration tests."
  echo "Provide an API token from a VoIPGRID user account."
  echo "The account must have more than 5 rooms for the tests to work."
  echo ""
  echo "  ./run_tests.sh --token <your_token>"
  exit 1
fi

dart pub global activate junitreport
export PATH="$PATH:$HOME/.pub-cache/bin"

ACCESS_TOKEN="$TOKEN" \
  dart test test/tests.dart --reporter json | \
  tojunit | \
  sed 's/&#x1[Bb];\[[0-9;]*[a-zA-Z]//g; s/&#x1[Bb];//g' > test-results.xml

exit "${PIPESTATUS[0]}"
