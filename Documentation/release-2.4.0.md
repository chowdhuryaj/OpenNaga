# OpenNaga 2.4.0

OpenNaga now keeps its files in its own folder, `~/Library/Application Support/OpenNaga`.

Up to 2.3.0 it shared `~/Library/Application Support/NagaController` with [NagaController](https://github.com/DParent10/NagaController), the app it started from. The two profile formats have diverged, so with both apps installed each one could rewrite the other's `profiles.json` and drop what it did not recognize. Thanks to DParent10 for reporting this.

- On first launch OpenNaga copies `profiles.json`, the mouse backup (`onboard-profile.json`) and the driver mode journal from the old folder, once. Files that already exist in the new folder are not overwritten.
- The old folder is left exactly as it is. OpenNaga does not write to it or delete it.
- If a copy fails, OpenNaga tries again at the next launch.
- No change to button mapping, mouse memory, DPI or polling rate.

Upgrading: quit OpenNaga, replace the app in Applications with the new `OpenNaga.app`. Profiles and a profile saved to the mouse carry over.

If you also use NagaController and both apps wrote to the shared folder, the imported profiles are whichever app saved last. Check your assignments after the first launch.

Apple Silicon build, ad-hoc signed, not notarized. On first launch right-click the app and choose Open, or run `xattr -dr com.apple.quarantine /Applications/OpenNaga.app`.
