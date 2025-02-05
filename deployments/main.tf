# Copyright 2024 The OSS Rebuild Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

variable "project" {
  type = string
}
variable "host" {
  type = string
  description = "Name of the host of the rebuild instance"
  validation {
    condition     = can(regex("^[a-z][a-z-]*[a-z]$", var.host))
    error_message = "The resource name must start with a letter and contain only lowercase letters and hyphens."
  }
}
variable "repo" {
  type = string
  default = "https://github.com/google/oss-rebuild"
  validation {
    condition = can(regex((
      # v--------- scheme ----------vv----------------- host -----------------------vv-- port --vv-- path -->
      "^(?:[a-zA-Z][a-zA-Z0-9+.-]*:)?(?:[a-zA-Z0-9-._~!$&'()*+,;=]+|%[0-9a-fA-F]{2})*(?::[0-9]+)?(?:/(?:[a-zA-Z0-9-._~!$&'()*+,;=:@]+|%[0-9a-fA-F]{2})*)*$"
    ), var.repo))
    error_message = "The repo must be a valid URI."
  }
  validation {
    condition = can(startswith(var.repo, "file://")
        ? fileexists(join("/", [substr(var.repo, 7, -1), ".git/config"])) ||  fileexists(join("/", [substr(var.repo, 7, -1), ".jj/repo/store/git/config"]))
        : true)
    error_message = "file:// URIs must point to valid git repos"
  }
}
variable "service_version" {
  type = string
  validation {
    condition = can(regex("^v0.0.0-[0-9]{14}-[0-9a-f]{12}$", var.service_version))
    error_message = "The version must be valid a go mod pseudo-version: https://go.dev/ref/mod#pseudo-versions"
  }
  // TODO: Validate that this is a valid pseudo-version (for external repos).
}
variable "service_commit" {
  type = string
  validation {
    condition = can(regex("^([0-9a-f]{40}|[0-9a-f]{64})$", var.service_commit))
    error_message = "The commit must be a valid git commit hash"
  }
  validation {
    condition = substr(var.service_commit, 0, 12) == substr(var.service_version, 22, 12)
    error_message = "The commit must correspond to service_version"
  }
  // TODO: Validate that this commit exists in repo.
}
variable "public" {
  type = bool
  default = true
}

data "google_project" "project" {
  project_id = var.project
}

locals {
  project_num = data.google_project.project.number
}

provider "google" {
  project = var.project
  region  = "us-central1"
  zone    = "us-central1-c"
}

provider "google-beta" {
  project = var.project
  region  = "us-central1"
  zone    = "us-central1-c"
}

## IAM resources

resource "google_service_account" "orchestrator" {
  account_id  = "orchestrator"
  description = "Primary API identity for the rebuilder. NOTE: This should NOT be used to run rebuilds."
}
resource "google_service_account" "builder-remote" {
  account_id  = "builder-remote"
  description = "Rebuild identity used to run rebuilds executed remotely from the RPC service node."
}
resource "google_service_account" "builder-local" {
  account_id  = "builder-local"
  description = "Rebuild identity used to run rebuilds executed locally on the RPC service node."
}
resource "google_service_account" "inference" {
  account_id  = "inference"
  description = "Identity serving inference-only endpoints."
}
resource "google_service_account" "git-cache" {
  account_id  = "git-cache"
  description = "Identity serving git-cache endpoint."
}
resource "google_service_account" "gateway" {
  account_id  = "gateway"
  description = "Identity serving gateway endpoint."
}
resource "google_service_account" "attestation-pubsub-reader" {
  account_id  = "attestation-pubsub-reader"
  description = "Identity for reading the attestation pubsub topic."
}
data "google_storage_project_service_account" "attestation-pubsub-publisher" {
  provider = google-beta
}

## KMS resources

