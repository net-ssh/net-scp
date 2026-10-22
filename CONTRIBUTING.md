# Contributing to net-scp

Run the tests with `bundle exec rake test`.

## Changelog

Don't edit `CHANGES.txt`. Instead, add a fragment file to `changelog.d/` in your PR; the release's version bump (`rake vbump:*`) moves all fragments into a new `=== <version>` section at the top of `CHANGES.txt` and deletes them.

A fragment is named `<number>.<type>.txt`, where `<number>` is the PR number (so open the PR first, then add the fragment), and contains a single UTF-8 paragraph: the entry as it should read in `CHANGES.txt`, without the bullet or prefix. Lines are joined, so it can be wrapped. If it doesn't end with a reference list such as `[#95, #101]` or `[GHSA-xxxx-xxxx-xxxx]`, ` [#<number>]` is appended.

| Type                | Written as                     | Use for                                                      |
| ------------------- | ------------------------------ | ------------------------------------------------------------ |
| `breaking-security` | `* BREAKING: Security: <text>` | an incompatible change made for security                     |
| `breaking`          | `* BREAKING: <text>`           | an incompatible change                                       |
| `security`          | `* Security: <text>`           | a security fix or hardening                                  |
| `change`            | `* <text>`                     | any other user-visible fix or feature                        |
| `none`              | nothing                        | PRs with no user-visible change (tests, CI, docs, refactors) |

Examples:

```sh
rake "changelog:new[102,change,Fixed uploading files with spaces in their names]"
# changelog.d/102.change.txt -> * Fixed uploading files with spaces in their names [#102]

echo 'Refuse downloads that write outside the target directory [GHSA-xxxx-xxxx-xxxx]' > changelog.d/103.security.txt
touch changelog.d/104.none.txt
```

For several entries from one PR add a suffix: `102.change.txt`, `102.change.2.txt` (`changelog:new` picks the next free one).

`rake changelog:check` validates the fragments and `rake changelog:preview` prints the section the next release would add. CI fails a PR that edits `CHANGES.txt` or doesn't add or modify a `changelog.d/<PR number>.<type>.txt` fragment, unless it only touches `changelog.d/` or a maintainer adds the `skip-changelog` label; Dependabot PRs are skipped.

The full rules, including how a release orders the entries, are in the [changelogd README](https://github.com/net-ssh/changelogd#readme).
