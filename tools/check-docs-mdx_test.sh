#!/usr/bin/env bash
# Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES.  All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Unit harness for tools/check-docs-mdx check 6 — the fail-closed allowlist
# rule for a bare '<' not followed by a valid JSX name-start.
# Run directly: bash tools/check-docs-mdx_test.sh
# Wired into CI via `make test` (test-shell target, runs tools/*_test.sh).
#
# Hermetic: builds fixture .md files in a temp dir and runs the checker against
# them, so no docs/ content is read and nothing on disk is mutated. The
# fixtures pin the regression from issue #2050 (Fern's MDX parser rejects
# '(gate <= 2,000)' with "Unexpected character = (U+003D) before name", which
# the denylist-era checker reported as OK) and guard against false positives
# when the same token is safely wrapped in inline or fenced code.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${SCRIPT_DIR}/check-docs-mdx"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 — $2"; fails=$((fails + 1)); }

# run <dir>: capture combined stdout+stderr into $OUT and exit code into $RC.
OUT=""
RC=0
run() {
    OUT="$("${CHECK}" "$1" 2>&1)"
    RC=$?
}

check_rc_nonzero() { # <name>
    if [[ "${RC}" != "0" ]]; then pass "$1"; else fail "$1" "want nonzero rc, got 0"; fi
}
check_rc_zero() { # <name>
    if [[ "${RC}" == "0" ]]; then pass "$1"; else fail "$1" "want rc=0, got ${RC}"; fi
}
check_contains() { # <name> <needle>
    if [[ "${OUT}" == *"$2"* ]]; then pass "$1"; else fail "$1" "expected to contain: $2"; fi
}
check_absent() { # <name> <needle>
    if [[ "${OUT}" != *"$2"* ]]; then pass "$1"; else fail "$1" "expected NOT to contain: $2"; fi
}

# --- Fixture 0: the script must parse. ---
# The awk programs live inside single-quoted bash strings, so one apostrophe in
# a comment ("Fern's") silently terminates the quote and turns the rest of the
# program into shell tokens. `bash -n` catches that before any behavioral
# assertion has to.
if bash -n "${CHECK}" 2>/dev/null; then
    pass "script-parses"
else
    fail "script-parses" "bash -n reported a syntax error (an apostrophe inside the awk block?)"
fi

# --- Fixture 1: the #2050 regression — a bare '<= ' outside any code span. ---
# The checker MUST fail closed here. If check 6 is removed, this token is not
# a void element (check 1), autolink (check 4), or <name-start> tag (check 5),
# so nothing else flags it and this assertion fails — proving the rule is what
# catches it.
DIR_HAZARD="${TMPDIR_TEST}/hazard"
mkdir -p "${DIR_HAZARD}"
cat >"${DIR_HAZARD}/bare-lt.md" <<'MD'
# Bare less-than-or-equal hazard

The TTFT p99 stays low (gate <= 2,000) under the calibrated inference gate.
MD

run "${DIR_HAZARD}"
check_rc_nonzero "bare-lt-exits-nonzero"
check_contains   "bare-lt-reported" "MDX: bare < not starting a valid tag"
check_contains   "bare-lt-line-cited" "bare-lt.md:3:"

# --- Fixture 2: the SAME token, but safely wrapped. No false positive. ---
# Inline backtick span and fenced code block both hide the '<=' from every
# check, so a clean fixture built only from wrapped hazards must pass.
DIR_SAFE="${TMPDIR_TEST}/safe"
mkdir -p "${DIR_SAFE}"
cat >"${DIR_SAFE}/wrapped-lt.md" <<'MD'
# Wrapped less-than-or-equal is safe

The TTFT p99 stays low (gate `<= 2,000`) under the calibrated inference gate.

```text
inference-perf TTFT p99 gate <= 2,000 ms
```

A valid element like <br /> stays clean.
MD

run "${DIR_SAFE}"
check_rc_zero  "wrapped-lt-exits-zero"
check_absent   "wrapped-lt-no-violation" "bare < not starting a valid tag"

