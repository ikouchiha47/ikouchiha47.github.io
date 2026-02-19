---
active: true
layout: group_index
title: "PostgreSQL Internals Deep Dive"
subtitle: "A wizard-level exploration of the PostgreSQL codebase"
date: 2026-02-19 00:00:00
background_color: '#000'
group: postgresql
permalink: /postgresql-internals/
---

> A wizard-level exploration of the PostgreSQL codebase, from SQL string to disk blocks and back.

## How to Read This Book

Each chapter follows a **zoom-in / zoom-out** pattern:

1. **Chapter index** — bird's-eye overview, key concepts, how the subsystem fits into PG as a whole
2. **Topic pages** — deep dives into specific mechanisms, with source file references (`file:line`), struct layouts, and diagrams
3. **Connections** section at the bottom of every page — links back out to related subsystems

You can read linearly or jump to any topic. The dependency arrows in each chapter index will guide you.

## Prerequisites

- Comfortable reading C code
- Basic understanding of operating systems (processes, virtual memory, file I/O)
- Familiarity with SQL and relational databases
- A cloned PostgreSQL source tree (this book references `src/` paths throughout)

## Acknowledgments

Built by studying the PostgreSQL source code, READMEs in `src/backend/*/README`, and the following references:

- [The Internals of PostgreSQL](https://www.interdb.jp/pg/) by Hironobu Suzuki
- [PostgreSQL 14 Internals](https://postgrespro.com/community/books/internals) by Egor Rogov
- Original papers cited in each chapter
