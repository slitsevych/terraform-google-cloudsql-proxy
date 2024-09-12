locals {
  instance_name = var.instance_name
  network_tag   = "cloudsql-proxy"
}

resource "google_service_account" "main" {
  account_id   = "sa-${local.instance_name}"
  display_name = "Cloud SQL Proxy sa for VM ${local.instance_name}"
  project      = var.project
  description  = "Used by the VM ${local.instance_name}"
}

resource "google_project_iam_member" "cloudsql_instance_user_role_to_main_service_account" {
  role    = "roles/cloudsql.instanceUser"
  member  = "serviceAccount:${google_service_account.main.email}"
  project = var.project
}

resource "google_project_iam_member" "cloudsql_instance_client_role_to_main_service_account" {
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.main.email}"
  project = var.project
}

module "gce_container_sqlproxy" {
  source  = "terraform-google-modules/container-vm/google"
  version = "3.1.1"

  cos_image_family = var.cos_image_family
  container = {
    image   = var.container_image
    command = var.container_command
    args    = var.container_args
  }

  restart_policy = "Always"
}

resource "google_project_iam_member" "log_writer_to_vm_sa" {
  project = var.project
  role    = "roles/logging.logWriter"

  member = "serviceAccount:${google_service_account.main.email}"
}

resource "google_project_iam_member" "metric_writer_to_vm_sa" {
  project = var.project
  role    = "roles/monitoring.metricWriter"

  member = "serviceAccount:${google_service_account.main.email}"
}

resource "google_compute_firewall" "inbound" {
  name        = "allow-${local.instance_name}"
  network     = var.firewall_network
  description = "Allow accessing default container port"

  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }

  source_ranges = var.firewall_source_ranges
  target_tags   = [local.network_tag]
}

resource "google_compute_address" "sqlproxy_address" {
  count = var.enable_public_ip ? 1 : 0
  name = "${local.instance_name}-ip"
}

resource "google_compute_instance" "main" {
  name         = local.instance_name
  machine_type = var.vm_machine_type
  zone         = var.vm_zone

  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = module.gce_container_sqlproxy.source_image
      size  = "10"
    }
  }

  network_interface {
    network    = var.vm_network
    subnetwork = var.vm_subnetwork

    dynamic "access_config" {
      for_each = var.enable_public_ip ? [1] : []

      content {
        nat_ip = google_compute_address.sqlproxy_address[0].address
      }
    }
  }

  metadata = {
    gce-container-declaration    = module.gce_container_sqlproxy.metadata_value
    google-logging-enabled       = "true"
    google-logging-use-fluentbit = "false"
    google-monitoring-enabled    = "true"
    block-project-ssh-keys       = false
  }

  labels = merge(
    { container-vm = module.gce_container_sqlproxy.vm_container_label },
    var.labels
  )

  tags = concat([local.network_tag], var.custom_network_tags)

  service_account {
    email = google_service_account.main.email
    scopes = [
      "https://www.googleapis.com/auth/sqlservice.admin",
      "https://www.googleapis.com/auth/cloud-platform",
      "https://www.googleapis.com/auth/userinfo.email",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write",
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/compute.readonly",
      "https://www.googleapis.com/auth/source.read_only"
    ]
  }

  lifecycle {
    ignore_changes = [
      boot_disk[0].initialize_params[0].image,
      labels
    ]
  }
}