# --- Fixture 2b: '<' followed by WHITESPACE. Must NOT be reported. ---
# Verified against @mdx-js/mdx: micromark only enters JSX-tag mode when a
# name-ish character follows '<' immediately, so '< 500' and friends stay
# literal text and parse cleanly. This checker is a strict subset of the real
# parser, so reporting them here would be a false positive — it would force
# contributors to backtick prose that `fern generate --docs` accepts.
DIR_WS="${TMPDIR_TEST}/whitespace"
mkdir -p "${DIR_WS}"
cat >"${DIR_WS}/lt-space.md" <<'MD'
# Less-than followed by whitespace is literal text

Embed the cause only when status < 500, since 4xx carries client feedback.

Recipes targeting Kubernetes < 1.15 must enable the feature gate explicitly.

Guards fire before any cluster mutation, so skips are cheap (typically < 10 s).
MD

run "${DIR_WS}"
check_rc_zero "lt-space-exits-zero"
check_absent  "lt-space-no-violation" "bare < not starting a valid tag"
check_absent  "lt-space-no-word-tag"  "bare <word> tag"

# --- Fixture 2d: well-formed JSX must NOT be reported. ---
# MDX accepts self-closing components and balanced elements, and Fern's own
# component set (Cards, Tabs, Accordions) is authored that way. Check 5 used to
# flag every '<' followed by a letter, so it rejected all of these. A line
# showing evidence of well-formed JSX ('/>' or '</') is now left to the parse
# gate, which can actually tell whether the tags balance.
DIR_JSX="${TMPDIR_TEST}/jsx"
mkdir -p "${DIR_JSX}"
cat >"${DIR_JSX}/valid-jsx.md" <<'MD'
# Well-formed JSX is valid MDX

A <span>styled</span> word renders fine.

A self-closing <Component /> renders fine.

So does <Foo bar="baz" /> with attributes.

And a void element like <br /> stays clean.
MD

run "${DIR_JSX}"
check_rc_zero "valid-jsx-exits-zero"
check_absent  "valid-jsx-no-word-tag"  "bare <word> tag"
check_absent  "valid-jsx-no-void"      "non-self-closing void element"
check_absent  "valid-jsx-no-bare-lt"   "bare < not starting a valid tag"

# --- Fixture 2e: an unbalanced placeholder is still caught. ---
# Narrowing check 5 must not blind it to the case it exists for: a bare
# '<word>' placeholder on a line with no JSX evidence.
DIR_PLACEHOLDER="${TMPDIR_TEST}/placeholder"
mkdir -p "${DIR_PLACEHOLDER}"
cat >"${DIR_PLACEHOLDER}/placeholder.md" <<'MD'
# Bare placeholder

Pass <name> to select the component you want to bundle.
MD

run "${DIR_PLACEHOLDER}"
check_rc_nonzero "placeholder-exits-nonzero"
check_contains   "placeholder-reported" "MDX: bare <word> tag outside code fence"

# --- Fixture 2f: YAML frontmatter is not scanned; content after it still is. ---
# Fern strips frontmatter before MDX, so '<=' in a title is valid. Skipping it
# by line number (rather than rewriting the file) keeps later diagnostics
# pointing at the true line.
DIR_FM="${TMPDIR_TEST}/frontmatter"
mkdir -p "${DIR_FM}"
cat >"${DIR_FM}/fm-safe.md" <<'MD'
---
title: Latency gate <= 2,000 ms
description: TTFT p99 under <= 2,000 ms
---

# Page

Body text with a wrapped `<= 2,000` gate.
MD
cat >"${DIR_FM}/fm-hazard.md" <<'MD'
---
title: Safe here <= 1
---

# Page

Body hazard gate <= 5 sits on line 7.
MD

run "${DIR_FM}"
check_rc_nonzero "frontmatter-hazard-exits-nonzero"
check_absent     "frontmatter-title-not-flagged" "fm-safe.md"
check_contains   "frontmatter-hazard-true-line"  "fm-hazard.md:7:"

# --- Fixture 2c: '<30' must produce exactly ONE diagnostic, not two. ---
# Check 5 owns letter-prefixed names and check 6 owns everything that cannot
# start a name, so a digit-prefixed sequence belongs to check 6 alone. When
# check 5 also matched digits, one source token emitted two lines and
# double-incremented the error count.
DIR_DIGIT="${TMPDIR_TEST}/digit"
mkdir -p "${DIR_DIGIT}"
cat >"${DIR_DIGIT}/digit-tag.md" <<'MD'
# Digit-prefixed angle bracket

