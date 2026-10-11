# Synchronize the released Containerization source with Apple main

The released fork source `6db16197bbad8196a78132f86529daa89125aafb` predates Apple main `3e7bc39e66b38806ec8199aaa24509d66708eb60`. Synchronization must precede new performance work so fixes do not target obsolete APIs.

Adopt Apple's descriptor-relative traversal primitives and composites (#957), optional token service handling (#940), registry User-Agent (#753), EXT4 partial-group and journal sizing fixes (#925/#924), coverage handling (#955), build flag hook (#947), platform changes (#938) and x86 kernel updates (#950). The released source already contains the runc fixes (#941); retain them.

Preserve filtered extraction, sparse archive data offsets, deferred directory attributes, forward/chained hardlinks, last-entry replacement, descriptor ownership, explicit directory permissions, bounded and authenticated token exchange, and all sixteen runtime virtiofs slots. Archive member absolute names remain anchored below the extraction root; parent traversal remains rejected.

This synchronization does not fix the separately reported copy-root symlink exposure (#2379), sparse EXT4 export corruption (#958), sparse OCI import request (#959), or legacy iptables kernel configuration (#913). It does not change a published artifact or claim improved performance. The four focused host suites (453 cases), coverage-tool tests (19 cases), formatting/license checks and independent e2fsck checks now pass. Full product coverage and runtime qualification remain pending.
