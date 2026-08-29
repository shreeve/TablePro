#!/usr/bin/env bash
#
# Checks that the DuckDB-family plugins ask DuckDB for a plan the app can parse.
#
# A plugin's statics replace the curated PluginMetadataRegistry snapshot wholesale
# (registerLocked carries over isDownloadable and little else), so updating the
# registry alone leaves the shipped SQL unchanged. DuckDB's default EXPLAIN is
# box-drawing art laid out in two dimensions and no parser reads it; the plan
# viewer then falls back to raw text. Run this after touching either plugin's
# EXPLAIN wiring.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARBOR="$ROOT/Plugins/HarborDriverPlugin/HarborPlugin.swift"
DUCKDB="$ROOT/Plugins/DuckDBDriverPlugin/DuckDBPlugin.swift"
status=0

if ! grep -q 'sqlPrefix: "EXPLAIN (FORMAT JSON)", format: .duckdbJson' "$HARBOR"; then
    echo "error: HarborPlugin explain variant does not pair EXPLAIN (FORMAT JSON) with .duckdbJson" >&2
    status=1
fi

if ! grep -q '"EXPLAIN (FORMAT JSON) \\(sql)"' "$DUCKDB"; then
    echo "error: DuckDBPlugin.buildExplainQuery does not request FORMAT JSON" >&2
    status=1
fi

if [ "$status" -eq 0 ]; then
    echo "duckdb explain: both plugins request FORMAT JSON"
fi
exit "$status"