Cold start completes in <30 s on a warm cache.
MD

run "${DIR_DIGIT}"
check_rc_nonzero "digit-tag-exits-nonzero"
check_contains   "digit-tag-reported" "MDX: bare < not starting a valid tag"
check_absent     "digit-tag-not-double-reported" "MDX: bare <word> tag"
if [[ "$(grep -c 'digit-tag.md:3:' <<<"${OUT}")" == "1" ]]; then
    pass "digit-tag-single-diagnostic"
else
    fail "digit-tag-single-diagnostic" "want exactly 1 diagnostic for line 3, got $(grep -c 'digit-tag.md:3:' <<<"${OUT}")"
fi

# --- Fixture 3: '<= ' inside a tilde (~~~) fenced code block. No false pos. ---
# CommonMark honors ~~~ fences as code; the checker must skip their contents
# just like ``` fences, so the hazard token stays hidden.
DIR_TILDE="${TMPDIR_TEST}/tilde"
mkdir -p "${DIR_TILDE}"
cat >"${DIR_TILDE}/tilde-fence.md" <<'MD'
# Tilde fence hides the hazard

~~~
inference-perf TTFT p99 gate <= 2,000 ms
~~~
MD

run "${DIR_TILDE}"
check_rc_zero  "tilde-fence-exits-zero"
check_absent   "tilde-fence-no-violation" "bare < not starting a valid tag"

# --- Fixture 4: '<= ' inside a double-backtick (``…``) span. No false pos. ---
# CommonMark closes an N-backtick span at the next run of exactly N backticks;
# the checker strips spans of any run length, so the '<=' inside is code.
DIR_DBT="${TMPDIR_TEST}/dbt"
mkdir -p "${DIR_DBT}"
cat >"${DIR_DBT}/double-backtick.md" <<'MD'
# Double-backtick span hides the hazard

Use ``(gate <= 2,000)`` to express the inference gate inline.
MD

run "${DIR_DBT}"
check_rc_zero  "double-backtick-exits-zero"
check_absent   "double-backtick-no-violation" "bare < not starting a valid tag"

# --- Fixture 5: a triple-backtick fence that CONTAINS a lone double-backtick. ---
# The fence-length rule requires the closing run to be the SAME char and at
# least as long as the opener, so an inner ``` shorter run (or the lone ``)
# must NOT close the fence early and expose the hazard on a later line.
DIR_LEN="${TMPDIR_TEST}/fencelen"
mkdir -p "${DIR_LEN}"
cat >"${DIR_LEN}/fence-length.md" <<'MD'
# Fence-length rule keeps the block open

```
here is a lone `` double backtick inside the block
inference-perf TTFT p99 gate <= 2,000 ms
```
MD

run "${DIR_LEN}"
check_rc_zero  "fence-length-exits-zero"
check_absent   "fence-length-no-violation" "bare < not starting a valid tag"

# --- Fixture 6: fence opener indented beneath a list item. ---
# The tracker used to anchor on column 1, so an indented fence never opened and
# its contents were scanned as prose. Three spaces is the normal list-item case.
DIR_IND_OPEN="${TMPDIR_TEST}/indent-open"
mkdir -p "${DIR_IND_OPEN}"
cat >"${DIR_IND_OPEN}/indented-opener.md" <<'MD'
# Indented fence opener

1. Run the command:

   ```
   kubectl get <pod>
   ```
MD

run "${DIR_IND_OPEN}"
check_rc_zero "indented-opener-exits-zero"
check_absent  "indented-opener-no-violation" "bare <word> tag"

# --- Fixture 7: closer indented independently of the opener. ---
# The closing fence may use any indentation, and its indent is NOT bounded by
# the opener's. Both directions must close the block, or the tracker stays open
# and swallows the rest of the file.
DIR_IND_CLOSE="${TMPDIR_TEST}/indent-close"
mkdir -p "${DIR_IND_CLOSE}"
cat >"${DIR_IND_CLOSE}/indented-closer.md" <<'MD'
# Closer indent is independent of the opener