resource "google_project_service" "cloudkms" {
  service = "cloudkms.googleapis.com"
}
resource "google_kms_key_ring" "ring" {
  provider = google-beta
  name     = "ring"
  location = "global"
  depends_on = [google_project_service.cloudkms]
}
resource "google_kms_crypto_key" "signing-key" {
  provider = google-beta
  name     = "signing-key"
  key_ring = google_kms_key_ring.ring.id
  purpose  = "ASYMMETRIC_SIGN"
  version_template {
    algorithm = "EC_SIGN_P256_SHA256"
  }
  lifecycle {
    prevent_destroy = true
  }
}
data "google_kms_crypto_key_version" "signing-key-version" {
  provider   = google-beta
  crypto_key = google_kms_crypto_key.signing-key.id
}

## Storage resources

resource "google_project_service" "firestore" {
  service = "firestore.googleapis.com"
}
resource "google_project_service" "storage" {
  service = "storage.googleapis.com"
}
resource "google_storage_bucket" "attestations" {
  name                        = "${var.host}-rebuild-attestations"
  location                    = "us-central1"
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  depends_on = [google_project_service.storage]
}
resource "google_storage_bucket" "metadata" {
  name                        = "${var.host}-rebuild-metadata"
  location                    = "us-central1"
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  depends_on = [google_project_service.storage]
}
resource "google_storage_bucket" "logs" {
  name                        = "${var.host}-rebuild-logs"
  location                    = "us-central1"
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  depends_on = [google_project_service.storage]
}
resource "google_storage_bucket" "debug" {
  name                        = "${var.host}-rebuild-debug"
  location                    = "us-central1"
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  depends_on = [google_project_service.storage]
}
resource "google_storage_bucket" "git-cache" {
  name                        = "${var.host}-rebuild-git-cache"
  location                    = "us-central1"
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  depends_on = [google_project_service.storage]
}
resource "google_storage_bucket" "bootstrap-tools" {
  name                        = "${var.host}-rebuild-bootstrap-tools"
  location                    = "us-central1"
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  depends_on = [google_project_service.storage]
}

## Firestore

resource "google_project_service" "compute" {
  service = "compute.googleapis.com"
}
resource "google_project_service" "gae" {
  service = "appengine.googleapis.com"
}
# NOTE: Side-effect of app creation is creation of Firestore DB.
resource "google_app_engine_application" "dummy_app" {
  project       = var.project
  location_id   = "us-central"
  database_type = "CLOUD_FIRESTORE"
  depends_on    = [google_project_service.gae]
}

## PubSub

resource "google_pubsub_topic" "attestation-topic" {
  provider = google-beta
  name     = "oss-rebuild-attestation-topic"
}

resource "google_storage_notification" "attestation-notification" {
  provider       = google-beta
  bucket         = google_storage_bucket.attestations.name
  payload_format = "JSON_API_V1"
  topic          = google_pubsub_topic.attestation-topic.id
  event_types    = ["OBJECT_FINALIZE"]
  depends_on     = [google_pubsub_topic_iam_binding.readers-can-read-from-attestation-topic, google_pubsub_topic_iam_binding.can-publish-to-attestation-topic]
}

## Container resources

resource "google_artifact_registry_repository" "registry" {
  provider = google-beta
  location = "us-central1"
  repository_id = "service-images"
  format  = "DOCKER"
}

resource "terraform_data" "service_version" {
  input = var.service_version
}
resource "terraform_data" "git_dir" {
  input = (
    !startswith(var.repo, "file://") ? "!remote!" :
    fileexists(join("/", [substr(var.repo, 7, -1), ".git/config"])) ? join("/", [substr(var.repo, 7, -1), ".git"]) :
    fileexists(join("/", [substr(var.repo, 7, -1), ".jj/repo/store/git/config"])) ? join("/", [substr(var.repo, 7, -1), ".jj/repo/store/git"]) :
    "")
}

