# Partial backend — all values injected at init via -backend-config flags.
# See scripts/tf.sh and the TF_BACKEND_* env vars set in each GitHub Environment.
terraform {
  backend "azurerm" {
    use_azuread_auth = true
  }
}