```
kubectl get <pod>
    ```

Prose after the block with <placeholder> must still be flagged.
MD

run "${DIR_IND_CLOSE}"
check_rc_nonzero "indented-closer-exits-nonzero"
check_contains   "indented-closer-reopens-prose" "bare <word> tag"

# --- Fixture 7b: the inverse — indented opener, column-zero closer. ---
# Fixture 7 covers opener-0/closer-4; this covers opener-3/closer-0. Both
# directions are needed: a regression that ties the closer's indent to the
# opener's (either >= or <=) satisfies one fixture and fails the other, so
# neither alone pins "the two indents are independent".
DIR_IND_CLOSE2="${TMPDIR_TEST}/indent-close-inverse"
mkdir -p "${DIR_IND_CLOSE2}"
cat >"${DIR_IND_CLOSE2}/indented-opener-flush-closer.md" <<'MD'
# Indented opener closed at column zero

   ```
   kubectl get <pod>
```

Prose after the block with <placeholder> must still be flagged.
MD

run "${DIR_IND_CLOSE2}"
check_rc_nonzero "inverse-closer-exits-nonzero"
check_contains   "inverse-closer-reopens-prose" "bare <word> tag"

# --- Fixture 8: a fence line with an info string never closes a block. ---
# A closer must be the delimiter followed only by whitespace; ```yaml is an
# opener. Treating it as a closer ended the block early and scanned the
# following code lines as prose.
DIR_INFO="${TMPDIR_TEST}/info-string"
mkdir -p "${DIR_INFO}"
cat >"${DIR_INFO}/info-string-closer.md" <<'MD'
# Info string does not close a fence

```go
fmt.Println("a")
```yaml
key: <value>
<br>
```
MD

run "${DIR_INFO}"
check_rc_zero "info-string-exits-zero"
check_absent  "info-string-no-violation" "bare <word> tag"
# <br> covers check 1's separate awk pass; a <word> hazard alone cannot catch
# a regression that affects only void-element scanning.
check_absent  "info-string-no-void-violation" "non-self-closing void element"

# --- Fixture 9: indented fence must hide contents from check 1 too. ---
# Check 1 (void elements) runs its own awk pass using the shared fence tracker.
# Fixtures using only bare <word> tags exercise check 5, so <br> is included to
# prove the fence state reaches the void-element pass too.
DIR_VOID_IND="${TMPDIR_TEST}/void-indent"
mkdir -p "${DIR_VOID_IND}"
cat >"${DIR_VOID_IND}/void-indented.md" <<'MD'
# Indented fence hides a void element from check 1

1. Run the command:

   ```
   <br>
   ```
MD

run "${DIR_VOID_IND}"
check_rc_zero "void-indented-exits-zero"
check_absent  "void-indented-no-violation" "non-self-closing void element"

# --- Fixture 10: MDX accepts a four-space-indented fence. ---
# CommonMark would parse this as indented code, but MDX disables indented code
# blocks and therefore treats the delimiters as a fence. Its payload must stay
# hidden, while prose after the independently indented closer is scanned.
DIR_FOUR="${TMPDIR_TEST}/four-space"
mkdir -p "${DIR_FOUR}"
cat >"${DIR_FOUR}/four-space-fence.md" <<'MD'
# Four-space MDX fence

    ```
    <br>
    ```

Prose after the block with <placeholder> must still be flagged.
MD

run "${DIR_FOUR}"
check_rc_nonzero "four-space-exits-nonzero"
check_absent     "four-space-hides-payload" "non-self-closing void element"
check_contains   "four-space-reopens-prose" "bare <word> tag"

# --- Fixture 11: indented tilde fence. ---
# The indent allowance applies to ~~~ fences as well as ``` fences; only the
# backtick form is covered above.
DIR_TILDE_IND="${TMPDIR_TEST}/tilde-indent"
mkdir -p "${DIR_TILDE_IND}"
cat >"${DIR_TILDE_IND}/tilde-indented.md" <<'MD'
# Indented tilde fence

1. Run the command:

   ~~~
   kubectl get <pod>
   ~~~
