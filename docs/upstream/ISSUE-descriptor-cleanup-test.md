# Directory cleanup test mistakes descriptor reuse for a leak

## Description

The callback-failure cleanup regression requires a released descriptor number to remain invalid. Concurrent tests open files and can reuse that number immediately. In full native coverage, F_GETFD returned a valid close-on-exec descriptor after the callback had unwound, producing a false leak report. The separate errno assertion also ran after a test macro could change thread-local errno.

## Expected behavior

The test must detect whether the original private directory remains open, while accepting a number reused for another object. The production helper already closes its owned descriptor in defer and must remain unchanged.

Related: [implementation handoff](PR-descriptor-cleanup-test.md).
