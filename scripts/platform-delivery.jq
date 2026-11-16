# coord:report:daily's metrics as one logfmt record (scripts/platform-record.sh delivery); a metric the report leaves
# null (its unknown_reason says why) is "unknown", never 0. Lead time is authorization_to_merge's median, in hours.
.metrics as $m
| [
    "verified_deliveries=\($m.verified_deliveries.value.total // "unknown")",
    "prs_reviewed=\($m.review.value.prs_reviewed // "unknown")",
    "review_passes=\($m.review.value.passes // "unknown")",
    "rework_rounds=\($m.review.value.rework_rounds // "unknown")",
    "repeated_reviews=\($m.review.value.repeated_reviews // "unknown")",
    "parked=\($m.blocked_time.value.parked_events // "unknown")",
    "lead_time_hours=\($m.authorization_to_merge.value.median_seconds // null | if . == null then "unknown" else (. / 360 | floor) / 10 end)"
  ]
| join(" ")
