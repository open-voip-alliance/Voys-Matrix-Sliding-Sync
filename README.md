# voys_matrix_sliding_sync

A thin Dart wrapper around the [matrix](https://pub.dev/packages/matrix) SDK that adds [Sliding Sync (MSC4186)](https://github.com/matrix-org/matrix-spec-proposals/pull/4186) support.

## Running Tests

The tests are integration tests that connect to a real Matrix server and require a valid access token.

**Prerequisites**: The account must have more than 5 rooms for the tests to pass.

```bash
./run_tests.sh --token <your_access_token>
```

The token should be an API token from a VoIPGRID user account.
