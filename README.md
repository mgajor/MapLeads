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
- Separate leads into website opportunities, existing-site opportunities, inactive/stale leads, needs verification, and excluded queues.
- Filter by website status, phone availability, operating status, and outreach stage.
- Track contacted, interested, meeting booked, won, not interested, and do-not-contact stages.
- Import Apify dataset JSON; export filtered CSV lists and plain-text business briefs for your existing website templates.
- Store your API token in macOS Keychain.
- Optional Firecrawl website discovery, DataForSEO newest-review checks, and OpenAI-compatible AI opportunity analysis with model discovery.

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

1. Open **Settings → Apify**.
2. Paste your [Apify API token](https://console.apify.com/settings/integrations) and choose **Save Apify token**.
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
| **Website opportunities** | Reachable operational listings without a listed/discovered site; enabled review and website checks must pass. With enrichment disabled, this is based on Maps data only. |
| **Existing-site opportunities** | Reachable operational businesses with listed or strongly matched websites, eligible for service discovery rather than a new-site pitch. |
| **Inactive / stale leads** | When review qualification is enabled, the newest retrieved review is older than the configured cutoff (24 months by default). Not a confirmed closure. |
| **Needs verification** | Missing/ambiguous evidence, zero reviews, unknown dates, pending/failed checks, or expired qualification evidence. |
| **Excluded** | No phone, closed/moved listing, consumer alert, or saved not-interested/do-not-contact stage. Records remain in All leads. |

Important distinctions:

- **No website listed is not proof that no website exists.** Check separately before pitching.
- **Closed right now is not out of business.** Opening-hours status is separate from temporary or permanent business closure.
- **Unknown is not false.** Missing claimed status does not mean unclaimed; missing media does not mean zero photos.
- **Scores rank evidence, not commercial certainty.** Hard exclusions cannot be outweighed by positive score contributions.
- A missing address is not automatically disqualifying for a service-area business; it requires verification.

## Optional enrichment (1.1)

Open **Settings** for the Enrichment, Apify, Firecrawl, DataForSEO, and AI analysis sections. All enrichment providers are **off by default**. Enabling one does not start requests; choose **Enrich this lead** or **Enrich filtered list**, inspect the confirmation, and authorize the batch.

- **Firecrawl:** save your API key and enable website discovery. Searches use business identity and inspect page content; name-only matches require verification. Existing listed sites are scraped directly. A successful search with no match means *no website found in that search*, not proof of absence.
- **DataForSEO:** save the **API login and API password**, enable review qualification, and select the stale cutoff. Requests use saved Place ID/CID plus location, newest-first sorting, and depth 10. Missing identity/location produces an actionable error rather than an ambiguous name search. Pending task IDs persist; another enrichment pass resumes collection without resubmitting. Missing or unreadable dates do not imply inactivity.
- **AI analysis:** enter an OpenAI-compatible API base URL (including its version prefix), save the key, then **Refresh models** or manually enter a model ID. Only Chat Completions-compatible models are supported. Model-list failures retain the current selection; the app never switches models automatically. Fresh content from a matched Firecrawl website is required; cached pages can be used while Firecrawl requests are disabled.

Order: **review recency → website discovery → optional AI analysis**. Stale leads skip downstream services. Each provider can be disabled independently; its saved results remain visible, but its requests and qualification gate are disabled. Successful checks are reused for 30 days by default (configurable); force refresh can incur additional charges. AI results also refresh when the selected model/base URL changes. Website identity changes invalidate website/AI caches.

**Costs:** enrichment has no shared dollar cap. Apify's run cap does not apply to Firecrawl, DataForSEO, or your AI provider. Confirmation shows the batch size and enabled services. Stop finishes the current request; submitted cloud review tasks can continue. An uncertain failed task submission may still have been billed—check the provider before retrying. Terminal failed/expired review tasks retain their IDs and surface errors rather than silently purchasing replacements.

AI output separates observations, potential opportunities, discovery questions, limitations, and source URLs. It is not a needs assessment or a closure decision. Only supplied-page citations are accepted; assertions still require human review. Scraped content is untrusted input, and no tools are exposed to the model. Selected business facts/page excerpts are sent to the configured AI provider; confirm that the base URL is one you trust. HTTPS is required except for loopback HTTP endpoints.

CSV and brief exports include enrichment evidence and the prospecting category. The CSV also retains the original **Maps-only qualification** for provenance. Stale records are retained to avoid duplicate rediscovery. Save outreach before changing selection; outreach editing is disabled during enrichment batches.

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
| Enrichment checks, pending tasks, and AI suggestions | `~/Library/Application Support/MapLeads/enrichment.json` |
| Enrichment credentials | macOS Keychain; service `local.MapLeads.enrichment` |
| Enrichment options and selected model | macOS app preferences |

Search criteria are sent to Apify, which processes the scrape and stores its cloud run/dataset. Local storage does not mean the scraping is offline or that Apify's copy has been deleted.

The local libraries are not encrypted by the app. Use normal macOS account protections, FileVault, and backups appropriate for your outreach data. Back up both `leads.json` and `enrichment.json`; do not commit them or API tokens to Git.

Writes are atomic. If the existing library cannot be read, the app refuses to overwrite it. Preserve the damaged file, restore a backup, and relaunch. Removing it discards its saved records.

## Project layout

```text
Sources/MapLeads/
  App.swift       SwiftUI workspace, search lifecycle, and outreach editor
  Core.swift      Parsing, qualification, local persistence, and CSV export
  Apify.swift     Native URLSession API client and Keychain token storage
  Enrichment.swift    Provider orchestration, caching, category routing, and evidence storage
  SettingsView.swift  Unified provider settings and enrichment detail views
  Firecrawl.swift     Website discovery and page retrieval
  ReviewProvider.swift DataForSEO newest-review tasks
  LLMProvider.swift   Compatible model discovery and grounded opportunity analysis
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

Version 1.1 verification: release build and signature verification passed; the updated native app launched with a window. Controlled-transport smoke scenarios exercised model discovery, strong website matching, grounded AI response parsing and invalid-citation rejection, newest-review timestamps versus owner replies, stale routing and downstream skips, disabled-provider isolation, cache reuse, persistence, multiline CSV, and corrupt-library preservation. These were not paid provider calls. Live Firecrawl/DataForSEO/AI account access and full settings click-through still need to be exercised with your credentials; Accessibility automation is disabled on the development machine.

## References

- [Actor documentation and current pricing](https://apify.com/kaix/google-maps-places-scraper)
- [Apify: start an Actor run](https://docs.apify.com/api/v2/actors-runs-post)
- [Apify: retrieve dataset items](https://docs.apify.com/api/v2/dataset-items-get)
- [Firecrawl search](https://docs.firecrawl.dev/api-reference/endpoint/search)
- [DataForSEO Google reviews tasks](https://docs.dataforseo.com/v3/business_data/google/reviews/task_post/)
- [OpenRouter model discovery](https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties)
