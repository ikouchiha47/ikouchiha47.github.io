---
active: true
featured: false
layout: group_index
title: "Small Databases"
subtitle: "opening up sqlite, learning how it stores and serves, and how to run it without hurting yourself"
date: 2026-10-08 00:00:00
background_color: 'linear-gradient(135deg, #0b1220 0%, #132033 55%, #1f3350 100%)'
group: small-databases
hidden: false
sitemap: true
permalink: /small-databases/
hide_toc: true
---

It started with wanting to build a storage engine. No database was built.

What happened instead was better: opening up sqlite files in a hex editor, learning how B-trees, pages and the WAL actually fit together, and then figuring out how to run the thing in production — pragmas, backups, vacuums, and the honest limits of a database that lives in a single file.

Two posts. Read them in order: first how it works inside, then how to operate it outside.

1. [Notes toward a storage engine]({% post_url 2024-07-10-building-a-storage-engine %}) — the study log. B+tree vs LSM thinking, clustered vs non-clustered indexes, a skiplist prototype, and the reading list that started all of it.
2. [Supercharge a platform backed by sqlite]({% post_url 2024-12-16-sqlite_supercharged %}) — the operations sequel. A hex-dump tour of the file format, the production PRAGMA kit, and the missing manual on backup, cleanup and partitioning.
