### Fixed

- A first apply no longer fails halfway with `ServerIsBusy` on a Postgres server parameter. The
  server parameters (`log_error_verbosity`, `log_parameter_max_length_on_error`,
  `log_parameter_max_length`, `postgres_server_parameters` and the PgBouncer parameters) are now
  written after the server's Entra administrators. Azure runs one operation at a time on a
  flexible server, and the parameter writes and the administrator write were sent together. An
  existing install sees no change in its plan.