MD

run "${DIR_TILDE_IND}"
check_rc_zero "tilde-indented-exits-zero"
check_absent  "tilde-indented-no-violation" "bare <word> tag"

# --- Fixture 12: MDX accepts a TAB-indented fence. ---
# CommonMark advances a tab into indented code, but MDX has no indented code
# blocks and recognizes the fence. Pin both directions: its payload stays
# hidden and the tab-indented closer exposes the following prose.
DIR_TAB="${TMPDIR_TEST}/tab-fence"
mkdir -p "${DIR_TAB}"
printf '# Tab-indented fence\n\n\t```\n\t<br>\n\t```\n\nProse after the block with <placeholder> must still be flagged.\n' >"${DIR_TAB}/tab-fence.md"

run "${DIR_TAB}"
check_rc_nonzero "tab-fence-exits-nonzero"
check_absent     "tab-fence-hides-payload" "non-self-closing void element"
check_contains   "tab-fence-reopens-prose" "bare <word> tag"

# --- Fixture 13: CRLF-terminated closing fence still closes the block. ---
# awk keeps the \r on a CRLF line, so a bare closer arrives as "```\r". A
# delimiter-only test that does not tolerate that trailing \r leaves the fence
# open and silently swallows every hazard after it — a false negative, the
# dangerous direction. The repo has no text=auto normalization, so a CRLF file
# can reach the checker.
DIR_CRLF="${TMPDIR_TEST}/crlf"
mkdir -p "${DIR_CRLF}"
printf '# CRLF closer\r\n\r\n```\r\ncode\r\n```\r\n\r\nProse with <placeholder> after the block.\r\n\r\nAnd a <br> on its own line.\r\n' >"${DIR_CRLF}/crlf-closer.md"

run "${DIR_CRLF}"
check_rc_nonzero "crlf-closer-exits-nonzero"
check_contains   "crlf-closer-reopens-prose" "bare <word> tag"
# <br> covers check 1's separate awk pass; a <word> hazard alone cannot catch a
# regression that affects only void-element scanning.
check_contains   "crlf-closer-reopens-void" "non-self-closing void element"

# --- Fixture 14: a backtick in a backtick-fence info string is not a fence. ---
# CommonMark forbids a backtick inside the info string of a backtick fence --
# it would be ambiguous with an inline code span -- so the line is prose. Once
# the tracker allowed indented openers, such a line matched and opened a fence
# that never closed, hiding every later hazard through EOF. Both hazards are on
# separate lines because check 5 skips any line carrying a void element.
DIR_TICK="${TMPDIR_TEST}/info-backtick"
mkdir -p "${DIR_TICK}"
cat >"${DIR_TICK}/info-backtick.md" <<MD
# Backtick in the info string

   \`\`\`foo\`bar

Prose with <placeholder> after.

And a <br> on its own line.
MD
cat >"${DIR_TICK}/info-backtick-list.md" <<'MD'
1. ```foo`bar
lazy continuation

   ```
   nested code

```
outer block
```

Prose with <placeholder> after the outer block.
MD

run "${DIR_TICK}"
check_rc_nonzero "info-backtick-exits-nonzero"
check_contains   "info-backtick-reopens-prose" "bare <word> tag"
check_contains   "info-backtick-reopens-void"  "non-self-closing void element"
check_contains   "info-backtick-preserves-list-laziness" "info-backtick-list.md"

# --- Fixture 15: a TILDE fence info string may contain a backtick. ---
# The restriction is backtick-fence-only, so ~~~ with a backtick in its info
# string is a real fence and must still hide its contents.
DIR_TILDE_TICK="${TMPDIR_TEST}/tilde-backtick"
mkdir -p "${DIR_TILDE_TICK}"
cat >"${DIR_TILDE_TICK}/tilde-backtick.md" <<MD
# Tilde fence with a backtick in the info string

