---
layout: page
title: Mofy Privacy Policy
description: Privacy policy for Mofy, a personal offline-first media library app for Android.
background_color: '#000'
---

# Privacy Policy for Mofy

**Effective date:** October 9, 2026

Mofy ([github.com/ikouchiha47/mofy](https://github.com/ikouchiha47/mofy)) is a personal, offline-first media library app for Android, developed and maintained by an individual developer. This policy describes what data Mofy accesses and why. Short version: your library stays on your device and in your own cloud storage — it is never sent to us, because there is no "us" server-side to send it to.

## Data stored on your device

Mofy keeps the following on your own device only, in a local database:

- Your media catalog and library entries (titles, file locations, posters, overviews).
- Watch progress and resume positions.
- Search indexes and on-device machine-learning data used for semantic search.

Uninstalling the app deletes this local data. We do not operate any server that receives, stores, or processes it.

## Google account and Google Drive access (OAuth)

If you choose to connect your Google account — for example, to back up or sync your library through Google Drive (including via tools such as rclone configured with this OAuth client) — Mofy requests only the access needed for that purpose:

- Basic account identification, so the app can connect to *your* Drive and not anyone else's.
- Access scoped to the files and folders Mofy creates or you explicitly designate for backup/sync.

Your Google data is used solely to perform the backup/sync operation you requested. It is not copied anywhere else, not used for any other feature, not shared with any third party, and not used for advertising. You can revoke access at any time from your [Google account permissions page](https://myaccount.google.com/permissions); revoking stops all future access immediately, and previously synced files remain only in your own Drive until you delete them.

## Movie metadata (TMDB)

To enrich your catalog with posters, overviews, and ratings, Mofy queries the public TMDB API. These requests contain only the title or identifier being looked up — never your library contents, watch history, or account details. TMDB's handling of that query data is governed by [TMDB's own privacy policy](https://www.themoviedb.org/privacy-policy).

## Watch Together (WebRTC)

The Watch Together feature synchronizes playback directly between participating devices over an encrypted peer-to-peer WebRTC connection. Session data exists only for the duration of the session on the participating devices and is not routed through or stored on any server we operate.

## What we do not do

- No analytics, crash reporters, or tracking SDKs.
- No advertising and no ad identifiers.
- No sale, rental, or sharing of your data with third parties, for any reason.
- No use of your data to train models, except the on-device models running locally on your phone that never leave it.

## Data retention and deletion

- Local data: deleted when you clear the app's storage or uninstall it.
- Drive backups: deleted when you delete the corresponding files or folders in your own Google Drive.
- There is no server-side copy to request deletion of, because none exists.

## Security

Local data is protected by your device's own lock screen and storage encryption. Drive data is protected by Google's authentication and whatever sharing settings you apply yourself — do not share backup folders publicly.

## Children's privacy

Mofy is not directed at children under 13, and we do not knowingly collect any data from anyone, child or adult.

## Changes to this policy

If this policy changes materially, the updated version will be posted at this same URL with a revised effective date.

## Contact

Questions about this policy or Mofy's data practices: **amitava.dev@proton.me**
