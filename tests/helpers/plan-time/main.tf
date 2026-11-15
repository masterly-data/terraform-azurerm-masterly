# A test helper, not part of the module: times relative to its own plan, for the runs that need a
# time on either side of a window measured from the plan, which has to be relative to the plan
# rather than a fixed date: in tests/builtin_auth.tftest.hcl a builtin_auth_recovery_until inside
# the 60-minute window, and in tests/bff_dpop_key.tftest.hcl a DPoP key rotated inside or before
# its 60-minute overlap. A first run plans this module and the later runs read its output. Their
# own plans come seconds later, so a time 30 minutes after this one is still in the future and
# within the window for them.

output "in_30_minutes" {
  value       = timeadd(plantimestamp(), "30m")
  description = "This plan's time plus 30 minutes, in RFC 3339 UTC."
}

# Either side of the 60-minute limit, for a later plan seconds after this one: 59 minutes is
# still inside it, 61 minutes is past it. Only elapsed time moves 59 minutes further inside;
# 61 minutes falls inside after a minute, so the run that reads it plans this module directly
# before.
output "in_59_minutes" {
  value       = timeadd(plantimestamp(), "59m")
  description = "This plan's time plus 59 minutes, in RFC 3339 UTC."
}

output "in_61_minutes" {
  value       = timeadd(plantimestamp(), "61m")
  description = "This plan's time plus 61 minutes, in RFC 3339 UTC."
}

# For the DPoP key's timers: times before this plan, for a key replaced that long ago, and the
# expiry of a timer started 30 days ago. 10 minutes ago stays inside a 60-minute overlap for a
# later plan that comes within the next 50 minutes; 2 hours ago is past it.
output "ago_10_minutes" {
  value       = timeadd(plantimestamp(), "-10m")
  description = "This plan's time minus 10 minutes, in RFC 3339 UTC."
}

output "ago_2_hours" {
  value       = timeadd(plantimestamp(), "-2h")
  description = "This plan's time minus 2 hours, in RFC 3339 UTC."
}

output "ago_30_days" {
  value       = timeadd(plantimestamp(), "-720h")
  description = "This plan's time minus 30 days, in RFC 3339 UTC."
}

output "in_150_days" {
  value       = timeadd(plantimestamp(), "3600h")
  description = "This plan's time plus 150 days, in RFC 3339 UTC."
}

output "ago_120_days" {
  value       = timeadd(plantimestamp(), "-2880h")
  description = "This plan's time minus 120 days, in RFC 3339 UTC."
}
