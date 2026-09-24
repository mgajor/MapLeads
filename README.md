# MapLeads

A native macOS app for finding and qualifying Google Maps business leads, then managing your outreach locally.

MapLeads uses the [Google Maps Places Scraper by kaix on Apify](https://apify.com/kaix/google-maps-places-scraper) to discover businesses. Its primary workflow is identifying businesses **without a website listed on Google Maps**, checking the evidence, and organizing a call list for website and business-profile services.

**The app and lead library live on your Mac. Scraping runs on Apify and incurs charges on your Apify account.**

## Features

- Search by business niche, location, radius, result limit, and detail level.
- Require explicit authorization for a paid search, with an Apify run spending cap.
- Resume an interrupted cloud run or request an abort.
- Save results locally and deduplicate them by Place ID, with a deterministic fallback when unavailable.
- Preserve saved outreach notes, stages, meeting dates, and follow-ups when refreshing listings.
- Separate leads into **Call candidates**, **Needs verification**, and **Excluded**, with evidence and score explanations.
- Filter by website status, phone availability, operating status, and outreach stage.
- Track contacted, interested, meeting booked, won, not interested, and do-not-contact stages.
- Import Apify dataset JSON; export filtered CSV lists and plain-text business briefs for your existing website templates.
- Store your API token in macOS Keychain.

No local web server, third-party Swift packages, or browser-based app shell.

## Requirements

- **Run:** macOS 14 or later.
- **Build:** Apple's command-line developer tools with Swift 5.9 or later. The current build was verified with Swift 6.3.3 on Apple Silicon.
- **Search:** an Apify account, API token, and sufficient account credit or plan allowance. JSON import and saved-lead management do not require a token.

The build script produces an app for the machine's native architecture, not a universal binary.

## Build and launch

```bash
git clone git@github.com:mgajor/MapLeads.git
cd MapLeads
bash build-app.sh
open dist/MapLeads.app
```

If the developer tools are not installed:

```bash
xcode-select --install
```

You can move `dist/MapLeads.app` to `/Applications`. The built app does not need Xcode, Node.js, or Python to run.

This is a standard native `.app` bundle. Once copied into Applications, launch it from Finder or Spotlight. To pin it, right-click its Dock icon and choose **Options → Keep in Dock**. Use **⌘Q** to quit; closing a window is separate from quitting on macOS. The app and saved library persist after quitting. Install in `/Applications` or your user's `~/Applications`, not `/System`.

The icon's editable vector master is `Assets/MapLeads.svg`; `Assets/MapLeads.icns` contains the standard macOS icon resolutions and is copied into the bundle during the build. The design uses a mint map pin and cream storefront on a rounded navy/teal tile.

The app is **locally ad-hoc signed**, not Developer ID signed or notarized for distribution. Build output in `dist/` and Swift build artifacts in `.build/` are excluded from Git.

## First search

1. Open **Apify settings**.
2. Paste your [Apify API token](https://console.apify.com/settings/integrations) and choose **Save token**.
3. Select **Find leads** and enter a niche plus a city/state/country.
4. Choose a radius, maximum result count, detail level, and USD spending cap.
5. Review the actor's current pricing, authorize the paid run, and start the search.
6. Review the resulting candidate list and inspect each business on Maps before calling or building a preview.

Start with a small search. Area searches use a rectangle around the location, not municipal boundaries, and may return fewer results than requested.

### Detail levels

- **Basic:** core contact, location, hours, rating, and operating data.
- **Detailed:** additional profile information, including claimed status when returned.
- **Rich:** additional review and media detail.

Fields can be missing at any level. MapLeads retains the source JSON for inspection rather than treating unavailable fields as negative evidence.

### Costs and interrupted runs

MapLeads sends `maxTotalChargeUsd` when starting a run; Apify handles billing and cap enforcement. Consult the actor's current pricing for event and platform-usage charges. A result limit is not a price quote.

The app retains the pending run ID in macOS preferences. **Resume / collect** checks that run and retrieves its results without starting a new paid run. Failed or aborted runs may have partial results.

**Closing MapLeads does not stop a cloud run.** Use **Abort cloud run** or the Apify Console; charges already incurred remain. If a start request fails before the app receives a run ID, inspect the Console before retrying because the server may already have started it.

## Qualification rules

| Queue | Meaning |
| --- | --- |
| **Call candidates** | Website explicitly absent from the listing; phone and address present; operational business status; no closure, move, consumer-alert, or outreach opt-out exclusion. |
| **Needs verification** | Insufficient evidence, such as an omitted website field, unknown operating status, or missing address. |
| **Excluded** | Website present, no phone, closed/moved listing, consumer alert, or a saved not-interested/do-not-contact stage. Records remain in **All leads**. |

Important distinctions:

- **No website listed is not proof that no website exists.** Check separately before pitching.
- **Closed right now is not out of business.** Opening-hours status is separate from temporary or permanent business closure.
- **Unknown is not false.** Missing claimed status does not mean unclaimed; missing media does not mean zero photos.
- **Scores rank evidence, not commercial certainty.** Hard exclusions cannot be outweighed by positive score contributions.
- A missing address is not automatically disqualifying for a service-area business; it requires verification.

## Outreach and exports

Select a business, edit its stage, notes, meeting date, or follow-up date, then click **Save outreach before selecting another business**.

The follow-up queue lists scheduled follow-ups; it does not send notifications or create calendar events.

- **Import JSON:** accepts an Apify dataset JSON array, not CSV or a run-response envelope. Malformed records produce an error instead of a silent partial import.
- **Export CSV:** exports the current filtered list and neutralizes formula-like spreadsheet values.
- **Export brief:** exports business facts, qualification evidence, potential offers, and the current detail editor's notes and scheduling fields.

MapLeads does **not** generate websites, create GitHub repositories, deploy to Vercel, or automate calls. Business briefs are intended for your existing template workflow. Verify permission to use business assets and keep private previews access-controlled; `noindex` or a deployment URL alone is not access control.

## Storage and privacy

| Data | Location |
| --- | --- |
| Lead library and source records | `~/Library/Application Support/MapLeads/leads.json` |
| Apify API token | macOS Keychain; service `local.MapLeads`, account `apify` |
| Pending run ID | macOS app preferences |

Search criteria are sent to Apify, which processes the scrape and stores its cloud run/dataset. Local storage does not mean the scraping is offline or that Apify's copy has been deleted.

The local library is not encrypted by the app. Use normal macOS account protections, FileVault, and backups appropriate for your outreach data. Back up `leads.json`; do not commit it or API tokens to Git.

Writes are atomic. If the existing library cannot be read, the app refuses to overwrite it. Preserve the damaged file, restore a backup, and relaunch. Removing it discards its saved records.

## Project layout

```text
Sources/MapLeads/
  App.swift       SwiftUI workspace, search lifecycle, and outreach editor
  Core.swift      Parsing, qualification, local persistence, and CSV export
  Apify.swift     Native URLSession API client and Keychain token storage
Package.swift     Swift executable package, macOS 14 minimum
Info.plist        App bundle metadata
build-app.sh      Release build, app bundling, and local ad-hoc signing
USAGE.txt         Plain-text operating instructions
```

For compiler-only verification:

```bash
swift build -c release
```

## Verification status

Verified during initial development:

- Release compilation and native app launch with a visible window.
- Qualification cases covering closed-now versus permanently closed, unknown website data, domain-only websites, and moved listings.
- Deduplication, persisted outreach across refreshes, and do-not-contact exclusions.
- CSV formula protection and malformed-input handling.
- Live Apify authentication-error handling without starting a paid run.

These behavioral checks used throwaway smoke programs; there is no checked-in automated test suite.

**Still requires account-level/manual verification:** successful paid search completion, Keychain save/read with a real credential, and a full UI click-through. Accessibility automation was unavailable during initial development, and screenshot inspection could not be completed. No paid scrape was started as part of that verification.

## References

- [Actor documentation and current pricing](https://apify.com/kaix/google-maps-places-scraper)
- [Apify: start an Actor run](https://docs.apify.com/api/v2/actors-runs-post)
- [Apify: retrieve dataset items](https://docs.apify.com/api/v2/dataset-items-get)
