# Nomad job spec for Keywordista.
#
# Plan §4.6.7: anyone running a Nomad cluster can deploy by pointing
# at our image and supplying env vars. No custom Nomad operator.
#
# Run:
#   nomad job plan deploy/nomad/keywordista.nomad
#   nomad job run  deploy/nomad/keywordista.nomad
#
# Secrets:
#   Set KEYWORDISTA_ENCRYPTION_KEY and KEYWORDISTA_PUBLIC_BASE_URL via
#   `nomad var put` or a Vault integration. The env block below
#   references them via Nomad template syntax (`{{ env "..." }}`).
#
# Single instance (count = 1) by design — see §4.10. SQLite + iTunes API
# throttling both make horizontal scaling counterproductive.

job "keywordista" {
  type        = "service"
  datacenters = ["dc1"]  # change to your datacenter

  group "server" {
    count = 1

    # Recreate-style update: stop old before starting new (so the
    # ReadWriteOnce-style host volume is released cleanly).
    update {
      max_parallel      = 1
      min_healthy_time  = "30s"
      healthy_deadline  = "5m"
      progress_deadline = "10m"
      auto_revert       = true
      canary            = 0
      stagger           = "30s"
    }

    network {
      port "http" {
        to = 8080
      }
    }

    # Host volume mount for /data. Configure on your client nodes:
    #   client { host_volume "keywordista_data" { path = "/srv/keywordista" } }
    volume "data" {
      type      = "host"
      source    = "keywordista_data"
      read_only = false
    }

    service {
      name = "keywordista"
      port = "http"
      tags = ["urlprefix-keywordista.your-domain.com/"]  # Fabio/Traefik tag

      check {
        type     = "http"
        path     = "/health"
        interval = "30s"
        timeout  = "5s"
      }
    }

    task "keywordista" {
      driver = "docker"

      config {
        image = "ghcr.io/bootuz/keywordista:latest"
        ports = ["http"]
        # uid 10001 = keywordista user inside the image
      }

      volume_mount {
        volume      = "data"
        destination = "/data"
      }

      env {
        KEYWORDISTA_MODE                = "server"
        KEYWORDISTA_DATA_DIR            = "/data"
        KEYWORDISTA_ENCRYPTION_KEY      = "${KEYWORDISTA_ENCRYPTION_KEY}"
        KEYWORDISTA_PUBLIC_BASE_URL     = "${KEYWORDISTA_PUBLIC_BASE_URL}"
      }

      resources {
        cpu    = 200  # MHz; raise for heavier workloads
        memory = 256  # MB
      }
    }
  }
}
