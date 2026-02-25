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

ACCESS_TOKEN="$TOKEN" \
  dart test test/tests.dart
