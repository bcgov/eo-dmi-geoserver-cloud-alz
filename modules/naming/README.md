# module: naming

Pure-locals module. Emits the mandatory BC Gov ALZ tag set (`account_coding`,
`billing_group`, `ministry_name`, `environment`, `owner`) plus any extra tags as
`common_tags`, and a `name_prefix` (`<project>-<environment>`). Creates no Azure
resources.

## Usage
```hcl
module "naming" {
  source         = "../../modules/naming"
  project        = "geoserver"
  environment    = "dev"
  account_coding = var.account_coding
  billing_group  = var.billing_group
  ministry_name  = var.ministry_name
  owner          = var.owner
}
```
