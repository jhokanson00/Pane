# Security

## Reporting a problem

Please report security problems privately: on GitHub, open the **Security** tab of this
repository and choose **Report a vulnerability**. Don't open a public issue for them, and
don't attach recordings that show private information.

Say what you found, the Pane version (Pane ▸ About Pane) and macOS version, and how to
reproduce it. You'll get a reply on the report, and fixes ship as a Pane update.

Only the latest release is supported; Pane updates itself (Pane ▸ Check for Updates…).

## What counts

- Anything that could get code onto a Mac through Pane's updates, or make Pane run code
  it didn't ship.
- Blurs that can be read back, or sensitive text Auto-blur shows unblurred in an export.
- Pane recording something it says it leaves out (its own windows, "Never record" apps,
  notification banners), or anything leaving the Mac other than the update check.
- Pane losing or overwriting files it shouldn't touch.

## How updates are protected

Pane uses [Sparkle](https://sparkle-project.org) over HTTPS. Every update is signed with
an EdDSA key that isn't on GitHub, and Pane checks that signature against the public key
it shipped with before installing. From Pane 1.1 the update feed is signed too: Pane
accepts only a signed feed (`SURequireSignedFeed`) and checks each download before
opening it (`SUVerifyUpdateBeforeExtraction`). So changing a GitHub release isn't enough
to make Pane install anything, or to point it at another download. Pane never installs
an older version. Downloads are signed with Developer ID (team `DHGK36B2V9`) and
notarized by Apple.

To check a download yourself:

```bash
spctl --assess --type open --context context:primary-signature -v Pane-<version>.dmg
shasum -a 256 Pane-<version>.dmg   # compare with the release notes
```
