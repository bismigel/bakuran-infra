# The provider cannot guess a site when none is marked primary, so read them and pick by name.
data "omada_sites" "all" {}

output "sites" {
  value = data.omada_sites.all.sites
}