~~~foo\`bar
<br>
~~~
MD

run "${DIR_TILDE_TICK}"
check_rc_zero "tilde-backtick-exits-zero"
check_absent  "tilde-backtick-no-violation" "non-self-closing void element"

# --- Fixture 16: a fence inside a list item ends at the list boundary. ---
# CommonMark closes a list-scoped fence implicitly when the list item ends, so
# the column-zero fence below is the NEXT block opener, not this one closer.
# Reading it as a closer inverts every later fence and hides the trailing
# prose. Contrast fixture 7b, where the same shape at top level DOES close --
# only the enclosing list scope tells them apart.
DIR_LIST="${TMPDIR_TEST}/list-scope"
mkdir -p "${DIR_LIST}"
cat >"${DIR_LIST}/list-scope.md" <<'MD'
# List-scoped fence then an outer block

1. Item with a nested fence:

   ```
   nested code

```
outer block
```

Prose with <placeholder> after everything.

And a <br> on its own line.
MD

run "${DIR_LIST}"
check_rc_nonzero "list-scope-exits-nonzero"
check_contains   "list-scope-reopens-prose" "bare <word> tag"
check_contains   "list-scope-reopens-void"  "non-self-closing void element"

# --- Fixture 17: a list-scoped fence ends at ANY outdented nonblank line. ---
# Not just at another fence line: outdented prose or a new list item ends the
# item, and with it the fence. Leaving the tracker open here hides everything
# to EOF.
DIR_OUTD="${TMPDIR_TEST}/outdent"
mkdir -p "${DIR_OUTD}"
cat >"${DIR_OUTD}/outdent.md" <<'MD'
# Unclosed nested fence, then outdented prose

1. Item:

   ```
   nested code

Outdented prose with <placeholder> here.

And a <br> on its own line.
MD

run "${DIR_OUTD}"
check_rc_nonzero "outdent-exits-nonzero"
check_contains   "outdent-reopens-prose" "bare <word> tag"
check_contains   "outdent-reopens-void"  "non-self-closing void element"

# --- Fixture 18: a lazy paragraph continuation keeps the list open. ---
# CommonMark keeps an unindented line that directly follows item text inside
# the item. Ending the list there loses the scope, so a later indented fence is
# treated as top-level and the fence phase inverts again.
DIR_LAZY="${TMPDIR_TEST}/lazy"
mkdir -p "${DIR_LAZY}"
cat >"${DIR_LAZY}/lazy.md" <<'MD'
# Lazy continuation keeps list scope

1. Item text
lazy continuation line

   ```
   nested code

```
outer
```

Prose with <placeholder> after.

And a <br> on its own line.
MD

run "${DIR_LAZY}"
check_rc_nonzero "lazy-exits-nonzero"
check_contains   "lazy-reopens-prose" "bare <word> tag"
check_contains   "lazy-reopens-void"  "non-self-closing void element"

# --- Fixture 19: a thematic break is not a list marker. ---
# "- - -" and "* * *" match a naive list-marker regex but are thematicBreak in
# CommonMark. Recording one as a marker scopes a later top-level fence to a
# phantom list, inverting its closer. Note awk has no backreferences, so the
# break pattern must spell out each delimiter.
DIR_TB="${TMPDIR_TEST}/thematic"
mkdir -p "${DIR_TB}"
cat >"${DIR_TB}/thematic.md" <<'MD'
# Thematic break is not a list

- - -

  ```
  code
```

Prose with <placeholder> after.

And a <br> on its own line.
MD

run "${DIR_TB}"
check_rc_nonzero "thematic-exits-nonzero"
check_contains   "thematic-reopens-prose" "bare <word> tag"
check_contains   "thematic-reopens-void"  "non-self-closing void element"

# --- Fixture 20: an unclosed fence at EOF is valid MDX. ---
# CommonMark and the pinned MDX parser treat EOF as the end of a fenced block;
# a closing delimiter is optional. Its contents must remain hidden from every
# prose check rather than being rescanned as a malformed document.
DIR_EOF_FENCE="${TMPDIR_TEST}/eof-fence"
mkdir -p "${DIR_EOF_FENCE}"
cat >"${DIR_EOF_FENCE}/eof-fence.md" <<'MD'
# Fence continuing through EOF

