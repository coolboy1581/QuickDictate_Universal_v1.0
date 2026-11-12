# Maintainer distribution and signing guide

The default `Scripts/build_universal_app.sh` makes an ad-hoc-signed macOS Universal 2 app. **Ad-hoc signing does not confer a trusted Apple Developer identity or notarization.** It is appropriate for source builds and controlled betas with clear warnings, not frictionless consumer installation.

For a later trusted stable distribution:

1. Obtain an Apple Developer Program membership, a valid **Developer ID Application** signing certificate, and configure the certificate in the macOS Keychain. Never commit the private certificate or export password.
2. Run tests on a current supported Xcode installation, perform a clean Universal 2 build with `SIGN_IDENTITY` set to the local Developer ID identity. The build script sets Hardened Runtime for that path.
3. Package the signed app into a DMG. Sign the DMG if needed by the chosen workflow and submit it through Apple's `notarytool` using short-lived authentication (prefer App Store Connect API keys or a secure keychain profile). Store signing/notary secrets only in private CI secrets, not public build logs.
4. Wait for notarization to succeed; staple the notarization ticket to the artifact when supported, then verify with `spctl --assess` and `stapler validate` on the finished release.
5. Test the exact uploaded binary on a different clean macOS user account and both architecture classes before advertising it as stable.
6. Upload only the verified signed/notarized DMG to GitHub Releases, with checksums and updated release notes.

No such signing certificate or notarization credentials were provided for `v2.0.0-beta.1`. Do not mark that release signed/notarized.
