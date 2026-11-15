# A test helper, not part of the module: times relative to its own plan, for the runs in
# tests/builtin_auth.tftest.hcl that need a builtin_auth_recovery_until inside the 60-minute
# window, which has to be relative to the plan rather than a fixed date. A first run plans this
# module and the later runs read its output. Their own plans come seconds later, so a time 30
# minutes after this one is still in the future and within the window for them.

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