```go
func main() {
    fmt.Println("<placeholder>")
    fmt.Println("<br>")
}
MD

run "${DIR_EOF_FENCE}"
check_rc_zero "eof-fence-exits-zero"
check_absent  "eof-fence-no-word-violation" "bare <word> tag"
check_absent  "eof-fence-no-void-violation" "non-self-closing void element"

# --- Fixture 21: a later EOF fence cannot hide a list-boundary phase bug. ---
# A raw delimiter-parity probe can be neutralized by this final valid unclosed
# fence: the parser sees it as a new block, while an inverted tracker sees a
# closer and ends apparently balanced. The prose before it must still surface.
DIR_PARITY="${TMPDIR_TEST}/list-parity"
mkdir -p "${DIR_PARITY}"
cat >"${DIR_PARITY}/list-parity.md" <<'MD'
# List boundary followed by an unclosed outer fence

1. Item:

   ```
   nested code

```
outer block
```

Prose with <placeholder> after the outer block.

And a <br> on its own line.

```
safe code through EOF
MD

run "${DIR_PARITY}"
check_rc_nonzero "list-parity-exits-nonzero"
check_contains   "list-parity-reopens-prose" "bare <word> tag"
check_contains   "list-parity-reopens-void"  "non-self-closing void element"

# --- Fixture 22: leaving a nested list restores the parent item scope. ---
# A single scalar list indent loses the outer item after seeing the nested
# marker. The following fence belongs to the outer item, so its column-zero
# boundary starts a new top-level block and prose after that block is visible.
DIR_NESTED_LIST="${TMPDIR_TEST}/nested-list"
mkdir -p "${DIR_NESTED_LIST}"
cat >"${DIR_NESTED_LIST}/nested-list.md" <<'MD'
# Nested list followed by an outer-item fence

1. Outer item

   - Nested item

   ```
   nested code

```
outer block
```

Prose with <placeholder> after everything.

And a <br> on its own line.
MD

run "${DIR_NESTED_LIST}"
check_rc_nonzero "nested-list-exits-nonzero"
check_contains   "nested-list-reopens-prose" "bare <word> tag"
check_contains   "nested-list-reopens-void"  "non-self-closing void element"

# --- Fixture 23: an empty list marker still establishes item indentation. ---
# CommonMark permits a marker with no same-line content. A fence on the next
# line belongs to that empty item when it meets the marker-width-plus-one
# continuation indent; the column-zero delimiter therefore starts a new outer
# block. Cover both marker widths because bullets and ordered markers establish
# different continuation columns.
DIR_EMPTY_LIST="${TMPDIR_TEST}/empty-list"
mkdir -p "${DIR_EMPTY_LIST}"
cat >"${DIR_EMPTY_LIST}/empty-bullet.md" <<'MD'
-
  ```
  nested code

```
outer block
```

Prose with <placeholder> after everything.
MD
cat >"${DIR_EMPTY_LIST}/empty-ordered.md" <<'MD'
1.
   ```
   nested code

```
outer block
```

And a <br> on its own line.
MD

run "${DIR_EMPTY_LIST}"
check_rc_nonzero "empty-list-exits-nonzero"
check_contains   "empty-bullet-reopens-prose" "empty-bullet.md"
check_contains   "empty-bullet-reopens-word" "bare <word> tag"
check_contains   "empty-ordered-reopens-void" "empty-ordered.md"
check_contains   "empty-ordered-reopens-void-diagnostic" "non-self-closing void element"

# --- Fixture 24: an outdented MDX block ends the preceding list. ---
# JSX flow elements and MDX flow comments are block constructs, not lazy
# paragraph continuations. Keeping a stale list scope across either one makes
# the valid indented top-level fence that follows close implicitly on its first
# content line, producing false positives from code.
DIR_MDX_BOUNDARY="${TMPDIR_TEST}/mdx-boundary"
mkdir -p "${DIR_MDX_BOUNDARY}"
cat >"${DIR_MDX_BOUNDARY}/mdx-boundary.md" <<'MD'
1. An item before a JSX flow element
<Component />

   ```
   <placeholder>
```

1. An item before an MDX flow comment
{/* this is a block comment */}

   ```
   <br>
```
MD

run "${DIR_MDX_BOUNDARY}"
check_rc_zero "mdx-boundary-exits-zero"
check_absent  "mdx-boundary-no-word-violation" "bare <word> tag"
check_absent  "mdx-boundary-no-void-violation" "non-self-closing void element"

