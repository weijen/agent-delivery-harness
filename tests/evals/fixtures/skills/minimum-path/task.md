Complete `build_report(source, output)` in report.py. Produce a UTF-8 JSON file
containing the three groups with the largest totals across the entire source,
sorted by total descending and group name ascending for ties. Each row is
`{"group": <name>, "total": <integer>}`. Fewer than three groups and an empty
source are valid. The source can exceed the raw-row result window.

Use only Source's public API. Do not change source.py or its constraints.
If the source is unavailable, propagate ConnectionError and leave any existing
output untouched; never report a partial or empty success for that failure.
Add and execute useful tests, then finish. No extra features are requested.
