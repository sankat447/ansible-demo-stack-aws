output "host" {
  value     = data.aws_ssm_parameter.endpoint.value
  sensitive = true
}

output "credentials" {
  description = "Per-database app credentials: { <db> = { database, username, password } }."
  value = {
    for name, db in var.databases : name => {
      database = name
      username = "${name}_app"
      password = random_password.app[name].result
    }
  }
  sensitive = true
}