# --- Fixture 25: a fence may open directly after a list marker. ---
# The marker prefix is a container, not prose before the delimiter. Both checker
# passes must hide the fenced payload just as they do for an opener placed on
# the following indented line.
DIR_MARKER_FENCE="${TMPDIR_TEST}/marker-fence"
mkdir -p "${DIR_MARKER_FENCE}"
cat >"${DIR_MARKER_FENCE}/marker-fence.md" <<'MD'
- ```md
  <placeholder>
  <br>
  ```
MD

run "${DIR_MARKER_FENCE}"
check_rc_zero "marker-fence-exits-zero"
check_absent  "marker-fence-no-word-violation" "bare <word> tag"
check_absent  "marker-fence-no-void-violation" "non-self-closing void element"

# --- Fixture 26: a marker-line fence still ends at the list boundary. ---
# Recognizing the same-line opener without assigning its item scope would make
# the first column-zero delimiter close it instead of opening the outer block,
# hiding the trailing prose again.
DIR_MARKER_BOUNDARY="${TMPDIR_TEST}/marker-boundary"
mkdir -p "${DIR_MARKER_BOUNDARY}"
cat >"${DIR_MARKER_BOUNDARY}/marker-boundary.md" <<'MD'
1. ```
   nested code

```
outer block
```

Prose with <placeholder> after everything.

And a <br> on its own line.
MD

run "${DIR_MARKER_BOUNDARY}"
check_rc_nonzero "marker-boundary-exits-nonzero"
check_contains   "marker-boundary-reopens-prose" "bare <word> tag"
check_contains   "marker-boundary-reopens-void" "non-self-closing void element"

# --- Fixture 27: prose-lookalike markers must not leave a stale list scope. ---
# An ordered marker starting above 1 cannot interrupt a paragraph, and a blank
# immediately after an empty list item ends that item. Treating either spelling
# as an active list makes the valid indented top-level fence close on its first
# outdented payload line and reports code as prose.
DIR_LIST_LOOKALIKE="${TMPDIR_TEST}/list-lookalike"
mkdir -p "${DIR_LIST_LOOKALIKE}"
cat >"${DIR_LIST_LOOKALIKE}/list-lookalike.md" <<'MD'
This paragraph continues on the next line.
2. This is still paragraph text.

   ```
<placeholder>
```

-

  ```
<br>
```
MD

run "${DIR_LIST_LOOKALIKE}"
check_rc_zero "list-lookalike-exits-zero"
check_absent  "list-lookalike-no-word-violation" "bare <word> tag"
check_absent  "list-lookalike-no-void-violation" "non-self-closing void element"

# --- Fixture 28: completed headings/tables do not keep paragraph laziness. ---
# A setext underline closes its paragraph, and a GFM table row remains part of
# the table. An ordered list may therefore start above 1 immediately afterward;
# rejecting those markers as paragraph continuations loses the fence scope and
# hides the trailing hazards.
DIR_BLOCK_BOUNDARY="${TMPDIR_TEST}/block-boundary"
mkdir -p "${DIR_BLOCK_BOUNDARY}"
cat >"${DIR_BLOCK_BOUNDARY}/setext-boundary.md" <<'MD'
Setext heading
===
2. Item

   ```
   nested code

```
outer block
```

Prose with <placeholder> after everything.
MD
cat >"${DIR_BLOCK_BOUNDARY}/table-boundary.md" <<'MD'
| Name | Value |
| --- | --- |
| one | two |
2. Item

   ```
   nested code

```
outer block
```

And a <br> on its own line.
MD

run "${DIR_BLOCK_BOUNDARY}"
check_rc_nonzero "block-boundary-exits-nonzero"
check_contains   "setext-boundary-reopens-prose" "setext-boundary.md"
check_contains   "setext-boundary-reopens-word" "bare <word> tag"
check_contains   "table-boundary-reopens-void" "table-boundary.md"
check_contains   "table-boundary-reopens-void-diagnostic" "non-self-closing void element"

if (( fails > 0 )); then
    echo "${fails} test(s) failed"
    exit 1
fi
echo "All check-docs-mdx tests passed"
