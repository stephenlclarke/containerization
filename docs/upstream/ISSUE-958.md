# Sparse EXT4 reads and export discard logical extent positions

[Upstream #958](https://github.com/apple/containerization/issues/958) reports exported sparse files with data shifted before its proper offset. The reader decoded only physical extent ranges, discarding `ee_block` and interpreting unwritten lengths as initialized block counts. Both ordinary file reads and archive export concatenated these physical ranges.

Preserve logical starts, physical starts, extent lengths and unwritten state. Holes and unwritten ranges must read as zeros through the inode's EOF, including offset reads and archives containing hardlinks. Reject malformed overlapping or out-of-bounds extents and unrepresentable block-to-byte offsets without arithmetic traps. Validate supported block size before using superblock geometry. Export must reject a short physical read rather than claim a complete file.

The [kernel extent format](https://www.kernel.org/doc/html/latest/filesystems/ext4/ifork.html) distinguishes initialized length `0x8000` from unwritten lengths greater than `0x8000`. Deeper-than-one extent trees remain outside the reader's existing supported scope. This correction does not change the formatter, sparse import, guest runtime or dependency pins.
