#!/usr/bin/env bash
#
# generate-appcast.sh — render a single-item Sparkle appcast (RSS) to stdout.
#
# Each Yggdrasil release ships an appcast.xml describing *itself*; the feed URL
# baked into the app (SUFeedURL) resolves to the latest published release's
# asset, so an app on an older version fetches this one item and offers the
# update. Signing (the EdDSA signature + byte length) is produced upstream by
# Sparkle's `sign_update`; this script only templates the XML, which keeps it
# trivially testable (see Tests/Integration/AppcastGenerationTests.swift).
#
# Inputs (environment variables):
#   VERSION             required  CFBundleShortVersionString, e.g. 0.5.0
#   BUILD               required  CFBundleVersion (Sparkle orders by this), e.g. 6
#   DMG_URL             required  absolute URL of the release DMG
#   DMG_LENGTH          required  DMG size in bytes (from sign_update)
#   ED_SIGNATURE        required  base64 EdDSA signature (from sign_update)
#   MIN_SYSTEM          optional  minimum macOS version (default 14.0)
#   PUB_DATE            optional  RFC-822 date (default: `date -R` now)
#   RELEASE_NOTES_LINK  optional  URL of the release notes page (omitted if unset)
#   APPCAST_TITLE       optional  channel title (default Yggdrasil)
#
set -euo pipefail

: "${VERSION:?VERSION is required}"
: "${BUILD:?BUILD is required}"
: "${DMG_URL:?DMG_URL is required}"
: "${DMG_LENGTH:?DMG_LENGTH is required}"
: "${ED_SIGNATURE:?ED_SIGNATURE is required}"
MIN_SYSTEM="${MIN_SYSTEM:-14.0}"
APPCAST_TITLE="${APPCAST_TITLE:-Yggdrasil}"
PUB_DATE="${PUB_DATE:-$(date -R)}"

notes_line=""
if [[ -n "${RELEASE_NOTES_LINK:-}" ]]; then
    notes_line="            <sparkle:releaseNotesLink>${RELEASE_NOTES_LINK}</sparkle:releaseNotesLink>"$'\n'
fi

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>${APPCAST_TITLE}</title>
        <item>
            <title>Version ${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:minimumSystemVersion>${MIN_SYSTEM}</sparkle:minimumSystemVersion>
${notes_line}            <enclosure
                url="${DMG_URL}"
                sparkle:version="${BUILD}"
                sparkle:shortVersionString="${VERSION}"
                length="${DMG_LENGTH}"
                type="application/octet-stream"
                sparkle:edSignature="${ED_SIGNATURE}" />
        </item>
    </channel>
</rss>
XML
