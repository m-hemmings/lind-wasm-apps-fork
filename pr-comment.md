ISSUE:
- Incremental builds were slower than expected because shared dependency work (library builds and sysroot merge) was repeatedly triggered during app builds.

WHAT CHANGED:
- Added stamp-driven targets in the top-level `Makefile` for shared build steps (`libtirpc`, `gnulib`, `zlib`, `openssl`) and for `merge-sysroot`.
- Converted `preflight` into a file-producing dependency (`build/.toolchain.env`) with `preflight` as an alias target.
- Rewired app targets (`lmbench`, `bash`, `nginx`, `coreutils`, and others) to depend on the merge stamp instead of always rerunning shared dependency recipes.
- Added `rebuild-libs` and `rebuild-sysroot` targets to force invalidation when desired.
- Updated `clean` to remove the stamp files.

EXPLANATION OF CHANGES:
- The previous graph used phony-style shared targets, so `make <app>` could repeatedly execute heavy steps even when inputs were unchanged.
- Stamp files make those shared steps incremental: once the recipe succeeds, Make sees the stamp target as up-to-date and skips re-running it unless dependencies change or the stamp is removed.
- This preserves correctness while significantly reducing repeated work in day-to-day app-only rebuild workflows.

NOTES TO REVIEWERS:
- What is a stamp driven target?
  - A stamp-driven target is a small file (for example, `build/.stamp_merge_sysroot`) used as a build marker.
  - The recipe does the real work, then `touch`es the stamp file.
  - On later runs, Make checks timestamps/dependencies; if nothing relevant changed, it skips the expensive recipe.
  - If you need to force a rebuild, delete the stamp (or run `make rebuild-libs` / `make rebuild-sysroot`).
