#!/usr/bin/env bash
#
# Checks that the DuckDB-family plugins ask DuckDB for a plan the app can parse.
#
# A plugin's statics replace the curated PluginMetadataRegistry snapshot wholesale
# (registerLocked carries over isDownloadable and little else), so updating the
# registry alone leaves the shipped SQL unchanged. Each variant's SQL and format
# have to agree: a bare EXPLAIN returns box-drawing art that no parser reads, and
# only EXPLAIN (FORMAT JSON) may claim .duckdbJson. Run this after touching either
# plugin's EXPLAIN wiring.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARBOR="$ROOT/Plugins/HarborDriverPlugin/HarborPlugin.swift"
DUCKDB="$ROOT/Plugins/DuckDBDriverPlugin/DuckDBPlugin.swift"
status=0

if ! grep -q 'sqlPrefix: "EXPLAIN", format: .duckdbBoxTree' "$HARBOR"; then
    echo "error: HarborPlugin default explain variant does not pair EXPLAIN with .duckdbBoxTree" >&2
    status=1
fi

if ! grep -q 'sqlPrefix: "EXPLAIN (FORMAT JSON)", format: .duckdbJson' "$HARBOR"; then
    echo "error: HarborPlugin JSON explain variant does not pair FORMAT JSON with .duckdbJson" >&2
    status=1
fi

if ! grep -q '"EXPLAIN \\(sql)"' "$DUCKDB"; then
    echo "error: DuckDBPlugin.buildExplainQuery no longer runs a bare EXPLAIN" >&2
    status=1
fi

if [ "$status" -eq 0 ]; then
    echo "duckdb explain: box art is the default, JSON keeps its parser"
fi
exit "$status"