locals {
  registry_url = "${google_artifact_registry_repository.registry.location}-docker.pkg.dev/${var.project}/${google_artifact_registry_repository.registry.repository_id}"
  # Add .git suffix if it's a GitHub URL and doesn't already end with .git
  repo_with_git = (
    can(regex("^https://github\\.com/", var.repo)) && !endswith(var.repo, ".git") ? "${var.repo}.git" : var.repo
  )
  repo_docker_context = (
    startswith(var.repo, "file:")
      ? "- < <(GIT_DIR=${terraform_data.git_dir.output} git archive --format=tar ${var.service_commit})"
      : "${local.repo_with_git}#${var.service_commit}")
}

resource "terraform_data" "image" {
  for_each = {
    "gateway" = {
      name = "gateway"
      image = "${local.registry_url}/gateway"
    }
    "git-cache" = {
      name = "git_cache"
      image = "${local.registry_url}/git_cache"
    }
    "rebuilder" = {
      name = "rebuilder"
      image = "${local.registry_url}/rebuilder"
    }
    "inference" = {
      name = "inference"
      image = "${local.registry_url}/inference"
    }
    "api" = {
      name = "api"
      image = "${local.registry_url}/api"
    }
  }
  provisioner "local-exec" {
    command = <<-EOT
      path=${each.value.image}:${terraform_data.service_version.output}
      cmd="gcloud artifacts docker images describe $path"
      # Suppress stdout, show first line of stderr, return cmd's status.
      if ($cmd 2>&1 1>/dev/null | head -n1 >&2; exit $PIPESTATUS); then
        echo Found $path
      else
        echo Building $path
        docker build --quiet -f build/package/Dockerfile.${each.value.name} -t $path ${local.repo_docker_context} && \
          docker push --quiet $path
      fi
    EOT
  }
  lifecycle {
    replace_triggered_by = [
      terraform_data.service_version.output,
      terraform_data.git_dir.output,
    ]
  }
}

data "google_artifact_registry_docker_image" "gateway" {
  provider = google-beta
  location = google_artifact_registry_repository.registry.location
  repository_id = google_artifact_registry_repository.registry.repository_id
  image_name = "gateway:${terraform_data.service_version.output}"
  depends_on = [terraform_data.image["gateway"]]
}

data "google_artifact_registry_docker_image" "git-cache" {
  provider = google-beta
  location = google_artifact_registry_repository.registry.location
  repository_id = google_artifact_registry_repository.registry.repository_id
  image_name = "git_cache:${terraform_data.service_version.output}"
  depends_on = [terraform_data.image["git-cache"]]
}

data "google_artifact_registry_docker_image" "rebuilder" {
  provider = google-beta
  location = google_artifact_registry_repository.registry.location
  repository_id = google_artifact_registry_repository.registry.repository_id
  image_name = "rebuilder:${terraform_data.service_version.output}"
  depends_on = [terraform_data.image["rebuilder"]]
}

data "google_artifact_registry_docker_image" "inference" {
  provider = google-beta
  location = google_artifact_registry_repository.registry.location
  repository_id = google_artifact_registry_repository.registry.repository_id
  image_name = "inference:${terraform_data.service_version.output}"
  depends_on = [terraform_data.image["inference"]]
}

data "google_artifact_registry_docker_image" "api" {
  provider = google-beta
  location = google_artifact_registry_repository.registry.location
  repository_id = google_artifact_registry_repository.registry.repository_id
  image_name = "api:${terraform_data.service_version.output}"
  depends_on = [terraform_data.image["api"]]
}

## Compute resources

