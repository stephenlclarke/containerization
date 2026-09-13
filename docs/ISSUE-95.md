# Issue 95: publish the fork VM-init image

The fork's enhanced Container distribution identifies its exact Containerization
source revision and derives a VM-init image reference in the fork namespace.
The existing reusable build only published images for Apple release tags, so a
fresh enhanced Homebrew installation could not resolve its own default image.

The compose release gate imported a retained OCI archive and therefore did not
exercise the clean-install registry path. A marker-owned clean runtime exposed
the missing publication as a deterministic `404 Not Found` during system boot.
