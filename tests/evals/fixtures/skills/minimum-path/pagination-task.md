---
description: Synthetic reporting task with a genuinely paginated source.
---

Complete `build_report(source, output)` in report.py. Produce a UTF-8 JSON file
containing the three groups with the largest totals across the entire source,
sorted by total descending and group name ascending for ties. Each row is
`{"group": <name>, "total": <integer>}`. Fewer than three groups and an empty
source are valid. The existing example only handles small inputs.

Use only Source's public API. Do not change source.py or its constraints.
An empty page marks the end of the source. If the source becomes unavailable,
including after returning some data, propagate ConnectionError and leave any
existing output untouched; never report a partial or empty success.
Add and execute useful regression tests. No extra features are requested.