resource "google_project_service" "cloudbuild" {
  service = "cloudbuild.googleapis.com"
}
resource "google_project_service" "run" {
  service = "run.googleapis.com"
}
resource "google_cloud_run_v2_service" "gateway" {
  provider = google-beta
  name     = "gateway"
  location = "us-central1"
  template {
    service_account = google_service_account.gateway.email
    timeout         = "${5 * 60}s" // 5 minutes
    containers {
      image = data.google_artifact_registry_docker_image.gateway.self_link
      resources {
        limits = {
          cpu    = "1000m"
          memory = "2G"
        }
      }
    }
    scaling { max_instance_count = 1 }
    # Start to reject requests once a queue is at or near saturation. See cmd/gateway/main.go
    max_instance_request_concurrency = 360
  }
  depends_on = [google_project_service.run]
}
resource "google_cloud_run_v2_service" "git-cache" {
  provider = google-beta
  name     = "git-cache"
  location = "us-central1"
  template {
    service_account = google_service_account.git-cache.email
    timeout         = "${2 * 60}s" // 2 minutes
    containers {
      image = data.google_artifact_registry_docker_image.git-cache.self_link
      args = [
        "--bucket=${google_storage_bucket.git-cache.name}"
      ]
      resources {
        limits = {
          cpu    = "1000m"
          memory = "2G"
        }
      }
    }
    max_instance_request_concurrency = 1
  }
  depends_on = [google_project_service.run]
}
resource "google_cloud_run_v2_service" "build-local" {
  provider = google-beta
  name     = "build-local"
  location = "us-central1"
  template {
    service_account = google_service_account.builder-local.email
    timeout         = "${59 * 60}s" // 59 minutes
    containers {
      image = data.google_artifact_registry_docker_image.rebuilder.self_link
      args = [
        "--debug-storage=gs://${google_storage_bucket.debug.name}",
        "--git-cache-url=${google_cloud_run_v2_service.git-cache.uri}",
        "--gateway-url=${google_cloud_run_v2_service.gateway.uri}",
        "--user-agent=oss-rebuild+${var.host}/0.0.0",
      ]
      resources {
        limits = {
          cpu    = "8000m"
          memory = "24G"
        }
      }
    }
    scaling { max_instance_count = 100 }
    max_instance_request_concurrency = 1
  }
  depends_on = [google_project_service.run]
}
resource "google_cloud_run_v2_service" "inference" {
  provider = google-beta
  name     = "inference"
  location = "us-central1"
  template {
    service_account       = google_service_account.inference.email
    timeout               = "${14 * 60}s" // 14 minutes
    containers {
      image = data.google_artifact_registry_docker_image.inference.self_link
      args = [
        "--gateway-url=${google_cloud_run_v2_service.gateway.uri}",
        "--user-agent=oss-rebuild+${var.host}/0.0.0",
        "--git-cache-url=${google_cloud_run_v2_service.git-cache.uri}",
      ]
      resources {
        limits = {
          cpu    = "4000m"
          memory = "16G"
        }
      }
    }
    max_instance_request_concurrency = 1
  }
  depends_on = [google_project_service.run]
}

resource "google_cloud_run_v2_service" "orchestrator" {
  provider = google-beta
  name     = "api"
  location = "us-central1"
  template {
    service_account = google_service_account.orchestrator.email
    timeout         = "${59 * 60}s" // 59 minutes
    containers {
      image = data.google_artifact_registry_docker_image.api.self_link
      args = [
        "--project=${var.project}",
        "--build-local-url=${google_cloud_run_v2_service.build-local.uri}",
        "--build-remote-identity=${google_service_account.builder-remote.name}",
        "--inference-url=${google_cloud_run_v2_service.inference.uri}",
        "--prebuild-bucket=${google_storage_bucket.bootstrap-tools.name}",
        "--signing-key-version=${data.google_kms_crypto_key_version.signing-key-version.name}",
        "--metadata-bucket=${google_storage_bucket.metadata.name}",
        "--attestation-bucket=${google_storage_bucket.attestations.name}",
        "--logs-bucket=${google_storage_bucket.logs.name}",
        "--debug-storage=gs://${google_storage_bucket.debug.name}",
        "--gateway-url=${google_cloud_run_v2_service.gateway.uri}",
        "--user-agent=oss-rebuild+${var.host}/0.0.0",
        "--build-def-repo=https://github.com/google/oss-rebuild",
        "--build-def-repo-dir=definitions",
      ]
      resources {
        limits = {
          cpu    = "1000m"
          memory = "2G"
        }
      }
    }
    max_instance_request_concurrency = 25
  }
  depends_on = [google_project_service.run]
}

## IAM Bindings

resource "google_project_iam_custom_role" "bucket-viewer-role" {
  provider    = google-beta
  role_id     = "bucketViewer"
  title       = "Bucket Viewer"
  permissions = ["storage.buckets.get", "storage.buckets.list"]
}
resource "google_storage_bucket_iam_binding" "git-cache-manages-git-cache" {
  bucket  = google_storage_bucket.git-cache.name
  role    = "roles/storage.objectAdmin"
  members = ["serviceAccount:${google_service_account.git-cache.email}"]
}
resource "google_storage_bucket_iam_binding" "local-build-reads-git-cache" {
  bucket  = google_storage_bucket.git-cache.name
  role    = "roles/storage.objectViewer"
  members = ["serviceAccount:${google_service_account.builder-local.email}"]
}
resource "google_storage_bucket_iam_binding" "orchestrator-writes-attestations" {
  bucket  = google_storage_bucket.attestations.name
  role    = "roles/storage.objectCreator"
  members = ["serviceAccount:${google_service_account.orchestrator.email}"]
}
resource "google_storage_bucket_iam_binding" "orchestrator-manages-metadata" {
  bucket  = google_storage_bucket.metadata.name
  role    = "roles/storage.objectAdmin"
  members = ["serviceAccount:${google_service_account.orchestrator.email}"]
}
resource "google_storage_bucket_iam_binding" "orchestrator-and-local-build-write-debug" {
  bucket  = google_storage_bucket.debug.name
  role    = "roles/storage.objectCreator"
  members = [
    "serviceAccount:${google_service_account.orchestrator.email}",
    "serviceAccount:${google_service_account.builder-local.email}",
  ]
}
resource "google_storage_bucket_iam_binding" "remote-build-writes-metadata" {
  bucket  = google_storage_bucket.metadata.name
  role    = "roles/storage.objectCreator"
  members = ["serviceAccount:${google_service_account.builder-remote.email}"]
}
resource "google_storage_bucket_iam_binding" "remote-build-uses-logs" {
  bucket  = google_storage_bucket.logs.name
  role    = "roles/storage.objectUser"
  members = ["serviceAccount:${google_service_account.builder-remote.email}"]
}
resource "google_storage_bucket_iam_binding" "remote-build-views-logs-bucket" {
  bucket  = google_storage_bucket.logs.name
  role    = google_project_iam_custom_role.bucket-viewer-role.name
  members = ["serviceAccount:${google_service_account.builder-remote.email}"]
}
resource "google_storage_bucket_iam_binding" "orchestrator-manages-attestations" {
  bucket  = google_storage_bucket.attestations.name
  role    = "roles/storage.objectAdmin"
  members = ["serviceAccount:${google_service_account.orchestrator.email}"]
}
resource "google_storage_bucket_iam_binding" "remote-build-views-bootstrap-bucket" {
  count = var.public ? 0 : 1  // NOTE: Non-public objects must still be visible to the builder.
  bucket  = google_storage_bucket.bootstrap-tools.name
  role    = "roles/storage.objectViewer"
  members = ["serviceAccount:${google_service_account.builder-remote.email}"]
}
resource "google_cloud_run_v2_service_iam_binding" "orchestrator-calls-build-local" {
  provider = google-beta
  location = google_cloud_run_v2_service.build-local.location
  project  = google_cloud_run_v2_service.build-local.project
  name     = google_cloud_run_v2_service.build-local.name
  role     = "roles/run.invoker"
  members  = ["serviceAccount:${google_service_account.orchestrator.email}"]
}
resource "google_project_iam_binding" "orchestrator-runs-workloads-as-others" {
  project = var.project
  role    = "roles/iam.serviceAccountUser"
  members = ["serviceAccount:${google_service_account.orchestrator.email}"]
}
resource "google_project_iam_binding" "orchestrator-runs-gcb-builds" {
  project = var.project
  role    = "roles/cloudbuild.builds.editor"
  members = ["serviceAccount:${google_service_account.orchestrator.email}"]
}
resource "google_cloud_run_v2_service_iam_binding" "orchestrator-calls-inference" {
  provider = google-beta
  location = google_cloud_run_v2_service.inference.location
  project  = google_cloud_run_v2_service.inference.project
  name     = google_cloud_run_v2_service.inference.name
  role     = "roles/run.invoker"
  members  = ["serviceAccount:${google_service_account.orchestrator.email}"]
}
resource "google_kms_crypto_key_iam_binding" "orchestrator-reads-signing-key" {
  crypto_key_id = google_kms_crypto_key.signing-key.id
  role          = "roles/cloudkms.viewer"
  members       = ["serviceAccount:${google_service_account.orchestrator.email}"]
}
resource "google_kms_crypto_key_iam_binding" "orchestrator-uses-signing-key" {
  crypto_key_id = google_kms_crypto_key.signing-key.id
  role          = "roles/cloudkms.signerVerifier"
  members       = ["serviceAccount:${google_service_account.orchestrator.email}"]
}
resource "google_cloud_run_v2_service_iam_binding" "local-build-calls-git-cache" {
  provider = google-beta
  location = google_cloud_run_v2_service.git-cache.location
  project  = google_cloud_run_v2_service.git-cache.project
  name     = google_cloud_run_v2_service.git-cache.name
  role     = "roles/run.invoker"
  members  = ["serviceAccount:${google_service_account.builder-local.email}"]
}
resource "google_cloud_run_v2_service_iam_binding" "api-and-local-build-and-inference-call-gateway" {
  provider = google-beta
  location = google_cloud_run_v2_service.gateway.location
  project  = google_cloud_run_v2_service.gateway.project
  name     = google_cloud_run_v2_service.gateway.name
  role     = "roles/run.invoker"
  members  = [
    "serviceAccount:${google_service_account.builder-local.email}",
    "serviceAccount:${google_service_account.inference.email}",
    "serviceAccount:${google_service_account.orchestrator.email}",
  ]
}
resource "google_pubsub_topic_iam_binding" "can-publish-to-attestation-topic" {
  provider = google-beta
  topic    = google_pubsub_topic.attestation-topic.id
  role     = "roles/pubsub.publisher"
  members  = ["serviceAccount:${data.google_storage_project_service_account.attestation-pubsub-publisher.email_address}"]
}
resource "google_pubsub_topic_iam_binding" "readers-can-read-from-attestation-topic" {
  provider = google-beta
  topic    = google_pubsub_topic.attestation-topic.id
  role     = "roles/pubsub.subscriber"
  members  = ["serviceAccount:${google_service_account.attestation-pubsub-reader.email}"]
}

## Public resources

resource "google_kms_crypto_key_iam_binding" "signing-key-is-public" {
  count = var.public ? 1 : 0
  crypto_key_id = google_kms_crypto_key.signing-key.id
  role          = "roles/cloudkms.verifier"
  members       = ["allUsers"]
}
resource "google_storage_bucket_iam_binding" "attestation-bucket-is-public" {
  count = var.public ? 1 : 0
  bucket  = google_storage_bucket.attestations.name
  role    = "roles/storage.objectViewer"
  members = ["allUsers"]
}
resource "google_storage_bucket_iam_binding" "bootstrap-bucket-is-public" {
  count = var.public ? 1 : 0
  bucket  = google_storage_bucket.bootstrap-tools.name
  role    = "roles/storage.objectViewer"
  members = ["allUsers"]
}
